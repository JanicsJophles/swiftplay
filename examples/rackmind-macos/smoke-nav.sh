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

alive() { # alive <label> — assert the app process is still running
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "  ✓ survived: $1"; pass=$((pass+1))
  else
    echo "  ✗ CRASHED at: $1"; fail=$((fail+1))
  fi
}

# --- Setup: seed a throwaway server so the app boots into MainView, not onboarding.
seeded=0
if [ -d "$SUPPORT" ]; then
  cp -f "$SUPPORT/servers.json" "$SUPPORT/servers.json.swiftplay-bak" 2>/dev/null
  cat > "$SUPPORT/servers.json" <<'JSON'
[{"id":"swiftplay-dummy","name":"swiftplay (temp)","host":"127.0.0.1","port":8006,"username":"root","realm":"pam","allowInsecure":true,"sshAuthMethod":"password","authMode":"password","ragServerURL":"http://127.0.0.1:3100"}]
JSON
  seeded=1
fi
cleanup() {
  pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null
  if [ "$seeded" = 1 ] && [ -f "$SUPPORT/servers.json.swiftplay-bak" ]; then
    mv -f "$SUPPORT/servers.json.swiftplay-bak" "$SUPPORT/servers.json"
  fi
}
trap cleanup EXIT

pkill -f "RackMind.app/Contents/MacOS/RackMind" 2>/dev/null; sleep 1
"$SWIFTPLAY" launch --path "$APP"; sleep 5
PID=$(pgrep -f 'RackMind.app/Contents/MacOS/RackMind' | head -1)

echo "swiftplay headless smoke sweep"
echo "------------------------------"
alive "launch (hidden)"

# Every sidebar page (identifiers from RAC-327).
for page in chat dashboard audit terminal knowledge alerts settings; do
  "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-$page" >/dev/null 2>&1
  sleep 0.7
  alive "nav-$page"
done

# Every Settings tab (we're on the Settings page after the loop above).
for tab in credentials embedding agent servers appearance updates audit-log; do
  "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "settings-tab-$tab" >/dev/null 2>&1
  sleep 0.7
  alive "settings-tab-$tab"
done

# Back to chat, exercise the skill picker open/dismiss once more.
"$SWIFTPLAY" click --ax -b "$BUNDLE" -t "nav-chat" >/dev/null 2>&1; sleep 0.5
"$SWIFTPLAY" type "/" -b "$BUNDLE"; sleep 0.5
alive "open skill picker"
"$SWIFTPLAY" click --ax -b "$BUNDLE" -t "skill-row-/monitor" >/dev/null 2>&1; sleep 0.5
alive "complete skill via AX-press"

echo "------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
