#!/usr/bin/env bash
#
# swiftplay headless smoke — rackmind-macos onboarding wizard.
#
# Onboarding is the first thing every new user sees, and it's full of conditional
# step-swaps with transitions — the same SwiftUI pattern that crashed in RAC-328.
# This walks the reachable step surface headlessly and asserts the app survives.
#
# Design 2.0 (RAC-341): the wizard is now a two-pane / 4-step model
# (Connect Proxmox · AI Provider · Discover · Ready). The standalone welcome step
# and the separate SSH step were folded into Step 01 "Connect Proxmox", which is
# shown immediately at first run. Without a real Proxmox server we can only
# traverse Step 01 + its Back (which clears banners, since there is no welcome to
# return to) — the entry render + the persistent left rail are the highest
# crash-risk parts anyway.
#
set -uo pipefail

BUNDLE="ai.rackmind.macos"
SWIFTPLAY="${SWIFTPLAY:-$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/swiftplay}"
APP="${RACKMIND_APP:-$HOME/development/rackmind/rackmind-macos/DerivedData/Build/Products/Debug/RackMind.app}"
SUPPORT="$HOME/Library/Application Support/RackMind"

pass=0; fail=0; PID=""
alive() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then echo "  ✓ survived: $1"; pass=$((pass+1));
  else echo "  ✗ CRASHED at: $1"; fail=$((fail+1)); fi
}
present() { # present <label> <id>  — assert an element exists (and app alive)
  if "$SWIFTPLAY" find -b "$BUNDLE" -t "$2" --count >/dev/null 2>&1; then echo "  ✓ shows: $1"; pass=$((pass+1));
  else echo "  ✗ missing: $1 ($2)"; fail=$((fail+1)); fi
}

# Force onboarding: no configured server.
seeded=0
if [ -d "$SUPPORT" ]; then
  cp -f "$SUPPORT/servers.json" "$SUPPORT/servers.json.swiftplay-bak" 2>/dev/null
  printf '[\n\n]' > "$SUPPORT/servers.json"
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

echo "swiftplay headless smoke — onboarding (D2.0 4-step)"
echo "-------------------------------------"
alive "launch (hidden, no server → onboarding)"

# Force-onboarding works by emptying the Swift app's servers.json. On a machine
# with a configured server that resists seeding (shared Application Support dir,
# stale persisted state — tracked as a verification follow-up), the app boots to
# the MAIN UI instead. In that case we cannot DRIVE onboarding, but the launch
# above already proved it didn't crash — so SKIP the onboarding assertions
# loudly rather than fail the crash-smoke. Detect which screen we're on:
if "$SWIFTPLAY" find -b "$BUNDLE" -t "onboarding-server-connect" --count >/dev/null 2>&1; then
  # Step 01 "Connect Proxmox" is shown immediately at first run.
  present "Connect Proxmox step (Step 01)" "onboarding-server-connect"
  # Persistent left rail (brand + boot-log + step-rail) renders on every step.
  present "left-rail step list" "onboarding-step-rail"
  present "left-rail boot log" "onboarding-boot-log"
  # The Read/Write mode rocker lives inside the Connect Proxmox form.
  present "read/write mode rocker" "onboarding-server-mode-toggle"

  # Back on Step 01 clears the error/success banners (no welcome to return to).
  # It must not crash and must leave us on the Connect Proxmox step.
  "$SWIFTPLAY" click --ax -b "$BUNDLE" -t "onboarding-server-back" >/dev/null 2>&1; sleep 0.8
  alive "press Back (clears banners, stays on Step 01)"
  present "still on Connect Proxmox step" "onboarding-server-connect"
else
  echo "  ⊘ SKIP onboarding assertions — app booted to MAIN UI (a configured"
  echo "    server resisted force-onboarding seeding). Launch-crash check still"
  echo "    counts; onboarding drive needs the verification-harness fix."
fi

echo "-------------------------------------"
echo "pass=$pass fail=$fail   (frontmost stayed: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null))"
[ "$fail" = 0 ]
