#!/usr/bin/env bash
# fetch_webview2.sh — download the Microsoft.Web.WebView2 NuGet package
# at the version pinned in `webview2.pinned.txt` and unpack it into
# `third_party/webview2/`. Idempotent: refuses to overwrite an
# existing SDK unless `--force` is passed.
#
# Run from the project root: `tools/fetch_webview2.sh`.
# CI wires this through `build.zig` on Windows builds so contributors
# do not need to manually drag the .lib out of the .nupkg zip.

set -euo pipefail

DEST="${WEBVIEW2_DEST:-third_party/webview2}"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --dest=*) DEST="${arg#*=}" ;;
    *)
      echo "fetch_webview2.sh: unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

PIN_FILE="$(dirname "$0")/webview2.pinned.txt"
if [[ ! -f "$PIN_FILE" ]]; then
  echo "fetch_webview2.sh: missing $PIN_FILE" >&2
  exit 1
fi

VERSION="$(grep '^version=' "$PIN_FILE" | head -1 | cut -d= -f2)"
SHA512="$(grep '^sha512=' "$PIN_FILE" | head -1 | cut -d= -f2 || true)"

if [[ -z "$VERSION" ]]; then
  echo "fetch_webview2.sh: webview2.pinned.txt has no version= line" >&2
  exit 1
fi

LIB_PATH="$DEST/WebView2Loader.dll.lib"
if [[ -f "$LIB_PATH" && "$FORCE" -ne 1 ]]; then
  echo "fetch_webview2.sh: $LIB_PATH already exists (pass --force to refresh)"
  exit 0
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/${VERSION}"
NUPKG="$TMP/webview2.nupkg"

echo "fetch_webview2.sh: downloading $URL"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$NUPKG"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$URL" -O "$NUPKG"
else
  echo "fetch_webview2.sh: need curl or wget" >&2
  exit 1
fi

if [[ -n "$SHA512" ]]; then
  echo "fetch_webview2.sh: verifying SHA-512 against pin"
  ACTUAL="$(openssl dgst -sha512 -binary "$NUPKG" | base64 | tr -d '\n')"
  if [[ "$ACTUAL" != "$SHA512" ]]; then
    echo "fetch_webview2.sh: SHA mismatch" >&2
    echo "  expected: $SHA512" >&2
    echo "  actual:   $ACTUAL" >&2
    exit 1
  fi
else
  echo "fetch_webview2.sh: WARNING — webview2.pinned.txt has no sha512= value, skipping verification"
fi

# The .nupkg is a zip. Unpack and pluck the x64 loader lib.
unzip -qq -o "$NUPKG" -d "$TMP/unpacked"
SRC_LIB="$TMP/unpacked/build/native/x64/WebView2Loader.dll.lib"
SRC_DLL="$TMP/unpacked/build/native/x64/WebView2Loader.dll"
if [[ ! -f "$SRC_LIB" ]]; then
  echo "fetch_webview2.sh: extracted package missing $SRC_LIB" >&2
  exit 1
fi

cp "$SRC_LIB" "$DEST/WebView2Loader.dll.lib"
if [[ -f "$SRC_DLL" ]]; then
  cp "$SRC_DLL" "$DEST/WebView2Loader.dll"
fi

echo "fetch_webview2.sh: installed WebView2 ${VERSION} into $DEST"
