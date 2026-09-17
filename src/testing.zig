//! Helpers for testing code that uses the client, without network access.
//!
//! `MockServer` is a loopback HTTP server that plays back scripted replies
//! and records every request it receives. Point a client at its `url` and
//! test your routing, thresholds and error handling offline:
//!
//! ```zig
//! test "urgent tickets are escalated" {
//!     const gpa = std.testing.allocator;
//!     const io = std.testing.io;
//!
//!     const server: *typesafe.testing.MockServer = try .create(gpa, io);
//!     defer server.destroy();
//!     try server.enqueueAnswers(questions, .{
//!         .is_urgent = .{ .noul = 0.97 },
//!         .department = .{ .choice = .billing, .probabilities = .{ .billing = 0.9, .technical = 0.05, .sales = 0.05 }, .confidence = 0.85 },
//!     }, .{});
//!
//!     var client: typesafe.Client = try .init(gpa, io, .{ .api_key = "test", .base_url = server.url(), .retry = .disabled });
//!     defer client.deinit();
//!
//!     try std.testing.expectEqual(.escalate, try routeTicket(&client, "Payouts failing for 3 days!"));
//!     try std.testing.expectEqualStrings("/v1/systemone", server.request(0).target);
//! }
//! ```
//!
//! The server needs an `Io` that can run tasks concurrently, such as
//! `std.testing.io`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const question = @import("question.zig");
const wire = @import("wire.zig");

/// A loopback HTTP server with scripted replies and recorded requests.
pub const MockServer = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    url_buffer: [32]u8,
    url_len: usize,
    accept_task: Io.Future(Io.Cancelable!void),
    connections: Io.Group,
    mutex: Io.Mutex,
    replies: std.ArrayList(Reply),
    next_reply: usize,
    requests: std.ArrayList(Request),

    /// A scripted reply.
    pub const Reply = struct {
        status: std.http.Status = .ok,
        body: []const u8 = "",
        /// Extra response headers, such as `x-typesafe-request-id` or
        /// `retry-after-ms`.
        headers: []const std.http.Header = &.{},
        content_type: []const u8 = "application/json",
        /// Wait this long before replying, for example to trigger a timeout.
        delay: Io.Duration = .zero,
        /// Close the connection without replying, like a dropped connection.
        drop: bool = false,
        /// Read the request body before replying. `false` leaves it unread
        /// and closes the connection after `delay`, like a server that stops
        /// reading mid-upload; the recorded body is empty.
        read_body: bool = true,
        /// Send only this many body bytes, with a `content-length` for the
        /// whole body, then close the connection.
        truncate_body_to: ?usize = null,
        /// Close the connection right after replying, although the reply
        /// allows keep-alive, like a server whose idle timeout expired.
        close_after: bool = false,
    };

    /// A recorded request. Valid until the server is destroyed.
    pub const Request = struct {
        method: std.http.Method,
        target: []const u8,
        headers: []const std.http.Header,
        body: []const u8,

        /// Returns the value of the first header named `name`, ignoring case.
        pub fn header(recorded: Request, name: []const u8) ?[]const u8 {
            for (recorded.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            }
            return null;
        }
    };

    /// The reply sent when the script runs out.
    pub const unscripted_reply: Reply = .{
        .status = .internal_server_error,
        .body = "{\"detail\":\"MockServer has no scripted reply for this request\"}",
    };

    /// Starts a server on an ephemeral loopback port. `gpa` must be
    /// thread-safe; `io` must support concurrency.
    pub fn create(gpa: Allocator, io: Io) !*MockServer {
        const server = try gpa.create(MockServer);
        errdefer gpa.destroy(server);

        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);

        server.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .url_buffer = undefined,
            .url_len = 0,
            .accept_task = undefined,
            .connections = .init,
            .mutex = .init,
            .replies = .empty,
            .next_reply = 0,
            .requests = .empty,
        };
        const url_text = std.fmt.bufPrint(&server.url_buffer, "http://127.0.0.1:{d}", .{
            listener.socket.address.getPort(),
        }) catch unreachable;
        server.url_len = url_text.len;
        server.accept_task = try io.concurrent(acceptLoop, .{server});
        return server;
    }

    /// Stops the server, closes open connections and frees everything,
    /// including recorded requests.
    pub fn destroy(server: *MockServer) void {
        const io = server.io;
        const gpa = server.gpa;
        server.accept_task.cancel(io) catch {};
        server.connections.cancel(io);
        server.listener.deinit(io);
        for (server.replies.items) |reply| freeReply(gpa, reply);
        server.replies.deinit(gpa);
        for (server.requests.items) |recorded| freeRequest(gpa, recorded);
        server.requests.deinit(gpa);
        gpa.destroy(server);
    }

    /// The base URL to pass as the client's `base_url`.
    pub fn url(server: *const MockServer) []const u8 {
        return server.url_buffer[0..server.url_len];
    }

    /// Adds a reply to the end of the script. Replies are consumed in order,
    /// one per request. The body and headers are copied.
    pub fn enqueue(server: *MockServer, reply: Reply) Allocator.Error!void {
        const gpa = server.gpa;
        var copy = reply;
        copy.body = try gpa.dupe(u8, reply.body);
        errdefer gpa.free(copy.body);
        copy.content_type = try gpa.dupe(u8, reply.content_type);
        errdefer gpa.free(copy.content_type);
        const headers = try gpa.alloc(std.http.Header, reply.headers.len);
        var copied: usize = 0;
        errdefer {
            for (headers[0..copied]) |h| freeHeader(gpa, h);
            gpa.free(headers);
        }
        for (headers, reply.headers) |*dst, src| {
            dst.* = try dupeHeader(gpa, src);
            copied += 1;
        }
        copy.headers = headers;

        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        try server.replies.append(gpa, copy);
    }

    /// Scripts a successful `ask` reply carrying `answers` for `questions`,
    /// encoded as the API would send it.
    pub fn enqueueAnswers(
        server: *MockServer,
        questions: anytype,
        answers: question.Answers(@TypeOf(questions)),
        options: AnswersOptions,
    ) Allocator.Error!void {
        const body = try wire.encodeAnswers(server.gpa, questions, answers, .{
            .model = options.model,
            .usage = options.usage,
        });
        defer server.gpa.free(body);
        const request_id_header = [_]std.http.Header{.{ .name = "x-typesafe-request-id", .value = options.request_id }};
        try server.enqueue(.{ .body = body, .headers = &request_id_header, .delay = options.delay });
    }

    /// Options for `enqueueAnswers`: the response model, request id and usage.
    pub const AnswersOptions = struct {
        model: []const u8 = "jev-test",
        usage: wire.Usage = .{ .input_tokens = 100, .output_tokens = 10 },
        request_id: []const u8 = "req_mock",
        delay: Io.Duration = .zero,
    };

    /// Scripts an error reply with the body shape the API uses for
    /// authentication and usage errors.
    pub fn enqueueError(server: *MockServer, status: std.http.Status, options: ErrorOptions) Allocator.Error!void {
        const body = try std.json.Stringify.valueAlloc(server.gpa, .{
            .detail = .{ .error_type = options.error_type, .message = options.message },
        }, .{});
        defer server.gpa.free(body);
        var headers_buffer: [2]std.http.Header = undefined;
        var headers: std.ArrayList(std.http.Header) = .initBuffer(&headers_buffer);
        headers.appendAssumeCapacity(.{ .name = "x-typesafe-request-id", .value = options.request_id });
        var retry_after_buffer: [20]u8 = undefined;
        if (options.retry_after_ms) |ms| {
            headers.appendAssumeCapacity(.{
                .name = "retry-after-ms",
                .value = std.fmt.bufPrint(&retry_after_buffer, "{d}", .{ms}) catch unreachable,
            });
        }
        try server.enqueue(.{ .status = status, .body = body, .headers = headers.items });
    }

    /// Options for `enqueueError`: the server message, error type, request id and retry delay.
    pub const ErrorOptions = struct {
        error_type: []const u8 = "api_error",
        message: []const u8 = "mock error",
        request_id: []const u8 = "req_mock",
        retry_after_ms: ?u64 = null,
    };

    /// The number of requests received so far.
    pub fn requestCount(server: *MockServer) usize {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        return server.requests.items.len;
    }

    /// Returns recorded request number `index`, starting at 0.
    pub fn request(server: *MockServer, index: usize) Request {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        return server.requests.items[index];
    }

    fn nextReply(server: *MockServer) ?Reply {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        if (server.next_reply == server.replies.items.len) return null;
        defer server.next_reply += 1;
        return server.replies.items[server.next_reply];
    }

    fn acceptLoop(server: *MockServer) Io.Cancelable!void {
        const io = server.io;
        while (true) {
            const stream = server.listener.accept(io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => {
                    std.log.scoped(.typesafe_mock).warn("accept failed: {t}", .{err});
                    return;
                },
            };
            server.connections.concurrent(io, serveConnection, .{ server, stream }) catch {
                stream.close(io);
            };
        }
    }

    fn serveConnection(server: *MockServer, stream: Io.net.Stream) Io.Cancelable!void {
        const io = server.io;
        const gpa = server.gpa;
        defer stream.close(io);

        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buffer);
        var stream_writer = stream.writer(io, &write_buffer);
        var http_server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);

        while (true) {
            var incoming = http_server.receiveHead() catch return canceledOr(stream_reader.err);
            const reply = server.nextReply() orelse unscripted_reply;
            const recorded = recordRequest(gpa, &incoming, reply.read_body) catch return canceledOr(stream_reader.err);
            {
                server.mutex.lockUncancelable(io);
                defer server.mutex.unlock(io);
                server.requests.append(gpa, recorded) catch {
                    freeRequest(gpa, recorded);
                    return;
                };
            }

            if (reply.delay.nanoseconds > 0) try io.sleep(reply.delay, .awake);
            if (reply.drop or !reply.read_body) return;

            var headers_buffer: [32]std.http.Header = undefined;
            var headers: std.ArrayList(std.http.Header) = .initBuffer(&headers_buffer);
            headers.appendAssumeCapacity(.{ .name = "content-type", .value = reply.content_type });
            headers.appendSliceBounded(reply.headers) catch return;

            if (reply.truncate_body_to) |len| {
                writeTruncated(http_server.out, reply, headers.items, len) catch return canceledOr(stream_writer.err);
                return;
            }
            incoming.respond(reply.body, .{ .status = reply.status, .extra_headers = headers.items }) catch {
                return canceledOr(stream_writer.err);
            };
            if (reply.close_after) return;
        }
    }

    fn writeTruncated(out: *Io.Writer, reply: Reply, headers: []const std.http.Header, len: usize) Io.Writer.Error!void {
        try out.print("HTTP/1.1 {d} {s}\r\ncontent-length: {d}\r\n", .{
            @intFromEnum(reply.status), reply.status.phrase() orelse "", reply.body.len,
        });
        for (headers) |h| try out.print("{s}: {s}\r\n", .{ h.name, h.value });
        try out.writeAll("\r\n");
        try out.writeAll(reply.body[0..@min(len, reply.body.len)]);
        try out.flush();
    }

    fn canceledOr(err: anytype) Io.Cancelable!void {
        if (err) |e| if (e == error.Canceled) return error.Canceled;
    }

    fn recordRequest(gpa: Allocator, incoming: *std.http.Server.Request, read_body: bool) !Request {
        const method = incoming.head.method;
        const target = try gpa.dupe(u8, incoming.head.target);
        errdefer gpa.free(target);

        var headers: std.ArrayList(std.http.Header) = .empty;
        errdefer {
            for (headers.items) |h| freeHeader(gpa, h);
            headers.deinit(gpa);
        }
        var it = incoming.iterateHeaders();
        while (it.next()) |h| {
            const copy = try dupeHeader(gpa, h);
            headers.append(gpa, copy) catch |err| {
                freeHeader(gpa, copy);
                return err;
            };
        }

        var body_buffer: [4096]u8 = undefined;
        const body = if (read_body)
            try incoming.readerExpectNone(&body_buffer).allocRemaining(gpa, .limited(64 * 1024 * 1024))
        else
            try gpa.dupe(u8, "");
        errdefer gpa.free(body);

        return .{ .method = method, .target = target, .headers = try headers.toOwnedSlice(gpa), .body = body };
    }

    fn dupeHeader(gpa: Allocator, header: std.http.Header) Allocator.Error!std.http.Header {
        const name = try gpa.dupe(u8, header.name);
        errdefer gpa.free(name);
        return .{ .name = name, .value = try gpa.dupe(u8, header.value) };
    }

    fn freeHeader(gpa: Allocator, header: std.http.Header) void {
        gpa.free(header.name);
        gpa.free(header.value);
    }

    fn freeReply(gpa: Allocator, reply: Reply) void {
        gpa.free(reply.body);
        gpa.free(reply.content_type);
        for (reply.headers) |h| freeHeader(gpa, h);
        gpa.free(reply.headers);
    }

    fn freeRequest(gpa: Allocator, recorded: Request) void {
        gpa.free(recorded.target);
        for (recorded.headers) |h| freeHeader(gpa, h);
        gpa.free(recorded.headers);
        gpa.free(recorded.body);
    }
};
