# Driving iOS apps in the Simulator

swiftplay can drive an **iOS app running in the iOS Simulator** using the same
Accessibility substrate it uses for native Mac apps — no XCUITest, no test
bundle, no device-side agent.

The reason is simple, and it is the whole trick:

> **Simulator.app is a macOS app, and it republishes the simulated app's
> accessibility tree as part of its own.**

So the iOS app's buttons, text fields, and *accessibility identifiers* show up in
a plain `AXUIElement` walk. Nothing about swiftplay's architecture changes.

**Physical iOS devices are a different story and remain out of scope**: there is
no macOS Accessibility bridge to an app running on real hardware, so there is
nothing to attach to. Use XCUITest for those.

---

## Status: what works, what doesn't

Verified on 2026-08-11 against a booted **iPhone 17 Pro (iOS 26.1)** running a
Flutter app.

| Capability | Command | Status |
|---|---|---|
| Read the AX tree | `swiftplay tree --simulator` | ✅ works |
| Find / assert on elements | `swiftplay find --simulator` | ✅ works |
| Device discovery + selection | `--device <name-or-udid>` | ✅ works |
| Screenshot the device window | `swiftplay screenshot -b com.apple.iphonesimulator` | ✅ works (captures window chrome too) |
| Click | `swiftplay click` | ⚠️ works, but **not scoped** — see [Limitations](#limitations) |
| **Type text** | `swiftplay type` | ❌ **broken in the Simulator** — see [Typing is broken](#typing-is-broken-in-the-simulator) |

---

## Quickstart

Boot a device and open the Simulator UI (a device booted with `simctl boot`
alone renders nothing and has no AX tree):

```sh
xcrun simctl boot "iPhone 17 Pro"
open -a Simulator
```

Run your app in it, then:

```sh
# The whole iOS app's tree — no bundle id needed, no Simulator chrome
swiftplay tree --simulator

# Assert an element exists (exits non-zero if not)
swiftplay find --simulator -t "Continue"

# Target one of several booted devices
swiftplay tree --device "iPhone 17 Pro"
swiftplay tree --device EC8051C6-BF02-454D-A3B1-2854ACAF1AD4
```

`--device` implies `--simulator`, so you never need both.

---

## How it works

`swiftplay tree -b com.apple.iphonesimulator` (the unscoped way) shows the real
structure:

```
AXApplication "Simulator"
├── AXWindow (AXStandardWindow) title="iPhone 17 Pro – iOS 26.1"
│   ├── AXGroup (iOSContentGroup)     ← the simulated app's UI lives here
│   ├── AXToolbar                     ┐
│   ├── AXButton (AXCloseButton)      │ macOS window chrome —
│   ├── AXButton (AXFullScreenButton) │ noise if you're testing
│   ├── AXButton (AXMinimizeButton)   │ the iOS app
│   └── AXStaticText "iPhone 17 Pro"  ┘
└── AXMenuBar                         ← Simulator's own menus (more noise)
```

`--simulator` does two things:

1. **Finds the right window.** Devices come from
   `xcrun simctl list devices booted -j`; the matching window is the one titled
   `"<device name> – <runtime>"`. (That separator is a U+2013 EN DASH, not a
   hyphen — a detail worth knowing if you ever match these titles yourself.)
2. **Roots every query at `iOSContentGroup`**, the group holding the simulated
   app's UI. Everything above it is macOS chrome and disappears from results.

Implementation: [`Sources/swiftplay/AX/Simulator.swift`](../Sources/swiftplay/AX/Simulator.swift).

### Scoping is a correctness feature, not a convenience

`find` is swiftplay's assertion oracle — it exits non-zero when nothing matches,
so it can be dropped straight into a test script. Against the Simulator, scoping
decides whether that assertion means anything:

```sh
$ swiftplay find -b com.apple.iphonesimulator -t "Device" --count
12          # ← every match is a Simulator *menu item*

$ swiftplay find --simulator -t "Device" --count
0           # ← correct: the iOS app has no such element (exits non-zero)
```

Unscoped, a suite asserting on its own UI can go green off Simulator's menu bar.
**Always use `--simulator` for assertions against a simulated app.**

---

## Worked example: a Flutter app

This is the pattern that makes Simulator automation genuinely useful rather than
a curiosity: **accessibility identifiers survive the bridge.**

A Flutter widget wrapped in `Semantics(identifier:)`:

```dart
Semantics(
  identifier: 'flow.general.first_name',
  child: TextField(
    decoration: InputDecoration(hintText: 'Enter First Name'),
  ),
)
```

…surfaces in swiftplay as a first-class, uniquely addressable element (real
output, lightly trimmed):

```sh
$ swiftplay tree --simulator
# iPhone 17 Pro — iOS 26.1 [EC8051C6-…] via Simulator (pid 55836)
AXGroup (iOSContentGroup)
├── AXHeading desc="New Customer"
├── AXStaticText desc="General"
├── AXStaticText desc="Services"
├── AXStaticText #flow.section.contact_info desc="Contact Info"
├── AXTextField #flow.general.first_name value="aaaaa"
├── AXTextField #flow.general.email      desc="Enter Email"
├── AXTextField #flow.general.phone      desc="Enter Phone"
├── AXTextField #flow.general.address    desc="Enter Address, City, State, Zipcode"
├── AXStaticText #flow.general.current_location desc="Current Location"
├── AXButton desc="Back" [disabled]
├── AXButton desc="Save"
└── AXButton desc="Continue" [disabled]
```

Two things to read off that output:

- **An empty field reports its hint as `desc=`; a filled one reports `value=`.**
  So `desc` is what you assert against for placeholder text, `value` for contents.
- That `value="aaaaa"` in `first_name` is the
  [typing bug](#typing-is-broken-in-the-simulator) caught in the act — the field
  was sent `"Krish"`.

The `#…` values are the Flutter identifiers, unchanged. So you can assert on
stable IDs instead of on user-visible copy that translators will change:

```sh
$ swiftplay find --simulator -t flow.general.phone
AXTextField #flow.general.phone @(957,691 318x20)
```

A useful convention for those identifiers is
`<area>.<screen>.<element>[.<qualifier>]`, lowercase and dot-separated — it keeps
them greppable and collision-free as an app grows.

### The same idea in other toolkits

| Toolkit | How to set it |
|---|---|
| Flutter | `Semantics(identifier: 'flow.general.first_name', child: …)` |
| SwiftUI | `.accessibilityIdentifier("flow.general.first_name")` |
| UIKit | `view.accessibilityIdentifier = "flow.general.first_name"` |

An app whose leaf controls carry identifiers is trivially drivable; one whose
controls don't forces you onto brittle text matching. This is the single highest-
leverage change an app team can make for automation, and it costs one line per
control.

> **Note on Flutter's semantics tree:** Flutter builds it on demand, when an
> accessibility client asks for it. Reading the tree through the Simulator bridge
> is such a request, which is why the identifiers above appear without any extra
> setup. If your identifiers *don't* show up, check that the widget is actually
> wrapped in `Semantics` and that the surrounding widget isn't blocking semantics
> (`ExcludeSemantics`, or a `MergeSemantics` that folds children together).

---

## Typing is broken in the Simulator

**Do not trust `swiftplay type` against a simulated app yet.**

Typing `"Krish"` produces `"Aaaaa"` — the correct character *count*, every
character wrong. It is not a timing problem; it reproduces with a 250 ms
inter-key delay.

The cause is in `Sources/swiftplay/Input/Keyboard.swift`:

```swift
CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
```

Virtual keycode `0` is `kVK_ANSI_A`. swiftplay then overrides the character with
`keyboardSetUnicodeString`. **Native macOS apps honour that override; the
Simulator does not** — it maps the virtual keycode, sees `0`, and types "a" every
time.

A fix (setting a real keycode per character) is tracked separately. Until it
lands, this doc will keep saying typing is broken, because it is.

---

## Limitations

- **Only `tree` and `find` take `--simulator`.** `click`, `type`, `press`, and
  `screenshot` still target the whole Simulator process. In practice:
  - `screenshot -b com.apple.iphonesimulator` captures the device window
    *including* macOS chrome (title bar, toolbar).
  - `click -t "…"` searches Simulator's entire tree, so a label that also appears
    in Simulator's menus can match the wrong element. Prefer a text or identifier
    that is unique to your app, and confirm the target first with
    `find --simulator`.
- **`click` activates the target app by default**, which pulls focus to the
  Simulator window. `click --ax` performs the element's AX press action instead
  and steals nothing.
- **A headlessly-booted device has no AX tree.** `simctl boot` without
  `open -a Simulator` renders no window; swiftplay reports this rather than
  silently finding nothing.
- **Typing** — see above.
- Ambiguous `--device` selectors are an error, never a guess. Driving the wrong
  device would silently test the wrong thing.

---

## Troubleshooting

| Message | Meaning |
|---|---|
| `No booted Simulator devices.` | Nothing is booted. `xcrun simctl boot "iPhone 17 Pro"` |
| `Simulator.app is not running…` | Device booted headlessly. `open -a Simulator` |
| `…has no window for <device>` | Window closed, or device booted headlessly. The message lists the windows that *are* open. |
| `…no 'iOSContentGroup' element inside it` | The window is showing no app — the simulated app may still be launching. |
| `More than one booted device matches…` | Add `--device <name-or-udid>`; the message lists the candidates. |

Accessibility permission applies exactly as it does for Mac apps: the **terminal
running swiftplay** must be granted Accessibility in System Settings → Privacy &
Security. See the [README](../README.md#permissions).
