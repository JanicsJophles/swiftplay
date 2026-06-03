#!/usr/bin/env bash
#
# Records demo.sh with asciinema and renders docs/demo.gif with agg.
# Run from anywhere; resolves the repo root itself.
#
# Prereqs: asciinema + agg installed, swiftplay built, RackMind installed, and
# Accessibility granted to this terminal.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

SWIFTPLAY="$REPO/.build/debug/swiftplay"
BUNDLE=ai.rackmind.macos
CAST="$(mktemp -t swiftplay-demo).cast"
OUT="docs/demo.gif"

[ -x "$SWIFTPLAY" ] || { echo "build swiftplay first: env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift build --product swiftplay"; exit 1; }

# Make sure the target is up (hidden) and the toggle starts at "1", so the demo
# shows a real 1 → 0 flip.
"$SWIFTPLAY" launch -b "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
val="$("$SWIFTPLAY" find -b "$BUNDLE" -t server-mode-toggle --role AXCheckBox 2>/dev/null | grep -oE '"[01]"' | head -1 || true)"
if [ "$val" != '"1"' ]; then
  "$SWIFTPLAY" click -b "$BUNDLE" -t server-mode-toggle --role AXCheckBox --ax >/dev/null 2>&1 || true
  sleep 1
fi

echo "recording…"
asciinema rec --overwrite --headless --window-size 92x22 \
  -c "env TERM=xterm-256color SWIFTPLAY='$SWIFTPLAY' bash examples/rackmind-macos/demo.sh" \
  "$CAST"

echo "rendering ${OUT} ..."
mkdir -p docs
agg --cols 92 --rows 22 --font-size 20 --theme dracula --idle-time-limit 1.2 \
  "${CAST}" "${OUT}"

echo "done -> ${OUT}"
ls -lh "${OUT}"
