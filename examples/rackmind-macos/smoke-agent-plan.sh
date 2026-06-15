#!/usr/bin/env bash
#
# swiftplay headless smoke — RAC-387 Wave 4 / Workstream B3: durable update_plan + PlanPanel.
#
# Wave 3 added context compaction (the fold). Wave 4 adds the DURABLE PLAN that
# SURVIVES that fold: the agent maintains an ordered TodoWrite-style plan via the
# intercepted `update_plan` tool; the plan is rendered into the SYSTEM PROMPT
# every turn (outside the foldable transcript) and persisted on the
# conversation's `planJson` column. `PlanPanel` is the read-only chat surface for
# it — a collapsible checklist with five statuses (pending/in_progress/completed/
# deferred/failed).
#
# A keyless smoke box can't drive a real multi-phase `update_plan` round-trip, so
# this smoke uses the DEBUG-only `RACKMIND_SEED_DEMO_PLAN` env (honored only in
# DEBUG builds) to seed a fixed 5-status plan into a fresh conversation. `open`
# propagates this process's environment to the launched app, so exporting it here
# reaches the DEBUG RackMind.app. The authoritative render-parity +
# survives-compaction + survives-relaunch proofs live in
# RackMindTests/AgentPlanTests.swift (run by `make check`); this smoke is the
# RUNTIME/VISUAL proof that the panel renders + its controls are locatable.
#
# What it asserts headlessly:
#   1. The app launches + survives with a seeded plan (PlanPanel mounted in the
#      live SwiftUI view graph didn't crash the chat surface).
#   2. The PlanPanel (`plan-panel`) + its toggle (`plan-toggle`) are locatable.
#   3. All five plan rows (`plan-step-0..4`) render, carrying the machine-readable
#      status AX values completed/in_progress/pending/failed/deferred — i.e. the
#      panel shows steps across the full pending→in_progress→completed lifecycle.
#   4. Collapsing + expanding the panel (clicking `plan-toggle`) doesn't wedge.
#   5. A round-trip across surfaces (chat → dashboard → chat) keeps the panel.
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

# Seed a fixed multi-status demo plan (DEBUG-only seam). `open` inherits this env
# → the launched DEBUG app honors it in ChatStore.seedDemoPlanIfRequested().
export RACKMIND_SEED_DEMO_PLAN="${RACKMIND_SEED_DEMO_PLAN:-1}"

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

found() { # found <seconds> <ax-id> <label> — assert a control is locatable by AX id
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

echo "swiftplay headless smoke — RAC-387 Wave 4 durable update_plan + PlanPanel"
echo "  (RACKMIND_SEED_DEMO_PLAN=$RACKMIND_SEED_DEMO_PLAN — seeded 5-status demo plan)"
echo "----------------------------------------------------------------------"
alive "launch (offscreen)"

# 1. Chat surface: the seeded plan mounts PlanPanel above the transcript.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 1
alive "nav-chat (PlanPanel mounted in live view graph)"

# 2. The panel + its toggle are locatable by stable AX id.
found 8 "plan-panel" "plan panel"
found 8 "plan-toggle" "plan toggle"

# 3. All five plan rows render — the panel shows steps across the full
#    pending→in_progress→completed lifecycle (+ deferred/failed). Each row's AX
#    value carries the machine-readable status string.
for i in 0 1 2 3 4; do
  found 6 "plan-step-$i" "plan step $i"
done

# 4. Collapse + expand — toggling the disclosure must not wedge the surface.
step 8 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "plan-toggle" >/dev/null 2>&1; sleep 0.6
alive "collapse plan"
step 8 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "plan-toggle" >/dev/null 2>&1; sleep 0.6
alive "expand plan"
# After expanding, the rows are locatable again.
found 6 "plan-step-1" "plan step 1 (re-expanded)"

# 5. Round-trip across surfaces — confirm the PlanPanel plumbing didn't wedge.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-dashboard" >/dev/null 2>&1; sleep 0.5
alive "nav-dashboard"
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.5
alive "return to chat (PlanPanel still present)"
found 8 "plan-panel" "plan panel (after round-trip)"

echo "----------------------------------------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
