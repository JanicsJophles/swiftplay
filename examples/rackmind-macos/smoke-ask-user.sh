#!/usr/bin/env bash
#
# swiftplay headless smoke — RAC-387 Wave 4 / Workstream B4: mid-run `ask_user`.
#
# The agent can call the `ask_user` tool to PAUSE mid-run and ask the user a
# structured question (confirm / select / text). The turn suspends on an
# AgentService continuation until the user answers; the `AskUserSheet` is the UI
# surface for it. This smoke is the RUNTIME/VISUAL proof that the sheet renders
# in the live SwiftUI view graph and its controls are locatable + drivable
# headlessly. The continuation suspend→answer→resume / cancel / timeout logic is
# proven by RackMindTests/AgentServiceAskUserTests.swift (run by `make check`).
#
# A keyless smoke box can't drive a real `ask_user` round-trip, so this smoke
# uses the DEBUG-only `RACKMIND_DEMO_ASK_USER` env (honored only in DEBUG builds)
# to surface a fixed question on launch. `open` propagates this process's
# environment to the launched app, so exporting it here reaches the DEBUG
# RackMind.app.
#
# What it asserts headlessly:
#   1. The app launches + survives with a demo ask_user surfaced (AskUserSheet
#      mounted in the live SwiftUI view graph didn't crash the chat surface).
#   2. The sheet's question + a control (confirm Yes) are locatable by AX id.
#   3. Driving the answer via `click --ax` (swiftplay's known Tab/focus gap means
#      we use --ax, not keyboard) dismisses the sheet and the run continues —
#      the app survives, no wedge.
#   4. Re-launching in `text` mode surfaces the text field + submit control.
#
# swiftplay's known Tab/focus-key gap → we drive the sheet buttons with
# `click --ax`, never Tab/keyboard.
#
# Runs fully headless via `swiftplay launch --offscreen`; the window renders on a
# headless virtual display and never appears on a physical screen.
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

found() { # found <seconds> <ax-id> <label> — assert a control is locatable
  if step "$1" "$SWIFTPLAY" find -t "$2" -b "$BUNDLE" >/dev/null 2>&1; then
    echo "  ✓ found: $3 ($2)"; pass=$((pass+1))
  else
    echo "  ✗ MISSING: $3 ($2)"; fail=$((fail+1))
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
  if [ "$seeded" = 1 ] && [ -f "$SUPPORT/servers.json.swiftplay-bak" ]; then
    mv -f "$SUPPORT/servers.json.swiftplay-bak" "$SUPPORT/servers.json"
  fi
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT

launch_app() { # launch_app <ask-user-mode>
  export RACKMIND_DEMO_ASK_USER="$1"
  pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null; sleep 1
  "$SWIFTPLAY" launch --offscreen --path "$APP" 2>/dev/null || "$SWIFTPLAY" launch --path "$APP"
  sleep 5
  PID=$(pgrep -f 'RackMind.app/Contents/MacOS/RackMind' | head -1)
}

echo "swiftplay headless smoke — RAC-387 Wave 4 ask_user mid-run human input"
echo "----------------------------------------------------------------------"

# === Phase 1: confirm question ===
launch_app "confirm"
echo "  (RACKMIND_DEMO_ASK_USER=confirm — seeded a yes/no question)"
alive "launch (offscreen, confirm)"

# Land on the chat surface (the sheet attaches there).
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 1
alive "nav-chat (AskUserSheet mounted in live view graph)"

# The question text + both confirm buttons are locatable by stable AX id.
found 8 "ask-user-question" "ask_user question"
found 8 "ask-user-confirm-yes" "confirm Yes button"
found 8 "ask-user-confirm-no" "confirm No button"

# Drive the answer via --ax (swiftplay Tab/focus gap → never keyboard). Clicking
# Yes resolves the question and dismisses the sheet; the run must continue.
step 8 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "ask-user-confirm-yes" >/dev/null 2>&1; sleep 1
alive "answer confirm (Yes) — run continues, no wedge"

# After answering, the sheet is gone — the question control is no longer present.
if step 6 "$SWIFTPLAY" find -t "ask-user-question" -b "$BUNDLE" >/dev/null 2>&1; then
  echo "  ✗ sheet still present after answering (ask-user-question)"; fail=$((fail+1))
else
  echo "  ✓ sheet dismissed after answering"; pass=$((pass+1))
fi

# === Phase 2: text question ===
launch_app "text"
echo "  (RACKMIND_DEMO_ASK_USER=text — seeded a free-form question)"
alive "launch (offscreen, text)"
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 1
alive "nav-chat (text-mode AskUserSheet)"
found 8 "ask-user-text" "text input field"
found 8 "ask-user-submit" "submit button"

echo "----------------------------------------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
