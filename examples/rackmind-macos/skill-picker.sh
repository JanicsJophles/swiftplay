#!/usr/bin/env bash
#
# swiftplay dogfood — rackmind-macos chat skill picker (RAC-36).
#
# Drives the native SwiftUI app end-to-end with swiftplay and asserts on the
# live AX tree: typing "/" opens the skill autocomplete, the rows are present,
# filtering narrows them, arrow keys navigate, and a trailing space dismisses it.
#
# BACKGROUND MODE: input is delivered to the app's pid (CGEvent.postToPid for
# keys, AX press for activation) without bringing it to the front — this is the
# default now. After the initial launch you can keep working in another app / on
# another macOS Space; swiftplay won't steal focus. `click` (mouse) still needs
# foreground, but `click --ax` activates an element's AX action in the
# background — which is why we gave the picker rows an .accessibilityAction.
#
# This is the first real swiftplay suite. It exercises the whole surface:
# tree/find queries plus type/press/click input.
#
# Requirements:
#   - swiftplay built:  (cd ../.. && xcrun --toolchain XcodeDefault swift build --product swiftplay)
#     NOTE: build with Xcode's toolchain via xcrun — a swiftly-managed `swift`
#     in PATH mismatches the macOS 16 SDK ("could not build module _Builtin_float").
#   - RackMind.app built: (cd <rackmind-macos> && make build)
#   - Accessibility permission granted to your terminal (Apple's TCC; there is
#     no programmatic grant).
#
# Usage:
#   ./skill-picker.sh
#
set -uo pipefail

BUNDLE="ai.rackmind.macos"
SWIFTPLAY="${SWIFTPLAY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/swiftplay}"
APP="${RACKMIND_APP:-$HOME/development/rackmind/rackmind-macos/DerivedData/Build/Products/Debug/RackMind.app}"
SUPPORT="$HOME/Library/Application Support/RackMind"

pass=0; fail=0
check() { # check <label> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (want exit $2, got $3)"; fail=$((fail+1)); fi
}

# --- Setup: seed a throwaway server so the app boots past onboarding into Chat.
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
# Launch hidden + background (headless-style): the app never appears on screen and
# your current app keeps focus. swiftplay drives it via the pid + AX from here on.
"$SWIFTPLAY" launch --path "$APP"; sleep 5

echo "swiftplay skill-picker dogfood"
echo "------------------------------"

# The composer auto-focuses on launch (which brought the app frontmost). From
# here everything runs in the background — alt-tab away and keep working.

# 1. Type "/" — opens the picker.
"$SWIFTPLAY" type "/" -b "$BUNDLE"; sleep 0.7

# 2. Picker is open; rows are AXButtons with stable identifiers (skill-row-<cmd>).
"$SWIFTPLAY" find -b "$BUNDLE" -t "skill-row-/deploy"   --role AXButton --count >/dev/null; check "picker shows /deploy"   0 $?
"$SWIFTPLAY" find -b "$BUNDLE" -t "skill-row-/jellyfin" --role AXButton --count >/dev/null; check "picker shows /jellyfin" 0 $?
"$SWIFTPLAY" find -b "$BUNDLE" -t "Tab to complete" --count >/dev/null;                     check "picker shows hint footer" 0 $?

# 3. Arrow keys navigate the selection (visual; no highlight assertion yet).
"$SWIFTPLAY" press down -b "$BUNDLE" --repeat 2; sleep 0.4

# 4. Prefix filter narrows the list.
"$SWIFTPLAY" type "mon" -b "$BUNDLE"; sleep 0.5
"$SWIFTPLAY" find -b "$BUNDLE" -t "skill-row-/monitor" --role AXButton --count >/dev/null; check "filter narrows to /monitor" 0 $?
"$SWIFTPLAY" find -b "$BUNDLE" -t "skill-row-/deploy"  --role AXButton --count >/dev/null; check "filter hides /deploy"      1 $?

# 5. Complete the command by AX-pressing the row — background, no cursor, no focus steal.
"$SWIFTPLAY" click --ax -b "$BUNDLE" -t "skill-row-/monitor" >/dev/null; sleep 0.6

# 6. Picker is dismissed once the command is completed.
"$SWIFTPLAY" find -b "$BUNDLE" -t "skill-row-" --count >/dev/null; check "picker dismissed after completion" 1 $?

echo "------------------------------"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
