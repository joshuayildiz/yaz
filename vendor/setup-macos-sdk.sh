#!/bin/sh
# Fetches a macOS SDK into vendor/macos-sdk, for cross-compiling to macOS.
# Invoked by `zig build` only when the target is macOS and the host is not.
#
# On a Mac this is never run: Zig and SDL use the system SDK directly.
#
# Apple's SDK is not redistributable by us, and its licence contemplates use on
# Apple hardware. The archive is fetched at build time from a third-party mirror
# and never committed. See README.md.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK="$ROOT/vendor/macos-sdk"

SDK_VERSION="15.5"
SDK_ARCHIVE="MacOSX$SDK_VERSION.sdk.tar.xz"
SDK_SHA256="c15cf0f3f17d714d1aa5a642da8e118db53d79429eb015771ba816aa7c6c1cbd"
SDK_URL="https://github.com/joseluisq/macosx-sdks/releases/download/$SDK_VERSION/$SDK_ARCHIVE"

# A Mac has its own SDK; nothing to do.
[ "$(uname -s)" = "Darwin" ] && exit 0

# usr/include is the last thing extracted below, so its presence means the
# previous run completed rather than died midway.
[ -d "$SDK/usr/include" ] && exit 0

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

echo ">> fetching the macOS $SDK_VERSION SDK (~80MB, expands to ~1.8GB)"
TMP="$ROOT/vendor/src"
mkdir -p "$TMP"
curl -fsSL --retry 3 -o "$TMP/$SDK_ARCHIVE" "$SDK_URL"

echo "$SDK_SHA256  $TMP/$SDK_ARCHIVE" | sha256sum -c - >/dev/null || {
    echo "setup-macos-sdk: checksum mismatch, refusing to use the archive" >&2
    rm -f "$TMP/$SDK_ARCHIVE"
    exit 1
}

echo ">> extracting"
rm -rf "$SDK" "$TMP/sdk"
mkdir -p "$TMP/sdk"
tar -xJf "$TMP/$SDK_ARCHIVE" -C "$TMP/sdk"
mv "$TMP/sdk/MacOSX$SDK_VERSION.sdk" "$SDK"
rm -rf "$TMP/sdk" "$TMP/$SDK_ARCHIVE"

echo ">> macOS SDK ready"
