#!/usr/bin/env bash
#
# swiftplay headless smoke — rackmind-macos Fleet Map (RAC-443).
#
# Navigates to the Fleet Map page (an interactive 3D topology graph rendered in a
# WKWebView via the vendored, offline 3d-force-graph asset) and asserts the app
# stays alive. The point is to catch a crash-on-mount in the WKWebView host or the
# JS data bridge before users hit it — the WebKit/WKScriptMessageHandler boundary
# is exactly the kind of surface XCTest can't exercise (no TCC in CI, RAC-320).
#
# Runs fully headless: the app is launched hidden/background via `swiftplay
# launch`, every input is delivered to its pid, and focus never leaves your
# current app. Nothing appears on screen.
#
# Requirements: swiftplay built, RackMind.app built (make build), Accessibility
# granted to the terminal. See README.md.
#
set -uo pipefail

BUNDLE="ai.rackmind.macos"
SWIFTPLAY="${SWIFTPLAY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/swiftplay}"
APP="${RACKMIND_APP:-$HOME/development/rackmind/rackmind-macos/DerivedData/Build/Products/Debug/RackMind.app}"
SUPPORT="$HOME/Library/Application Support/RackMind"

pass=0; fail=0
PID=""

step() { # step <seconds> <cmd...>
  local secs="$1"; shift
  "$@" & local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) & local watch_pid=$!
  wait "$cmd_pid" 2>/dev/null; local rc=$?
  kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
  return $rc
}

alive() { # alive <label> — assert the app process is still running
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "  ✓ survived: $1"; pass=$((pass+1))
  else
    echo "  ✗ CRASHED at: $1"; fail=$((fail+1))
  fi
}

# --- Single-run lock (shared with the other smoke scripts).
LOCK="/tmp/swiftplay-rackmind.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another swiftplay run holds $LOCK — refusing to run concurrently." >&2
  exit 1
fi

# --- Setup: seed a throwaway server so the app boots into MainView, not onboarding.
seeded=0
if [ -d "$SUPPORT" ]; then
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
  defaults delete "$BUNDLE" ApplePersistenceIgnoreState 2>/dev/null
  if [ "$seeded" = 1 ] && [ -f "$SUPPORT/servers.json.swiftplay-bak" ]; then
    mv -f "$SUPPORT/servers.json.swiftplay-bak" "$SUPPORT/servers.json"
  fi
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT

pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null; sleep 1
"$SWIFTPLAY" launch --path "$APP"; sleep 5
PID=$(pgrep -f 'RackMind.app/Contents/MacOS/RackMind' | head -1)

echo "swiftplay headless smoke — Fleet Map"
echo "------------------------------------"
alive "launch (hidden)"

# Open the Fleet Map page and let the WKWebView + 3d-force-graph asset mount.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-fleetMap" >/dev/null 2>&1
sleep 2
alive "nav-fleetMap (WKWebView mounted)"

# Linger on the page — the page runs a fly-in + auto-orbit timer loop and the JS
# data bridge; give it time to settle and assert no delayed crash.
sleep 2
alive "fleet map settled"

# Navigate away and back to exercise teardown + remount of the web view.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-dashboard" >/dev/null 2>&1; sleep 0.7
alive "nav-dashboard (fleet map torn down)"
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-fleetMap" >/dev/null 2>&1; sleep 1.5
alive "nav-fleetMap (remounted)"

echo "------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
