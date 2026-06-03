# Contributing to swiftplay

Thanks for wanting to help build Playwright for native macOS apps. This doc gets
you from a clean clone to a green PR.

## TL;DR

1. macOS 14+ with Xcode installed.
2. Build with the **exact** command below (not bare `swift build`).
3. Grant your terminal **Accessibility** permission.
4. Run the dogfood suite locally — CI can't (see below).
5. Open a PR; fill in the template.

## Building

```sh
env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift build --product swiftplay
```

Use this exact command. A bare `swift build` may crash the compiler frontend if
your `PATH` `swift` is a [swiftly](https://github.com/swiftlang/swiftly)-managed
toolchain whose frontend mismatches the installed macOS SDK. `xcrun --toolchain
XcodeDefault` pins the build to Xcode's toolchain, which matches the SDK. (On a
clean CI runner there's no mismatch, so CI uses a plain `swift build` — see
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).)

The binary lands at `.build/debug/swiftplay`.

## Permissions (required to run anything)

swiftplay drives the system through Accessibility, so **the terminal that runs it**
must be granted permission:

- System Settings → Privacy & Security → **Accessibility** → enable your terminal.
- Screenshot/capture features also need **Screen Recording** permission.

There is no programmatic way to grant these — macOS (TCC) requires a manual toggle.

## Testing

There are two layers, and an important constraint:

- **CI build-checks only.** swiftplay needs the TCC Accessibility grant, which
  **cannot be granted on a hosted GitHub runner**. So CI compiles the project and
  smoke-runs `--help`/`--version`; it does **not** run the dogfood suite.
- **The real suite runs locally** (or on a self-hosted Mac with the driver
  binary pre-approved in System Settings → Privacy & Security → Accessibility):

  ```sh
  .build/debug/swiftplay test --dir examples/rackmind-macos
  ```

  These scripts drive a live GUI app, so they run serially and need the target app
  (`ai.rackmind.macos`) available. If you're adding a feature, add or update a
  script in [`examples/`](examples/) that exercises it.

Before opening a PR, at minimum confirm the build succeeds and you've run your
change against a real app. Say what you ran in the PR template.

## Code conventions

- Swift 6 idioms; prefer `async`/`await` over GCD.
- Treat `AXError` returns as real errors, not optional-discardable.
- Never log raw element addresses in user-facing output.
- Keep modules small. Selector strings are parsed in `Locator/`, never split by hand.
- Locators are **lazy queries, never handles** — every action re-resolves. No
  stale-element bugs, ever.

## Found an AX gotcha?

macOS AX is full of surprises (SwiftUI not firing notifications, `Tab` not routing
as a command, off-screen `LazyVStack` rows literally not existing). When you hit
one, add it to [`examples/rackmind-macos/FINDINGS.md`](examples/rackmind-macos/FINDINGS.md)
so the next person doesn't rediscover it.

## Scope

A few things are deliberately **out of scope** — please check before proposing
them: iOS / iPadOS / visionOS (use XCUITest), Windows / Linux native, web views
inside Mac apps (use Playwright), and network mocking.

## License

By contributing, you agree your contributions are licensed under the
[Apache License 2.0](LICENSE), the same as the project.
