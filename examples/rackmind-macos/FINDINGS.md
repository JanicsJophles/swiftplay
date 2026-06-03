# swiftplay × rackmind-macos — spike findings

First real dogfood run (2026-06-01), driving the chat **skill picker**
end-to-end — the "find the first ten gotchas" pass against a real SwiftUI app.
See [`skill-picker.sh`](./skill-picker.sh) for the runnable suite.

## What worked

- `tree` dumps the full SwiftUI AX tree; the skill picker shows up cleanly as a
  column of `AXStaticText` rows with geometry.
- `find` (role + text substring, exits non-zero on no match) is a usable
  assertion oracle — the suite asserts picker presence and dismissal with it.
- `type` (CGEvent + `keyboardSetUnicodeString`, posted via `postToPid`) drives
  text input. The composer **auto-focuses on launch**, so `type "/"` lands
  without an explicit click first.
- `press down` (arrow keys) navigates the picker selection.
- `click` (resolve element via `find`, click its center) activates the row's
  SwiftUI `onTapGesture` and completes the command — the picker then dismisses.

## Background mode — no headless display needed (`--no-activate`)

macOS has no Linux-style headless display for GUI/AX automation, but you don't
need one: **`CGEvent.postToPid` delivers keyboard events straight to the target
process's event queue, and AX queries read the tree regardless of focus or which
Space the app is on.** So `type`/`press`/`find`/`tree` all work against a
**backgrounded** app.

This is the **default** now — `type`/`press` deliver to the pid without
activating; pass `--foreground` to opt into bringing the app forward. Proven:
with **Finder frontmost**, `type "/" -b ai.rackmind.macos` opened the picker in
RackMind and focus never left Finder. The whole `skill-picker.sh` suite — open,
filter, navigate, **complete**, dismiss — passes 6/6 without stealing focus. You
can keep working in another app, or park RackMind on another macOS Space.

Caveats:
- The target's relevant view must already hold key focus. RackMind's composer
  auto-focuses at launch (which is frontmost), so subsequent background input
  lands. An app launched directly into the background may need one foreground
  moment to establish focus.
- **Mouse `click` still needs foreground** (global CGEvent mouse hit-tests the
  frontmost window). But **`click --ax`** activates an element's AX press action
  instead — no cursor, no focus steal — so it works in the background. That only
  works when the element exposes an action; see Gotcha 1.

## Gotcha 1 — no a11y identifiers (FIXED for the chat surface)

Originally the picker rows were bare `AXStaticText value="/deploy"` — no
`accessibilityIdentifier`, no button role, no AX action — so they could only be
located by static-text substring and couldn't be activated via AX.

**Fixed in rackmind-macos** (the dogfood drove this change): the composer, send/
stop/attach buttons, and model picker now carry identifiers (`chat-composer`,
`chat-send`, …), and each skill row is an `AXButton #skill-row-/<cmd>` with a
combined label *and* an `.accessibilityAction`. swiftplay now resolves rows by
stable id (`find -t skill-row-/monitor --role AXButton`) and activates them in
the background (`click --ax`). This is the virtuous loop the spike was for.

Still open:
- **rackmind-macos:** sweep the rest of the app (sidebar nav, dashboard, settings
  tabs) for identifiers. Tracked in Linear.
- **swiftplay:** codegen's selector ranker should prefer `axIdentifier` >
  role+name > text, and warn when only text is available.

## Gotcha 2 — CGEvent Tab (command/focus keys) doesn't reach `doCommandBy`

`press tab` via CGEvent does **not** trigger the focused `NSTextView`'s
`doCommandBy: insertTab:` — so it never completes the picker. Tried, all failed
to deliver Tab as a command: `.cgSessionEventTap`, `.cghidEventTap`, and
`postToPid`. **Arrow keys route fine through every one of those** — so it's
specific to keys the AppKit key-view-loop / focus manager claims (Tab, and
likely Esc/arrows-in-some-contexts). System Events' `key code 48` *does* deliver
it as a command, so there's a delivery path we're not matching yet.

- **Workaround (today):** use `click --ax` — performs the element's AX press
  action (background, no cursor). It's a better test of the real UI anyway, and
  it sidesteps Tab entirely.
- **Action (swiftplay):** before `press` is "done" for v0.1, investigate the
  command-key path — likely needs `AXUIElementPostKeyboardEvent`-style delivery
  or marking the event so AppKit treats it as text-system input, not focus
  traversal. Track this; it'll bite any keyboard-shortcut test (`⌘1..5`, `⌘N`).

## Gotcha 3 — build with Xcode's toolchain, not the PATH `swift`

The `swift` on PATH here is swiftly-managed (`~/.swiftly/bin/swift`) and
mismatches Xcode's macOS 16 SDK — `swift build` dies with
`could not build Objective-C module '_Builtin_float'` (a frontend crash). Build via:

```
env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift build --product swiftplay
```

Also: a bare `swift build` tries to compile swift-argument-parser's DocC plugin,
which crashes the same frontend — `--product swiftplay` skips it.

## Test-harness gotcha — onboarding gate

`ContentView` shows `OnboardingView` until `ServerStore.hasConfiguredServer`,
which reads `~/Library/Application Support/RackMind/servers.json`. The suite
seeds a throwaway server there (and restores the original on exit) to reach
Chat. When swiftplay grows a real runner, this is the kind of thing a
`reset()` / state-seeding fixture should own (roadmap v0.4).
