#!/bin/sh
# Builds the documentation site into zig-out/site: the book, and the API
# reference generated from the doc comments next to it at api/.
#
# The chapters are the repository's own files, so no document is copied by hand
# and none can drift. They are staged instead of read in place because mdBook
# copies every file under its `src` directory into the output; building from the
# repository root would publish .git and the build caches with it.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage="$root/zig-out/book-src"
site="$root/zig-out/site"

rm -rf "$stage" "$site"
mkdir -p "$stage/docs/guides"
cp "$root/book/book.toml" "$root/book/SUMMARY.md" "$root/book/zig-highlight.js" "$stage/"
cp "$root/README.md" "$root/CHANGELOG.md" "$root/RELEASING.md" "$stage/"
cp "$root/docs/SPEC.md" "$stage/docs/"
cp "$root/docs/guides/"*.md "$stage/docs/guides/"

echo "building the book"
(cd "$root" && mdbook build "$stage")

echo "building the API reference"
(cd "$root" && zig build docs)

mkdir -p "$site/api"
cp -r "$stage/book/." "$site/"
cp -r "$root/zig-out/docs/." "$site/api/"
# The staged manifest is a build input, not a page.
rm -f "$site/book.toml"

echo "site: $site"
