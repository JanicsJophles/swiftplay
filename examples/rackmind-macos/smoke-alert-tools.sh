#!/usr/bin/env bash
#
# swiftplay headless smoke — RAC-387 alert tools + platform tool-filtering.
#
# Exercises the surfaces touched by the macOS tool-breadth parity slice:
#   1. Chat composer survives typing the canonical alert request
#      ("create an alert when container 100 CPU > 80%") — the prompt that, with
#      a live model + Proxmox, drives the new `create_alert` tool card.
#   2. The Alerts surface mounts and stays alive (where a created rule renders
#      as an `alert-rule-<id>` card).
#   3. A linux-typed server config round-trips through the app without crashing
#      — the platform field that gates Proxmox-only tools out of buildToolDefinitions.
#
# The end-to-end agent round-trip (tool card actually rendering, alert row
# actually appearing, linux server getting no create_lxc tool) needs a live
# Anthropic key + Proxmox host, so the authoritative functional assertions live
# in RackMindTests/AgentToolBreadthTests.swift (run by `make check`). This smoke
# is the headless crash-sweep over the same surfaces — "rendered + survived" on
# top of the unit proof.
#
# Runs fully headless: app launched via `swiftplay launch --offscreen`; the
# window renders on a headless virtual display and never appears on a physical
# screen. Focus never leaves your current app.
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

step() { # step <seconds> <cmd...> — per-step watchdog (macOS has no timeout(1))
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

# --- Single-run lock (a concurrent run once clobbered a real servers.json).
LOCK="/tmp/swiftplay-rackmind.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another swiftplay run holds $LOCK — refusing to run concurrently." >&2
  exit 1
fi

# --- Seed a throwaway LINUX-platform server so the app boots into MainView and
# the RAC-387 platform field is exercised on a real config decode. Back up ONLY
# a real config, NEVER over an existing backup, and NEVER back up our own dummy.
seeded=0
if [ -d "$SUPPORT" ]; then
  if [ -f "$SUPPORT/servers.json" ] && [ ! -f "$SUPPORT/servers.json.swiftplay-bak" ] \
     && ! grep -q swiftplay-dummy "$SUPPORT/servers.json" 2>/dev/null; then
    cp "$SUPPORT/servers.json" "$SUPPORT/servers.json.swiftplay-bak"
  fi
  cat > "$SUPPORT/servers.json" <<'JSON'
[{"id":"swiftplay-dummy","name":"swiftplay (temp)","host":"127.0.0.1","port":8006,"username":"root","realm":"pam","allowInsecure":true,"sshAuthMethod":"password","authMode":"password","platform":"linux","ragServerURL":"http://127.0.0.1:3100"}]
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
"$SWIFTPLAY" launch --offscreen --path "$APP" 2>/dev/null || "$SWIFTPLAY" launch --path "$APP"
sleep 5
PID=$(pgrep -f 'RackMind.app/Contents/MacOS/RackMind' | head -1)

echo "swiftplay headless smoke — RAC-387 alert tools + platform filter"
echo "----------------------------------------------------------------"
alive "launch (offscreen, linux-platform server seeded)"

# 1. Chat: type the canonical alert request into the composer.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.7
alive "nav-chat"
step 15 "$SWIFTPLAY" type "create an alert when container 100 CPU > 80%" -b "$BUNDLE" >/dev/null 2>&1
sleep 0.5
alive "type alert request into composer"

# 2. Alerts surface mounts + survives (where create_alert rules render).
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-alerts" >/dev/null 2>&1; sleep 0.7
alive "nav-alerts"
# The "New Alert" affordance must be present on the alerts surface.
if step 10 "$SWIFTPLAY" find -t "alerts-new-alert" -b "$BUNDLE" >/dev/null 2>&1; then
  echo "  ✓ found: alerts-new-alert"; pass=$((pass+1))
else
  echo "  ✗ MISSING: alerts-new-alert"; fail=$((fail+1))
fi

# 3. Back to chat — confirm the round-trip across surfaces didn't wedge anything.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.5
alive "return to chat"

echo "----------------------------------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
