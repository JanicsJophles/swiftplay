#!/usr/bin/env bash
#
# swiftplay headless smoke — RAC-448: chat layout must survive a heavy tool-output
# stream without collapsing the NavigationSplitView sidebar column.
#
# During a long agent deploy, a tool-call card rendering a multi-KB SINGLE-LINE
# JSON result (a `list_templates` blob) + a long single-line command-args input
# (a `create_lxc_container` call) reported an intrinsic width far wider than the
# detail column. Without `fixedSize(horizontal:false, vertical:true)` forcing the
# monospaced Text to wrap, that oversized ideal width propagated up through the
# message LazyVStack into the split-view column-width negotiation and STARVED the
# pinned sidebar column — it collapsed to the top-left of the window. Fixed by
# wrapping the tool-card text at the source (ToolCallCard) + clamping the detail
# column as a structural backstop (MainView). The SwiftUI view-graph layout can't
# be exercised by the XCTest layer (no TCC in CI — RAC-320), so this is the
# runtime proof.
#
# A keyless smoke box can't drive a real deploy, so this uses the DEBUG-only
# `RACKMIND_SEED_DEMO_TOOLCALL` env (honored only in DEBUG builds) to seed a
# conversation containing exactly that intrinsic-width bomb on launch. `open`
# propagates this process's environment to the launched app.
#
# What it asserts headlessly:
#   1. The app launches + survives with the bomb seeded (rendering a multi-KB
#      single-line tool result in the live SwiftUI view graph didn't crash).
#   2. The chat surface is reachable and survives (the tool card mounted).
#   3. The sidebar nav items stay locatable — the split view kept its sidebar
#      column populated instead of collapsing it away. (If the column had been
#      starved to a sliver, these would drop out of / mislocate in the AX tree.)
#
# swiftplay's known Tab/focus-key gap → drive with `click --ax`, never keyboard.
# Runs fully headless via `swiftplay launch --offscreen`.
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

echo "swiftplay headless smoke — RAC-448 heavy-tool-output layout (sidebar must hold)"
echo "------------------------------------------------------------------------------"

export RACKMIND_SEED_DEMO_TOOLCALL=1
pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null; sleep 1
"$SWIFTPLAY" launch --offscreen --path "$APP" 2>/dev/null || "$SWIFTPLAY" launch --path "$APP"
sleep 5
PID=$(pgrep -f 'RackMind.app/Contents/MacOS/RackMind' | head -1)
echo "  (RACKMIND_SEED_DEMO_TOOLCALL=1 — seeded a multi-KB single-line tool result + long command args)"
alive "launch (offscreen, intrinsic-width bomb seeded)"

# Land on the chat surface — the seeded tool card renders here.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 1
alive "nav-chat (heavy tool card mounted in live view graph)"

# The split view must keep its sidebar column populated, NOT collapse it. If the
# detail column's intrinsic width had starved the sidebar, these nav items would
# drop out of / mislocate in the AX tree.
found 8 "nav-chat" "sidebar: Chat"
found 8 "nav-dashboard" "sidebar: Dashboard"
found 8 "nav-knowledge" "sidebar: Knowledge"
alive "sidebar column intact after rendering the bomb"

echo "------------------------------------------------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
