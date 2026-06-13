#!/usr/bin/env bash
# Level-1 smoke harness for Linux. Runs the desktop app under Xvfb (so no real
# windowing system is needed — CI runners don't ship one) and verifies the app
# actually boots end-to-end by watching its debug log for ready markers:
#
#   - "window shown"            → GTK window created + mapped
#   - served "client.wasm"      → WebKit loaded the verve:// page and fetched
#                                 the app bundle, i.e. the WebView ran the app
#
# A screenshot is captured as a best-effort artifact, but its size is NOT a
# pass/fail gate: a GPU-less Xvfb with software GL frequently won't paint into
# the captured root even when the app renders fine, so a small PNG only warns.
#
# Usage:
#   tools/smoke_linux.sh <app-binary> [output-dir]
#
# Required packages:
#   xvfb (X virtual framebuffer)
#   libwebkit2gtk-4.1, libgtk-3 (the app itself)
#   imagemagick OR scrot (optional — screenshot artifact only)

set -euo pipefail

APP="${1:-}"
OUT_DIR="${2:-./.smoke}"
SHOT="$OUT_DIR/shot.png"
LOG="$OUT_DIR/app.log"
MIN_BYTES="${SMOKE_MIN_BYTES:-5000}"
READY_TIMEOUT="${SMOKE_READY_TIMEOUT:-30}" # seconds to wait for the ready markers
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

# Wait for the X server to actually accept connections before launching the app
# — a fixed sleep races on cold runners (Xvfb is still loading its keymap when
# the app calls gtk_init_check, which then blocks). The unix socket
# /tmp/.X11-unix/X<N> appears once Xvfb is listening.
xvfb_sock="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
for _ in $(seq 1 100); do
  [[ -S "$xvfb_sock" ]] && break
  kill -0 "$XVFB_PID" 2>/dev/null || { echo "smoke: FAIL — Xvfb exited during startup" >&2; exit 71; }
  sleep 0.1
done
[[ -S "$xvfb_sock" ]] || { echo "smoke: FAIL — Xvfb not ready after 10s" >&2; exit 71; }

# Headless rendering: Xvfb has no GPU. Disable WebKit's DMA-BUF/DRI3 renderer and
# force software GL (llvmpipe) so the WebView initialises without a device.
# NO_AT_BRIDGE silences the AT-SPI accessibility-bus warning (no session bus).
DISPLAY="$DISPLAY_NUM" \
  WEBKIT_DISABLE_DMABUF_RENDERER=1 \
  LIBGL_ALWAYS_SOFTWARE=1 \
  GALLIUM_DRIVER=llvmpipe \
  NO_AT_BRIDGE=1 \
  ZIG_LOG_LEVEL=debug "$APP" >"$LOG" 2>&1 &
APP_PID=$!

# Poll the log for the end-to-end ready markers (condition-based, not a fixed
# sleep): the WebView load + wasm fetch take a few seconds under software GL.
ready=0
for _ in $(seq 1 $((READY_TIMEOUT * 2))); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "smoke: FAIL — app exited early. Log:" >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
  # "window shown" matches both the gtk3 ([linux]) and gtk4 ([linux-gtk4])
  # backends; "client.wasm" proves the WebView served the app bundle.
  if grep -q "window shown" "$LOG" && grep -q "client.wasm" "$LOG"; then
    ready=1
    break
  fi
  sleep 0.5
done

if (( ready == 0 )); then
  echo "smoke: FAIL — app did not reach ready markers within ${READY_TIMEOUT}s" >&2
  echo "        (expected 'window shown' + a 'client.wasm' scheme request)" >&2
  tail -40 "$LOG" >&2
  exit 1
fi

# Best-effort screenshot artifact — NOT a pass/fail gate (software GL into a
# GPU-less Xvfb often won't paint the captured root even when the app renders).
if command -v import >/dev/null; then
  DISPLAY="$DISPLAY_NUM" import -window root "$SHOT" 2>/dev/null || true
elif command -v scrot >/dev/null; then
  DISPLAY="$DISPLAY_NUM" scrot "$SHOT" 2>/dev/null || true
fi
SIZE=$(stat -c%s "$SHOT" 2>/dev/null || echo 0)
if (( SIZE < MIN_BYTES )); then
  echo "smoke: note — screenshot is small (${SIZE} B < ${MIN_BYTES}); headless software render does not always paint the captured root. Not failing — ready markers passed." >&2
fi

echo "smoke: PASS — app booted, window shown, app bundle served (shot ${SIZE} B)"
