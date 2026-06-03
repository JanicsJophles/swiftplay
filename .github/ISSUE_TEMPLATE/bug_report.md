---
name: Bug report
about: Something swiftplay did wrong while driving a macOS app
title: "[bug] "
labels: bug
---

**What happened**
A clear description of the bug.

**Command / code that triggered it**
```sh
.build/debug/swiftplay ...
```

**Target app**
- Bundle id (or `--path`):
- AppKit / SwiftUI / mixed:
- Is it sandboxed / signed?

**Expected vs actual**
- Expected:
- Actual:

**AX tree slice (very helpful)**
Output of `swiftplay tree -b <bundle-id>` (or the relevant subtree) around the element you were targeting.

**Environment**
- macOS version:
- Output of `swift --version`:
- swiftplay commit (`git rev-parse --short HEAD`):
- Did you grant your terminal Accessibility (and Screen Recording, if relevant) permission? (yes/no)

**Anything else**
Screenshots, traces, or notes.
