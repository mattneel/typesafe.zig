// Zig syntax highlighting for the book.
//
// mdBook bundles highlight.js with a fixed set of languages, and Zig is not one
// of them: `zig` code blocks arrive in the page as plain text with no spans. A
// theme override could ship a different highlight.js, but that means building
// the whole bundle; registering a grammar with the instance mdBook already
// loaded costs one small file instead.
//
// The grammar uses only the token classes mdBook's themes style (keyword,
// type, built_in, string, number, comment, literal, title, symbol), so it needs
// no CSS of its own and looks right in every theme.

(function () {
  "use strict";

  if (typeof hljs === "undefined" || typeof hljs.registerLanguage !== "function") return;

  var KEYWORDS = [
    "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async",
    "await", "break", "callconv", "catch", "comptime", "const", "continue", "defer",
    "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if",
    "inline", "linksection", "noalias", "nosuspend", "opaque", "or", "orelse",
    "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test",
    "threadlocal", "try", "union", "unreachable", "usingnamespace", "var",
    "volatile", "while",
  ].join(" ");

  var TYPES = [
    "anyerror", "bool", "comptime_float", "comptime_int", "f16", "f32", "f64",
    "f80", "f128", "i8", "i16", "i32", "i64", "i128", "isize", "noreturn", "type",
    "u8", "u16", "u32", "u64", "u128", "usize", "void",
  ].join(" ");

  hljs.registerLanguage("zig", function (hljs) {
    // `\\` starts a multiline string; every line of one begins with it.
    var MULTILINE_STRING = { className: "string", begin: /\\\\[^\n]*/, relevance: 0 };

    var STRING = {
      className: "string",
      variants: [
        { begin: /"/, end: /"/, illegal: /\n/, contains: [{ begin: /\\./ }] },
        { begin: /'/, end: /'/, illegal: /\n/, contains: [{ begin: /\\./ }] },
      ],
    };

    // `@"..."` is an identifier, but reads as the quoted thing it is.
    var QUOTED_IDENTIFIER = { className: "symbol", begin: /@"[^"\n]*"/, relevance: 0 };

    var NUMBER = {
      className: "number",
      variants: [
        { begin: /\b0x[0-9a-fA-F_][0-9a-fA-F_]*/ },
        { begin: /\b0b[01_][01_]*/ },
        { begin: /\b0o[0-7_][0-7_]*/ },
        { begin: /\b\d[\d_]*(\.\d[\d_]*)?([eE][-+]?\d+)?/ },
      ],
      relevance: 0,
    };

    // `@import`, `@intCast`, `@field`, ...
    var BUILTIN = { className: "built_in", begin: /@[A-Za-z_][A-Za-z0-9_]*/ };

    return {
      name: "Zig",
      aliases: ["zig", "zon"],
      keywords: {
        keyword: KEYWORDS,
        type: TYPES,
        literal: "false null true undefined",
      },
      contains: [
        hljs.C_LINE_COMMENT_MODE,
        MULTILINE_STRING,
        STRING,
        QUOTED_IDENTIFIER,
        NUMBER,
        BUILTIN,
      ],
    };
  });

  // mdBook runs highlightAll before this file, so a Zig block has already been
  // looked at and left as plain text. Highlighting it again from its text is
  // idempotent, which also makes running twice harmless if the file is included
  // more than once.
  //
  // mdBook currently bundles highlight.js 10, where the call is
  // `highlight(language, code)`; 11 renamed it to `highlightElement`. Both spell
  // the same class names, so the themes style either one.
  function highlightZig(block) {
    if (typeof hljs.highlightElement === "function") {
      block.removeAttribute("data-highlighted");
      hljs.highlightElement(block);
      return;
    }
    block.innerHTML = hljs.highlight("zig", block.textContent).value;
  }

  document.querySelectorAll("code.language-zig, code.language-zon").forEach(highlightZig);
})();
