#!/usr/bin/env bash
# Level-1 smoke harness for Linux. Runs the desktop app under Xvfb so
# a windowing system isn't required (CI runners typically don't ship
# one), captures the virtual display via `import` (ImageMagick), and
# validates that the resulting PNG is non-trivial.
#
# Usage:
#   tools/smoke_linux.sh <app-binary> [output-dir]
#
# Required packages:
#   xvfb (X virtual framebuffer)
#   imagemagick OR scrot OR grim (capture)
#   libwebkit2gtk-4.1, libgtk-3 (the app itself)

set -euo pipefail

APP="${1:-}"
OUT_DIR="${2:-./.smoke}"
SHOT="$OUT_DIR/shot.png"
MIN_BYTES="${SMOKE_MIN_BYTES:-5000}"
WAIT_SECS="${SMOKE_WAIT_SECS:-2}"
DISPLAY_NUM="${SMOKE_DISPLAY:-:99}"

if [[ -z "$APP" || ! -x "$APP" ]]; then
  echo "smoke: usage: $0 <app-binary> [output-dir]" >&2
  exit 64
fi
command -v Xvfb >/dev/null || { echo "smoke: install xvfb"; exit 70; }

mkdir -p "$OUT_DIR"

Xvfb "$DISPLAY_NUM" -screen 0 1280x800x24 &
XVFB_PID=$!
trap '[[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true; kill "$XVFB_PID" 2>/dev/null || true' EXIT

# Wait for the X server to actually accept connections before launching the
# app — a fixed `sleep` races on cold CI runners (Xvfb is still loading the
# keymap when the app calls gtk_init_check, which then blocks/fails). The unix
# socket /tmp/.X11-unix/X<N> appears once Xvfb is listening.
xvfb_sock="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
for _ in $(seq 1 100); do
  [[ -S "$xvfb_sock" ]] && break
  # Bail early if Xvfb died (e.g. display already in use).
  kill -0 "$XVFB_PID" 2>/dev/null || { echo "smoke: FAIL — Xvfb exited during startup" >&2; exit 71; }
  sleep 0.1
done
[[ -S "$xvfb_sock" ]] || { echo "smoke: FAIL — Xvfb not ready after 10s" >&2; exit 71; }

# Headless rendering: Xvfb has no GPU, so webkit2gtk's default DMA-BUF/DRI3
# GL renderer can't get a device ("libEGL DRI3 error") and the WebView never
# composites — the window is created but never shown. Disable the DMA-BUF
# renderer and force software GL so webkit falls back to a path that works
# without a GPU.
DISPLAY="$DISPLAY_NUM" \
  WEBKIT_DISABLE_DMABUF_RENDERER=1 \
  WEBKIT_DISABLE_COMPOSITING_MODE=1 \
  LIBGL_ALWAYS_SOFTWARE=1 \
  GALLIUM_DRIVER=llvmpipe \
  ZIG_LOG_LEVEL=debug "$APP" >"$OUT_DIR/app.log" 2>&1 &
APP_PID=$!

sleep "$WAIT_SECS"

# Confirm the app is still alive — a crashed app indicates a real bug.
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "smoke: FAIL — app exited early. Log:" >&2
  tail -40 "$OUT_DIR/app.log" >&2
  exit 1
fi

# Capture. Prefer `import` (ImageMagick), fall back to `scrot`.
if command -v import >/dev/null; then
  DISPLAY="$DISPLAY_NUM" import -window root "$SHOT"
elif command -v scrot >/dev/null; then
  DISPLAY="$DISPLAY_NUM" scrot "$SHOT"
else
  echo "smoke: install imagemagick or scrot for capture" >&2
  exit 70
fi

# Validate expected log markers from the Linux backend.
grep -q "verve.desktop\[linux\]: window shown" "$OUT_DIR/app.log" \
  || { echo "smoke: FAIL — missing 'window shown' log line" >&2; tail -20 "$OUT_DIR/app.log" >&2; exit 1; }

SIZE=$(stat -c%s "$SHOT")
if (( SIZE < MIN_BYTES )); then
  echo "smoke: FAIL — capture too small ($SIZE B < $MIN_BYTES)" >&2
  exit 1
fi

echo "smoke: PASS — $SHOT ($SIZE B)"
