#!/usr/bin/env bash
#
# Live demo: swiftplay driving a visible RackMind window — navigate by role+name,
# then pop and filter the chat skill picker. Safe: it never sends a message or
# runs a skill (escape dismisses the picker), so no real infra action is taken.
#
# Pair with a screen recording of the app window; recording this same run with
# asciinema + agg (the docs/demo.gif pipeline) produces a synced terminal GIF.
#
# Usage:  SWIFTPLAY=/path/to/.build/release/swiftplay ./demo-live.sh
set -u

SWIFTPLAY="${SWIFTPLAY:?set SWIFTPLAY to the swiftplay binary path}"
swiftplay() { "$SWIFTPLAY" "$@"; }

P='\033[1;32m'; C='\033[0m'; D='\033[2m'; R='\033[0m'
say() { printf "${D}%s${R}\n" "$1"; sleep 0.9; }
run() {
  local cmd="$1"
  printf "\n${P}\$ ${C}"
  for ((i = 0; i < ${#cmd}; i++)); do printf '%s' "${cmd:i:1}"; sleep 0.02; done
  printf "${R}\n"; sleep 0.5; eval "$cmd"; sleep 1.5
}

printf '\033[2J\033[3J\033[H'; sleep 0.7
say "# swiftplay — driving a native macOS app live, from the terminal"
say "# navigate by role + name (no Xcode, no XCUITest):"
run 'swiftplay click -t Dashboard --role AXButton -b ai.rackmind.macos --ax'
run 'swiftplay click -t Terminal  --role AXButton -b ai.rackmind.macos --ax'
run 'swiftplay click -t Chat      --role AXButton -b ai.rackmind.macos --ax'
say "# pop the skill picker, pick /monitor, and run it — live:"
run 'swiftplay type "/" -b ai.rackmind.macos --foreground'
run 'swiftplay click -t skill-row-/monitor --role AXButton -b ai.rackmind.macos --ax'
run 'swiftplay click -t chat-send --role AXButton -b ai.rackmind.macos --ax'
sleep 4.0
