#!/usr/bin/env bash
#
# swiftplay headless smoke sweep — rackmind-macos.
#
# Walks every sidebar page and every Settings tab by AX-pressing their stable
# identifiers, and after each step asserts the app is STILL ALIVE. The point is
# to catch macOS-26.x SwiftUI/Observation crashes-on-mount (the class of bug that
# was RAC-328, where ⌘K's @Environment overlay assertion killed the app) before
# users hit them.
#
# Runs fully headless: the app is launched hidden/background via `swiftplay
# launch`, every input is delivered to its pid, and focus never leaves your
# current app. Nothing appears on screen.
#
# Requirements: swiftplay built (xcrun --toolchain XcodeDefault), RackMind.app
# built (make build), Accessibility granted to the terminal. See README.md.
#
set -uo pipefail

BUNDLE="ai.rackmind.macos"
SWIFTPLAY="${SWIFTPLAY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/swiftplay}"
APP="${RACKMIND_APP:-$HOME/development/rackmind/rackmind-macos/DerivedData/Build/Products/Debug/RackMind.app}"
SUPPORT="$HOME/Library/Application Support/RackMind"

pass=0; fail=0
PID=""

# Per-step timeout watchdog (portable; macOS has no timeout(1)). Belt-and-braces
# on top of swiftplay's own AX/SCK timeouts so no step can wedge the sweep.
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

# --- Single-run lock. Overlapping runs once clobbered a real servers.json (a
# second run backed up the first's dummy over the real backup). Atomic mkdir
# lock makes concurrent runs impossible.
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
  defaults delete "$BUNDLE" ApplePersistenceIgnoreState 2>/dev/null  # RAC-432: launch set it to force the content window; don't leave it on the user's prefs
  if [ "$seeded" = 1 ] && [ -f "$SUPPORT/servers.json.swiftplay-bak" ]; then
    mv -f "$SUPPORT/servers.json.swiftplay-bak" "$SUPPORT/servers.json"
  fi
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT

pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null; sleep 1
"$SWIFTPLAY" launch --path "$APP"; sleep 5
PID=$(pgrep -f 'RackMind.app/Contents/MacOS/RackMind' | head -1)

echo "swiftplay headless smoke sweep"
echo "------------------------------"
alive "launch (hidden)"

# Every sidebar page (identifiers from RAC-327).
for page in chat dashboard audit securityAudit terminal knowledge alerts settings; do
  step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-$page" >/dev/null 2>&1
  sleep 0.7
  alive "nav-$page"
done

# Every Settings tab (we're on the Settings page after the loop above).
for tab in account general credentials servers ai agent-rules skills advanced audit-log updates; do
  step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "settings-tab-$tab" >/dev/null 2>&1
  sleep 0.7
  alive "settings-tab-$tab"
done

# RAC-458: container-detail must never "stick" across page changes. The detail
# is pushed onto DashboardView's NavigationStack; navigating to another page must
# pop it. We can't push a real detail here (no live Proxmox = no containers to
# tap), but we CAN assert the regression guard: a container-detail tab
# (`container-tab-overview`) must NOT be reachable on any non-dashboard page, and
# the dashboard must still mount cleanly on re-entry after the refactor that
# hoisted the path onto AppState. The mechanism itself is covered deterministically
# by AppStateNavigationTests (make check).
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-dashboard" >/dev/null 2>&1; sleep 0.7
alive "nav-dashboard (re-entry after refactor)"
# A container-detail tab must NOT be present on the dashboard root (no detail pushed).
if "$SWIFTPLAY" find --ax -b "$BUNDLE" -t "container-tab-overview" >/dev/null 2>&1; then
  echo "  ✗ stale container detail present on dashboard root"; fail=$((fail+1))
else
  echo "  ✓ dashboard root shows the list, not a stale detail"; pass=$((pass+1))
fi
# Leaving the dashboard for another page must not leave a detail tab reachable.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-alerts" >/dev/null 2>&1; sleep 0.7
if "$SWIFTPLAY" find --ax -b "$BUNDLE" -t "container-tab-overview" >/dev/null 2>&1; then
  echo "  ✗ container detail leaked onto the Alerts page"; fail=$((fail+1))
else
  echo "  ✓ no container detail leaked onto Alerts"; pass=$((pass+1))
fi

# Back to chat, exercise the skill picker open/dismiss once more.
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.5
step 15 "$SWIFTPLAY" type "/" -b "$BUNDLE"; sleep 0.5
alive "open skill picker"
step 15 "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "skill-row-/monitor" >/dev/null 2>&1; sleep 0.5
alive "complete skill via AX-press"

echo "------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
