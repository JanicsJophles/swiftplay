#!/usr/bin/env bash
#
# swiftplay headless smoke — RAC-387 Wave 3 context compaction.
#
# Wave 2 added the token-budget gauge; Wave 3 adds the FOLD: at ~70% of the
# model window the agent folds older completed turns into a Haiku-summarized
# digest, keeps the recent N verbatim, and never orphans a tool_use/tool_result
# pair. Before this slice a long run resent the full transcript every turn and
# eventually 400'd on context overflow.
#
# This smoke forces an EARLY fold via the DEBUG-only `RACKMIND_COMPACT_THRESHOLD`
# env (honored only in DEBUG builds) so we don't need a 60-minute conversation to
# exercise the path. `open` propagates this process's environment to the launched
# app, so exporting it here reaches the DEBUG RackMind.app.
#
# What it asserts headlessly:
#   1. The app launches + survives a LONG scripted multi-step chat run with the
#      compaction threshold forced very low — the kind of run that, uncompacted,
#      slams into the context wall and 400s. "Survived" = the fold path (driven
#      every turn) didn't crash the chat surface.
#   2. The context gauge control (`chat-context-gauge`) stays locatable across
#      the run. When a live Anthropic key produced a real streaming fold, the
#      gauge text carries "· compacted" — we assert that when present; otherwise
#      we note it skipped (expected on a keyless smoke box, where the
#      authoritative fold/pairing proof lives in RackMindTests/
#      ContextCompactorTests.swift run by `make check`).
#   3. A round-trip across surfaces (chat → dashboard → chat) doesn't wedge after
#      the new `.compactionDigest` event plumbing was added to ChatStore.
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

# Force an early compaction fold (DEBUG-only seam). `open` inherits this env →
# the launched DEBUG app honors it in effectiveCompactionThreshold().
export RACKMIND_COMPACT_THRESHOLD="${RACKMIND_COMPACT_THRESHOLD:-0.01}"

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

echo "swiftplay headless smoke — RAC-387 Wave 3 context compaction"
echo "  (RACKMIND_COMPACT_THRESHOLD=$RACKMIND_COMPACT_THRESHOLD — forced early fold)"
echo "----------------------------------------------------------------------"
alive "launch (offscreen)"

# 1. Chat: drive a LONG multi-step request — the workload that, uncompacted,
#    grows the transcript past the context wall. With the threshold forced near
#    zero, maybeCompact() runs before every turn; the surface must survive it.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.7
alive "nav-chat"
step 15 "$SWIFTPLAY" type "list every container, then for each one check disk, memory, network, uptime, package updates, and running services, then summarize the whole fleet" -b "$BUNDLE" >/dev/null 2>&1
sleep 0.5
alive "type long multi-step request (drives many turns → fold)"

# Send it. On a keyless box this lands an error event (no API key) rather than a
# real run, but the send path + ChatStore's new .compactionDigest case must not
# wedge the surface. We assert survival, not a completed run.
step 12 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "chat-send" >/dev/null 2>&1; sleep 2
alive "send (compaction path armed, threshold≈0)"

# 2. The context gauge. It only renders while a turn is actively streaming
#    against a live key; after a real fold its text carries "· compacted".
if step 8 "$SWIFTPLAY" find -t "chat-context-gauge" -b "$BUNDLE" >/dev/null 2>&1; then
  echo "  ✓ found: chat-context-gauge (a streaming turn was live)"; pass=$((pass+1))
  if step 8 "$SWIFTPLAY" find -t "compacted" -b "$BUNDLE" >/dev/null 2>&1; then
    echo "  ✓ gauge shows '· compacted' (a real fold occurred)"; pass=$((pass+1))
  else
    echo "  ⊘ gauge present but not yet compacted (fold needs >keepRecentTurns turns of live history)"
  fi
else
  echo "  ⊘ skipped: chat-context-gauge not present (no live streaming turn — expected without an API key)"
fi

# 3. Round-trip across surfaces — confirm the .compactionDigest plumbing in
#    ChatStore didn't wedge anything.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-dashboard" >/dev/null 2>&1; sleep 0.5
alive "nav-dashboard"
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.5
alive "return to chat (digest event plumbing intact)"

echo "----------------------------------------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
