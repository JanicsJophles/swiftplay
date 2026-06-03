# swiftplay

[![CI](https://github.com/JanicsJophles/swiftplay/actions/workflows/ci.yml/badge.svg)](https://github.com/JanicsJophles/swiftplay/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)

Playwright-style UI automation for **native macOS apps**. swiftplay attaches to any
already-running app through the macOS Accessibility (AX) API — query its element
tree by role/label/text, drive the keyboard, and click controls — with no Xcode
project, no XCUITest, and no test bundle. It reads the app's live AX tree and
synthesizes input events, so it works against any pid / bundle id from the outside.

## Build

```sh
env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift build --product swiftplay
```

Use this exact command — **not** a bare `swift build`. The `swift` on `PATH` here
is a swiftly-managed toolchain whose Swift frontend mismatches the installed macOS
SDK; a plain `swift build` crashes the compiler frontend (and the
swift-argument-parser DocC plugin crashes it the same way, which is why we scope to
`--product swiftplay`). The `xcrun --toolchain XcodeDefault` invocation pins the
build to Xcode's default toolchain, which matches the SDK.

The binary lands at:

```
.build/debug/swiftplay
```

## Permissions

swiftplay drives the system through Accessibility, so the **terminal app that runs
it** must be granted Accessibility permission:

- System Settings → Privacy & Security → **Accessibility** → enable your terminal
  (Terminal.app, iTerm, etc.).

Screenshot / screen-capture features additionally require **Screen Recording**
permission for the same terminal.

There is **no programmatic way to grant these** — macOS (TCC) requires a manual
toggle. If swiftplay isn't trusted, commands print guidance and exit non-zero.

## Commands

All examples use the dogfood target bundle id `ai.rackmind.macos`.

### `launch` — start the app hidden (headless)

```sh
.build/debug/swiftplay launch -b ai.rackmind.macos
.build/debug/swiftplay launch --path /path/to/App.app
.build/debug/swiftplay launch -b ai.rackmind.macos --show   # visible/foreground
```

Launches the target **hidden + in the background** (`open -g -j`): the window never
appears on screen and your current app keeps focus. AX queries and
`CGEvent.postToPid` still reach a hidden app, so swiftplay drives it fully headless
from there. Use `--show` if you actually want to see it (or need mouse `click` /
menu key-equivalents — see Background mode).

### `tree` — dump the AX element tree

```sh
.build/debug/swiftplay tree -b ai.rackmind.macos
.build/debug/swiftplay tree -b ai.rackmind.macos --show-geometry
```

### `inspect` — print the element under the mouse cursor

```sh
.build/debug/swiftplay inspect
```

### `find` — locate elements (assertion oracle)

```sh
.build/debug/swiftplay find -t "Dashboard"
.build/debug/swiftplay find -t skill-row-/monitor --role AXButton
.build/debug/swiftplay find -t "Dashboard" --count
```

`find` exits **non-zero when nothing matches**, so it doubles as a test
assertion — drop it in a script and a missing element fails the suite.

### `type` — type literal text into the focused element

```sh
.build/debug/swiftplay type "hello world"
.build/debug/swiftplay type "/" -b ai.rackmind.macos
.build/debug/swiftplay type "hello" -b ai.rackmind.macos --foreground
```

### `press` — press a named key or chord

```sh
.build/debug/swiftplay press down
.build/debug/swiftplay press tab
.build/debug/swiftplay press down --repeat 3
.build/debug/swiftplay press cmd+k -b ai.rackmind.macos --foreground
```

Accepts a named key (`down`/`up`/`left`/`right`/`tab`/`return`/`escape`/`space`/
`delete`), a single letter/digit, or a chord like `cmd+k` / `cmd+shift+p`.
`--repeat N` presses N times.

### `click` — click an element by text/role

```sh
.build/debug/swiftplay click -t "Dashboard"
.build/debug/swiftplay click -t skill-row-/monitor --role AXButton --ax
.build/debug/swiftplay click -t "Save" -b ai.rackmind.macos
```

`--ax` performs the element's AX press action instead of a mouse click (see
Background mode).

### `test` — run test scripts and report

```sh
.build/debug/swiftplay test --dir examples/rackmind-macos
.build/debug/swiftplay test examples/rackmind-macos/smoke-nav.sh
.build/debug/swiftplay test --dir examples/rackmind-macos -v
```

A test is an executable script that exits 0 on success. `test` runs them
**serially** (they drive a single GUI app instance + shared state, so they can't
overlap), prints a `✓`/`✗` summary with durations, shows failing output (all
output with `-v`), and exits non-zero if any fail. This is the v0.4 MVP runner —
scripts today, native TS/Swift test files later.

### `mcp` — run as an MCP server (drive apps from an agent)

```sh
.build/debug/swiftplay mcp
```

Exposes swiftplay over the [Model Context Protocol](https://modelcontextprotocol.io)
as a stdio server, so an agent (Claude, etc.) can drive native macOS apps. It's a
dependency-free JSON-RPC 2.0 server speaking newline-delimited messages on
stdin/stdout (logs go to stderr). Tools:

| Tool | What it does |
|------|--------------|
| `swiftplay_launch` | Launch an app (hidden/background by default, or `show=true`) |
| `swiftplay_tree` | Dump the AX tree — the agent's equivalent of the DOM |
| `swiftplay_find` | Find elements by role/text; reports count + matches |
| `swiftplay_click` | AX-press (default) or mouse-click the first match |
| `swiftplay_type` | Type literal text into the focused element |
| `swiftplay_press` | Press a key or chord (`down`, `tab`, `cmd+k`, …) |

Register it with Claude Code:

```sh
claude mcp add swiftplay -- /absolute/path/to/.build/debug/swiftplay mcp
```

Or in a `claude_desktop_config.json` / `mcp.json`:

```jsonc
{
  "mcpServers": {
    "swiftplay": {
      "command": "/absolute/path/to/.build/debug/swiftplay",
      "args": ["mcp"]
    }
  }
}
```

The same Accessibility permission applies: the **process that hosts the MCP
server** (your terminal, or the agent app launching it) must be granted
Accessibility. AX-dependent tools return an error result with guidance if it
isn't, rather than crashing the server.

## Background / headless mode

By default `type` and `press` deliver events via `CGEvent.postToPid`, and
`click --ax` performs the element's AX press action. None of these steal focus or
switch Spaces — swiftplay reads the AX tree and posts straight to the target
process, so you can keep working in another app (or park the target on another
macOS Space) while a suite runs against it.

For a **fully headless run** — the app never appears on screen at all — start it
with `swiftplay launch` (hidden + background) and drive it with the default
(non-`--foreground`) commands. macOS has no true headless display for GUI apps, but
a hidden app's windows remain in the AX tree and accept `postToPid` input, so this
is as close as it gets: `launch` → `type`/`press`/`find`/`click --ax`, all
invisible. The dogfood suite ([`skill-picker.sh`](./examples/rackmind-macos/skill-picker.sh))
runs this way and never brings the app forward.

Pass `--foreground` to bring the target app forward first. You need it for:

- mouse **`click`** (without `--ax`) — the global CGEvent mouse hit-test resolves
  against the frontmost window;
- **menu key-equivalents** like `⌘K` — they only route through NSApplication when
  the app is frontmost and the event hits the global HID tap.

## Known limitations

- Plain **`Tab` as a command key** is not delivered as a command via CGEvent — it
  reaches the focused field but doesn't trigger AppKit's `doCommandBy:` (e.g.
  command-completion). Use **`click --ax`** to perform the element's action
  instead. Arrow keys do route correctly.
- The full, current gotcha list lives in
  [`examples/rackmind-macos/FINDINGS.md`](./examples/rackmind-macos/FINDINGS.md).

## Dogfood + more

- Runnable end-to-end suite:
  [`examples/rackmind-macos/skill-picker.sh`](./examples/rackmind-macos/skill-picker.sh)
- Findings, gotchas, and what works today:
  [`examples/rackmind-macos/FINDINGS.md`](./examples/rackmind-macos/FINDINGS.md)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) — it covers the build command, the
Accessibility permission, and why CI can only build-check (TCC can't be granted on
a hosted runner). Bug reports want an AX-tree slice; new gotchas go in
[`FINDINGS.md`](./examples/rackmind-macos/FINDINGS.md).

## License

[Apache License 2.0](./LICENSE). Use it, fork it, build on it.
</content>
</invoke>
