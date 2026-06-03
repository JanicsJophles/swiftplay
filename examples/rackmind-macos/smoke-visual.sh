#!/usr/bin/env bash
#
# swiftplay headless VISUAL sweep — rackmind-macos.
#
# Drives every sidebar page and every Settings tab, and captures a PNG of each
# surface — a full screenshot catalog of the app with zero in-app harness (no
# SwiftUI ImageRenderer, no XCUITest snapshot). It's the visual sibling of
# smoke-nav.sh: that one asserts "didn't crash", this one asserts "rendered, and
# here's the proof".
#
# Runs fully headless via `swiftplay launch --offscreen`: the window renders (so
# ScreenCaptureKit has a backing store to capture) but is parked off every
# display, so it never appears on screen and focus never leaves your current
# app. Each capture is sanity-checked for size to catch a blank/never-rendered
# window.
#
# Output PNGs land in $SHOTS (default: a timestamped dir under /tmp). Override:
#   SHOTS=~/Desktop/rackmind-shots ./smoke-visual.sh
#
# Requirements: swiftplay built (xcrun --toolchain XcodeDefault), RackMind.app
# built (make build), Accessibility AND Screen Recording granted to the
# terminal. See README.md.
#
set -uo pipefail

BUNDLE="ai.rackmind.macos"
SWIFTPLAY="${SWIFTPLAY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/swiftplay}"
APP="${RACKMIND_APP:-$HOME/development/rackmind/rackmind-macos/DerivedData/Build/Products/Debug/RackMind.app}"
SUPPORT="$HOME/Library/Application Support/RackMind"
SHOTS="${SHOTS:-/tmp/rackmind-visual}"
MIN_BYTES="${MIN_BYTES:-20000}"   # a real rendered window is >200KB; blank captures are tiny.

pass=0; fail=0
PID=""
mkdir -p "$SHOTS"

# Per-step timeout (defense-in-depth on top of swiftplay's own AX/SCK timeouts):
# no single driving step may wedge the whole sweep. macOS has no `timeout(1)`, so
# this is a portable pure-bash watchdog.
step() { # step <seconds> <cmd...>
  local secs="$1"; shift
  "$@" & local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) & local watch_pid=$!
  wait "$cmd_pid" 2>/dev/null; local rc=$?
  kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
  return $rc
}

shoot() { # shoot <surface-name> — screenshot the current surface, verify it's not blank
  local name="$1" out="$SHOTS/$1.png"
  step 35 "$SWIFTPLAY" screenshot -b "$BUNDLE" -o "$out" >/dev/null 2>&1
  local bytes; bytes=$(stat -f%z "$out" 2>/dev/null || echo 0)
  if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
    echo "  ✗ CRASHED at: $name"; fail=$((fail+1))
  elif [ "$bytes" -ge "$MIN_BYTES" ]; then
    echo "  ✓ $name → $name.png (${bytes} B)"; pass=$((pass+1))
  else
    echo "  ✗ blank/missing: $name (${bytes} B, want ≥${MIN_BYTES})"; fail=$((fail+1))
  fi
}

# --- Single-run lock. Overlapping runs are what once clobbered a real
# servers.json: a second run backed up the first run's dummy over the real
# backup. An atomic mkdir lock makes concurrent runs impossible.
LOCK="/tmp/swiftplay-rackmind.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another swiftplay run holds $LOCK — refusing to run concurrently." >&2
  exit 1
fi

# --- Setup: seed a throwaway server so the app boots into MainView, not onboarding.
seeded=0
if [ -d "$SUPPORT" ]; then
  # Back up ONLY a real config, and NEVER over an existing backup — so the dummy
  # can never overwrite a real servers.json backup.
  if [ -f "$SUPPORT/servers.json" ] && [ ! -f "$SUPPORT/servers.json.swiftplay-bak" ] \
     && ! grep -q swiftplay-dummy "$SUPPORT/servers.json" 2>/dev/null; then
    cp "$SUPPORT/servers.json" "$SUPPORT/servers.json.swiftplay-bak"
  fi
  cat > "$SUPPORT/servers.json" <<'JSON'
[{"id":"swiftplay-dummy","name":"swiftplay (temp)","host":"127.0.0.1","port":8006,"username":"root","realm":"pam","allowInsecure":true,"sshAuthMethod":"password","authMode":"password","ragServerURL":"http://127.0.0.1:3100"}]
JSON
  seeded=1
fi
cleanup() {
  pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null
  pkill -f "hold-display" 2>/dev/null
  if [ "$seeded" = 1 ] && [ -f "$SUPPORT/servers.json.swiftplay-bak" ]; then
    mv -f "$SUPPORT/servers.json.swiftplay-bak" "$SUPPORT/servers.json"
  fi
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT

pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null; sleep 1
"$SWIFTPLAY" launch --offscreen --path "$APP"; sleep 5
PID=$(pgrep -f 'RackMind.app/Contents/MacOS/RackMind' | head -1)

echo "swiftplay headless visual sweep → $SHOTS"
echo "------------------------------------------"

# Every sidebar page (identifiers from RAC-327).
for page in chat dashboard audit terminal knowledge alerts settings; do
  step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-$page" >/dev/null 2>&1
  sleep 0.8
  shoot "$page"
done

# Every Settings tab (we're on the Settings page after the loop above).
for tab in account general credentials servers ai agent-rules skills advanced audit-log updates; do
  step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "settings-tab-$tab" >/dev/null 2>&1
  sleep 0.8
  shoot "settings-$tab"
done

echo "------------------------------------------"
echo "pass=$pass fail=$fail   shots in: $SHOTS"
echo "frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)"
[ "$fail" = 0 ]
