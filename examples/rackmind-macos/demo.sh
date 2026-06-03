#!/usr/bin/env bash
#
# The README demo: locate an element by role/text, drive it headlessly, and
# verify the app's state actually changed — the whole Playwright loop against a
# native SwiftUI app, from the terminal.
#
# Recorded with asciinema and rendered to a GIF with agg (see record-demo.sh).
# Runs the REAL swiftplay binary against a running RackMind; nothing is faked.
#
# Usage:
#   SWIFTPLAY=/path/to/.build/debug/swiftplay ./demo.sh
set -u

SWIFTPLAY="${SWIFTPLAY:?set SWIFTPLAY to the swiftplay binary path}"
BUNDLE=ai.rackmind.macos

# Show the command as `swiftplay …`, run the real binary.
swiftplay() { "$SWIFTPLAY" "$@"; }

P='\033[1;32m'   # prompt
C='\033[0m'      # command
D='\033[2m'      # dim narration
R='\033[0m'

say()  { printf "${D}%s${R}\n" "$1"; sleep 0.8; }

run() {
  local cmd="$1"
  printf "\n${P}\$ ${C}"
  for ((i = 0; i < ${#cmd}; i++)); do printf '%s' "${cmd:i:1}"; sleep 0.018; done
  printf "${R}\n"
  sleep 0.4
  eval "$cmd"
  sleep 1.4
}

printf '\033[2J\033[3J\033[H'   # clear screen (no TERM dependency)
sleep 0.6
say "# swiftplay — Playwright-style automation for native macOS apps"
say "# attach to any running app. no Xcode, no XCUITest, no test bundle."
sleep 0.5

run 'swiftplay find -b ai.rackmind.macos -t "Connect Proxmox"'
run 'swiftplay find -b ai.rackmind.macos -t server-mode-toggle --role AXCheckBox'

say "# drive it headlessly — the app stays hidden, never steals focus:"
run 'swiftplay click -b ai.rackmind.macos -t server-mode-toggle --role AXCheckBox --ax'

say "# …and the app's state actually changed (value 1 → 0):"
run 'swiftplay find -b ai.rackmind.macos -t server-mode-toggle --role AXCheckBox'
sleep 1.6
