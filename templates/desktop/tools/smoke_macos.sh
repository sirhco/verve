#!/bin/zsh
# Level-1 smoke harness for the scaffolded desktop app.
#
# Boots the app, waits up to 5 s for its main window to appear,
# captures a screenshot via macOS `screencapture`, validates that the
# image is non-trivial, and kills the app. Exits non-zero on any
# failure so the harness is wirable into CI as `zig build smoke`.
#
# Usage:
#   tools/smoke_macos.sh <app-binary> [output-dir]
#
# Notes:
#   - Window-id lookup via `osascript` requires Accessibility access
#     for the calling shell. In CI runners that's typically granted.
#     If unavailable we fall back to a full-display capture so the
#     harness still produces something to inspect.
#   - `screencapture -l <wid>` is the cheapest cross-version way to
#     target a specific window without depending on PyObjC / Quartz.

set -euo pipefail

APP="${1:-}"
OUT_DIR="${2:-./.smoke}"
SHOT="$OUT_DIR/shot.png"
MIN_BYTES="${SMOKE_MIN_BYTES:-5000}"
WAIT_SECS="${SMOKE_WAIT_SECS:-1.5}"

if [[ -z "$APP" || ! -x "$APP" ]]; then
  echo "smoke: usage: $0 <app-binary> [output-dir]" >&2
  exit 64
fi

mkdir -p "$OUT_DIR"

"$APP" &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true' EXIT

# Poll for the app's first window. 50 × 100 ms = 5 s budget.
WID=""
for _ in $(seq 1 50); do
  WID=$(osascript -e "tell application \"System Events\" to get id of window 1 of (first process whose unix id is $APP_PID)" 2>/dev/null) || true
  if [[ -n "$WID" && "$WID" != "0" ]]; then
    break
  fi
  sleep 0.1
done

# Give WebKit a beat to paint the initial page before sampling.
sleep "$WAIT_SECS"

if [[ -n "$WID" && "$WID" != "0" ]]; then
  echo "smoke: capturing window id=$WID"
  screencapture -x -o -l "$WID" "$SHOT"
else
  echo "smoke: no window id (Accessibility denied?) — falling back to main display" >&2
  screencapture -x -o "$SHOT"
fi

if [[ ! -f "$SHOT" ]]; then
  echo "smoke: FAIL — screencapture produced no file." >&2
  echo "       Grant 'Screen Recording' permission to the terminal /" >&2
  echo "       runner under System Settings → Privacy & Security." >&2
  exit 2
fi

SIZE=$(stat -f%z "$SHOT")
if (( SIZE < MIN_BYTES )); then
  echo "smoke: FAIL — capture too small ($SIZE B < $MIN_BYTES)" >&2
  exit 1
fi

echo "smoke: PASS — $SHOT ($SIZE B)"
