#!/bin/zsh
# Level-3 smoke harness for the scaffolded desktop app.
#
# The app is launched with `--smoke <dir>`, which makes the bridge JS
# load `index.html?smoke=1` and drive a deterministic interaction
# sequence after hydration: click the IPC ping button, click the
# increment_counter button, then post a `smoke_done` IPC message with
# a checksum (document.body.innerText.length). The Zig smoke_done
# handler captures a PNG snapshot of the WKWebView via
# `Window.takeSnapshotPng`, writes the checksum to `<dir>/checksum.txt`,
# and terminates the app.
#
# This script then diffs the produced checksum against
# `tests/golden/checksum.txt`. PNG comparison is not enforced (renders
# vary across machines / macOS versions / display scales); the shot
# is kept for human inspection.
#
# Usage:
#   tools/smoke_macos.sh <app-binary> [output-dir]
#
# Exit codes:
#   0  PASS — checksum matches golden
#   1  FAIL — checksum mismatch
#   2  FAIL — no snapshot produced
#   64 usage error
#   65 first run — golden captured, commit it

set -euo pipefail

APP="${1:-}"
OUT_DIR="${2:-./.smoke}"
GOLDEN_DIR="${SMOKE_GOLDEN_DIR:-./tests/golden}"
SHOT="$OUT_DIR/shot.png"
CKSUM="$OUT_DIR/checksum.txt"
GOLDEN_CKSUM="$GOLDEN_DIR/checksum.txt"
APP_TIMEOUT_SECS="${SMOKE_APP_TIMEOUT:-6}"

if [[ -z "$APP" || ! -x "$APP" ]]; then
  echo "smoke: usage: $0 <app-binary> [output-dir]" >&2
  exit 64
fi

mkdir -p "$OUT_DIR"
rm -f "$SHOT" "$CKSUM"

# Run the app under --smoke; it self-terminates when smoke_done fires.
# Cap with a hard timeout in case the bridge driver hangs before it
# can post smoke_done.
"$APP" --smoke "$OUT_DIR" &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true' EXIT

# Poll for completion or timeout.
DEADLINE=$(($(date +%s) + APP_TIMEOUT_SECS))
while kill -0 "$APP_PID" 2>/dev/null; do
  if [[ $(date +%s) -ge $DEADLINE ]]; then
    echo "smoke: FAIL — app didn't exit within ${APP_TIMEOUT_SECS}s" >&2
    exit 2
  fi
  sleep 0.1
done
wait "$APP_PID" 2>/dev/null || true

# The checksum is the deterministic assertion and is REQUIRED; a missing
# checksum means the app never reached smoke_done (hydration / IPC / hang).
# The PNG snapshot is best-effort — a headless CI runner (no display) can't
# snapshot the WKWebView, so shot.png may be absent; validate the checksum
# regardless (PNG comparison is not enforced anyway).
if [[ ! -f "$CKSUM" ]]; then
  echo "smoke: FAIL — checksum.txt missing (app never reached smoke_done)" >&2
  echo "       Check console output for hydration / IPC / snapshot errors." >&2
  exit 2
fi
if [[ ! -f "$SHOT" ]]; then
  echo "smoke: WARN — shot.png missing (headless snapshot unavailable); validating checksum only" >&2
fi

# First run: capture the golden + tell the caller to commit it.
if [[ ! -f "$GOLDEN_CKSUM" ]]; then
  mkdir -p "$GOLDEN_DIR"
  cp "$CKSUM" "$GOLDEN_CKSUM"
  [[ -f "$SHOT" ]] && cp "$SHOT" "$GOLDEN_DIR/shot.png"
  echo "smoke: captured initial golden at $GOLDEN_DIR; commit it" >&2
  exit 65
fi

ACTUAL=$(cat "$CKSUM")
EXPECTED=$(cat "$GOLDEN_CKSUM")
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "smoke: FAIL — checksum mismatch (actual=$ACTUAL expected=$EXPECTED)" >&2
  echo "       Compare $SHOT vs $GOLDEN_DIR/shot.png by eye." >&2
  exit 1
fi

echo "smoke: PASS — checksum=$ACTUAL matches golden ($GOLDEN_CKSUM)"
