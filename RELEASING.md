# Releasing

This is the checklist for releasing a new version of `typesafe.zig`. Work through it in order.
Every step should pass before you go to the next one.

A release is an annotated `vX.Y.Z` tag on `master` and a GitHub release for that tag. Consumers
install it with:

```console
$ zig fetch --save git+https://github.com/mattneel/typesafe.zig#vX.Y.Z
```

`zig fetch` records the content hash in the consumer's `build.zig.zon`, so a tag must never move
after it is pushed.

The package follows [Semantic Versioning](https://semver.org). While the version is 0.x, any
change to an answer type or the wire format is at least a minor bump.

## 1. Prepare the release pull request

- [ ] Start from an up-to-date `master` and create a branch such as `release/vX.Y.Z`.
- [ ] Bump `.version` in `build.zig.zon`. The user agent (`typesafe-zig/X.Y.Z`) and
      `typesafe.version` read it from there. Never change `.fingerprint`.
- [ ] If the minimum Zig version changes, update `.minimum_zig_version` in `build.zig.zon`,
      `ZIG_VERSION` in `.github/workflows/ci.yml` and `live.yml`, and the requirement in
      `README.md`.
- [ ] Update the install snippet to `#vX.Y.Z` in `README.md`.
- [ ] In `CHANGELOG.md`, move the entries under `## [Unreleased]` to a new
      `## [X.Y.Z] - YYYY-MM-DD` heading below it, and leave `## [Unreleased]` empty. Use the date
      on which you will merge and tag. Add a `[X.Y.Z]` link at the bottom and point the
      `[Unreleased]` link at `https://github.com/mattneel/typesafe.zig/compare/vX.Y.Z...HEAD`.

## 2. Run the local checks

Run them from a shell without `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL` or
`TYPESAFE_DEFAULT_MODEL` exported.

```console
$ zig build ci --summary all
$ zig build test -Doptimize=ReleaseSafe --summary all
$ zig build test -Doptimize=ReleaseFast --summary all
```

`zig build ci` checks formatting and runs the offline tests, builds the examples and generates
the API reference.

- [ ] Run the live tests and every example against the real API if you will not rely on the Live
      API workflow in step 4: `TYPESAFE_API_KEY=... zig build test-live`, then
      `zig build run -Dexample=<name>` for each example.

## 3. Review the docs locally

```console
$ zig build docs
$ python3 -m http.server -d zig-out/docs
```

- [ ] Every public declaration has a doc comment, and `.version` in `build.zig.zon`, which
      `typesafe.version` reads, is X.Y.Z. (The generated reference does not print the version;
      check the manifest.)
- [ ] README links to `docs/guides/*.md`, `CHANGELOG.md` and the examples work from the release
      branch on GitHub.

## 4. Get CI green

Open a pull request for the release branch and wait for every job to pass: the test matrix on
Linux, macOS and Windows in Debug and ReleaseSafe, and the format, examples, docs and
cross-compilation job. Trigger the Live API workflow on the release branch head with
`workflow_dispatch` and check that the **Live tests** job ran and passed. A run in which it was
skipped, for example because the `TYPESAFE_API_KEY` secret is not set, does not count.

Merge the pull request once CI is green.

## 5. Tag the release

Tag the release pull request's merge commit, not whatever `master` points at now:

```console
$ git fetch origin
$ git show <release-commit-sha>:build.zig.zon | grep '.version = "X.Y.Z"'
$ git show <release-commit-sha>:CHANGELOG.md | grep '^## \[X.Y.Z\] - '
$ git tag -a vX.Y.Z <release-commit-sha> -m "vX.Y.Z"
$ git push origin vX.Y.Z
```

## 6. Verify the install from GitHub

Before publishing the GitHub release, in a scratch directory outside this repository:

```console
$ mkdir typesafe-consumer && cd typesafe-consumer
$ zig init
$ zig fetch --save git+https://github.com/mattneel/typesafe.zig#vX.Y.Z
```

Add the dependency to `build.zig` as the README shows, import it from `src/main.zig`, and print
`typesafe.version`.

- [ ] `zig build run` prints `X.Y.Z`.

If the install fails, do not publish the GitHub release. Fix the problem on `master` and release
a new patch version.

## 7. Create the GitHub release

```console
$ gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes "See CHANGELOG.md"
```

Paste the `CHANGELOG.md` section for the version into the release notes, joining hard-wrapped
lines.

## If something goes wrong

- Do not move or delete a tag that has been pushed. Consumers have its content hash in their
  `build.zig.zon`. Fix the problem on `master` and release a new patch version instead.
- If a release is broken, say so at the top of its GitHub release notes and point to the fixed
  version.
