#!/usr/bin/env bash
#
# swiftplay headless smoke — RAC-387 Wave 2 token-budget awareness.
#
# Exercises the surfaces touched by the macOS token-budget slice:
#   1. The chat composer survives typing a multi-step request — the kind of
#      prompt that, with a live model, drives several tool calls and makes the
#      context gauge advance turn over turn.
#   2. The streaming status bar (where the `chat-context-gauge` indicator lives,
#      AX id `chat-context-gauge`) mounts without crashing the chat surface.
#   3. A round-trip across surfaces (chat → dashboard → chat) doesn't wedge the
#      app after the new ContextUsage event plumbing was added to ChatStore.
#
# The gauge only renders WHILE a turn is streaming against a live Anthropic key
# (it reads real `usage.input_tokens` off the SSE stream), and a multi-tool run
# needs a real Proxmox host, so the authoritative functional assertions —
# estimator parity with Electron, ContextUsage arithmetic, the 4096→8192 bump —
# live in RackMindTests/ContextUsageTests.swift (run by `make check`). This
# smoke is the headless crash-sweep over the same surfaces: "rendered +
# survived" on top of the unit proof. When the gauge id is present (a streaming
# run happened to be live), we assert it too — otherwise we note it as skipped.
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

# --- Seed a throwaway server so the app boots into MainView. Back up ONLY a
# real config, NEVER over an existing backup, and NEVER back up our own dummy.
seeded=0
if [ -d "$SUPPORT" ]; then
  if [ -f "$SUPPORT/servers.json" ] && [ ! -f "$SUPPORT/servers.json.swiftplay-bak" ] \
     && ! grep -q swiftplay-dummy "$SUPPORT/servers.json" 2>/dev/null; then
    cp "$SUPPORT/servers.json" "$SUPPORT/servers.json.swiftplay-bak"
  fi
  cat > "$SUPPORT/servers.json" <<'JSON'
[{"id":"swiftplay-dummy","name":"swiftplay (temp)","host":"127.0.0.1","port":8006,"username":"root","realm":"pam","allowInsecure":true,"sshAuthMethod":"password","authMode":"password","platform":"proxmox","ragServerURL":"http://127.0.0.1:3100"}]
JSON
  seeded=1
fi
cleanup() {
  pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null
  pkill -f "hold-display" 2>/dev/null
  defaults delete "$BUNDLE" ApplePersistenceIgnoreState 2>/dev/null  # RAC-432: launch set it to force the content window; don't leave it on the user's prefs
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

echo "swiftplay headless smoke — RAC-387 Wave 2 token-budget / context gauge"
echo "----------------------------------------------------------------------"
alive "launch (offscreen)"

# 1. Chat: type a multi-step request that would drive several tool calls (the
#    workload that makes the gauge advance turn over turn).
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.7
alive "nav-chat"
step 15 "$SWIFTPLAY" type "list all containers, then check disk usage on each, then summarize" -b "$BUNDLE" >/dev/null 2>&1
sleep 0.5
alive "type multi-step request into composer"

# 2. The context gauge control. It only renders while a turn is actively
#    streaming against a live key, so its absence on a keyless smoke box is
#    expected (skip, not fail). When present, assert it's locatable by AX id.
if step 8 "$SWIFTPLAY" find -t "chat-context-gauge" -b "$BUNDLE" >/dev/null 2>&1; then
  echo "  ✓ found: chat-context-gauge (a streaming turn was live)"; pass=$((pass+1))
else
  echo "  ⊘ skipped: chat-context-gauge not present (no live streaming turn — expected without an API key)"
fi

# 3. Round-trip across surfaces — confirm the new ContextUsage event plumbing in
#    ChatStore didn't wedge anything.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-dashboard" >/dev/null 2>&1; sleep 0.5
alive "nav-dashboard"
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.5
alive "return to chat"

echo "----------------------------------------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
