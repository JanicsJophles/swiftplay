import AppKit
import CoreGraphics
import Foundation

/// CGEvent-based keyboard synthesis.
///
/// Text input carries a real US-QWERTY virtual keycode *and* a
/// `keyboardSetUnicodeString` payload, because the two classes of consumer read
/// different halves: native macOS apps take the unicode string, while the iOS
/// Simulator ignores it and maps the keycode. Named keys (arrows, Tab, Return…)
/// need real virtual keycodes because they carry no character payload at all.
/// `namedKeys` is the single keycode map serving chords and text alike.
///
/// Events are delivered with `CGEvent.postToPid` when a target pid is known.
/// Posting straight to the process (the way System Events does) bypasses the
/// session-level focus manager — which otherwise swallows command/focus keys
/// like Tab before they reach the focused view's `doCommandBy` — and removes
/// any dependency on the app being frontmost. Without a pid we fall back to the
/// global HID tap.
enum Keyboard {
    /// CG virtual keycodes (US QWERTY) from `<HIToolbox/Events.h>` (kVK_*).
    /// Covers named keys plus letters/digits/punctuation so chords like
    /// "cmd+k" or "cmd+comma" resolve to a base key.
    static let namedKeys: [String: CGKeyCode] = [
        // named
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        // punctuation (spelled out so they survive "+"-splitting)
        "comma": 0x2B, "period": 0x2F, "slash": 0x2C,
        "minus": 0x1B, "equal": 0x18,
        "leftbracket": 0x21, "rightbracket": 0x1E,
        "backslash": 0x2A, "semicolon": 0x29, "quote": 0x27, "grave": 0x32,
        // letters
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
        // digits
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
        "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    ]

    /// Characters that sit on a US-QWERTY key with no modifier, mapped to their
    /// `namedKeys` token. Letters and digits are omitted because they *are*
    /// their own token — `keyStroke(for:)` looks those up directly.
    private static let unshiftedChars: [Character: String] = [
        " ": "space", "\t": "tab", "\n": "return", "\r": "return",
        "-": "minus", "=": "equal", "[": "leftbracket", "]": "rightbracket",
        "\\": "backslash", ";": "semicolon", "'": "quote", "`": "grave",
        ",": "comma", ".": "period", "/": "slash",
    ]

    /// Characters produced by holding shift on US-QWERTY, mapped to the
    /// `namedKeys` token of the *unshifted* key in the same physical position.
    private static let shiftedChars: [Character: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
        "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "minus", "+": "equal", "{": "leftbracket", "}": "rightbracket",
        "|": "backslash", ":": "semicolon", "\"": "quote", "~": "grave",
        "<": "comma", ">": "period", "?": "slash",
    ]

    /// Resolve a character to the physical US-QWERTY key that produces it, plus
    /// the modifier flags needed to shift it.
    ///
    /// Returns nil for anything with no US-QWERTY key — emoji, accented letters,
    /// CJK. Those characters keep working on native macOS via the unicode-string
    /// payload alone (see `type`), but cannot be delivered to consumers that read
    /// the virtual keycode, such as the iOS Simulator.
    ///
    /// Layout caveat: this is a fixed US-QWERTY table, not a query of the active
    /// input source. On a non-US layout (Dvorak, AZERTY) the keycode we send is
    /// re-interpreted by that layout, so keycode-reading consumers will see the
    /// wrong character. Native macOS is unaffected — it reads the unicode string.
    /// A layout-aware version would reverse-map via `UCKeyTranslate`.
    static func keyStroke(for character: Character) -> (code: CGKeyCode, flags: CGEventFlags)? {
        if let token = unshiftedChars[character], let code = namedKeys[token] {
            return (code, [])
        }
        if let token = shiftedChars[character], let code = namedKeys[token] {
            return (code, .maskShift)
        }
        // Letters and digits: the lowercase form is the `namedKeys` token, and an
        // uppercase letter is the shifted form of that same key.
        let lowered = String(character).lowercased()
        guard let code = namedKeys[lowered] else { return nil }
        return (code, String(character) == lowered ? [] : .maskShift)
    }

    /// Modifier tokens accepted in a chord spec (e.g. "cmd+shift+k").
    static func modifierFlag(_ token: String) -> CGEventFlags? {
        switch token.lowercased() {
        case "cmd", "command", "⌘": .maskCommand
        case "shift", "⇧": .maskShift
        case "opt", "option", "alt", "⌥": .maskAlternate
        case "ctrl", "control", "⌃": .maskControl
        default: nil
        }
    }

    /// Parse a chord spec like "cmd+k" / "cmd+shift+p" / "tab" into a base
    /// keycode + modifier flags. Returns nil if the base key isn't recognized
    /// or a modifier token is unknown.
    static func parseChord(_ spec: String) -> (code: CGKeyCode, flags: CGEventFlags)? {
        var tokens = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let baseToken = tokens.popLast(), let code = namedKeys[baseToken.lowercased()] else { return nil }
        var flags: CGEventFlags = []
        for mod in tokens {
            guard let f = modifierFlag(mod) else { return nil }
            flags.insert(f)
        }
        return (code, flags)
    }

    private static func post(_ event: CGEvent, toPid pid: pid_t?) {
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Type a literal string into the focused element of the target (or frontmost) app.
    ///
    /// Each character is posted as a keyDown/keyUp pair carrying **both** payloads:
    /// its real US-QWERTY virtual keycode (plus shift where the character needs it)
    /// *and* its unicode value. The two consumers read different halves —
    ///
    /// - Native macOS apps honour `keyboardSetUnicodeString` and use the unicode
    ///   payload, so they see the exact character regardless of keycode.
    /// - The **iOS Simulator** ignores the unicode string and maps the virtual
    ///   keycode through its own layout. It previously received keycode 0
    ///   (`kVK_ANSI_A`) for every character, so typing "Krish" produced "Aaaaa" —
    ///   the right number of characters, every one of them wrong.
    ///
    /// Sending both satisfies both, and keeps native behaviour unchanged.
    ///
    /// Characters with no US-QWERTY key (emoji, accented letters, CJK) fall back
    /// to the old unicode-only path with keycode 0. They still type correctly on
    /// native macOS; they remain unsupported against the Simulator.
    ///
    /// Shift is posted as a real modifier key held across a run of shifted
    /// characters — the same bracketing `press` uses — rather than only as an
    /// event flag, because a keycode-reading consumer tracks modifier key state
    /// rather than inspecting each event's flags. The flags are set as well.
    static func type(_ text: String, toPid pid: pid_t? = nil, charDelayMs: Int = 8) {
        let source = CGEventSource(stateID: .privateState)
        for emission in emissions(for: text) {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: emission.virtualKey,
                keyDown: emission.keyDown
            ) else { continue }
            // Flags first, unicode payload last: the unicode string is the
            // authoritative payload for native apps and must not be clobbered.
            event.flags = emission.flags
            if !emission.unicode.isEmpty {
                let utf16 = Array(emission.unicode.utf16)
                utf16.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                    }
                }
            }
            post(event, toPid: pid)
            if emission.settleAfter { usleep(UInt32(charDelayMs * 1000)) }
        }
    }

    /// Exactly what [type] will post, in order — the CGEvent field values, not a
    /// plan that something else might interpret differently.
    ///
    /// **This exists so the emission is testable.** The first version of these
    /// tests asserted on `typePlan`, which describes intent; the bug they were
    /// written for (`virtualKey: 0` — the literal keycode for "a", which made
    /// the Simulator type "Aaaaa" for "Krish") lived one layer lower, in the
    /// event construction. Reverting the fix left all 19 tests green. A guard
    /// that passes on the bug it names certifies nothing, so the subject moved
    /// here: `type` is now a thin loop over this, and a test can read the
    /// virtual keycodes that actually go out.
    struct Emission: Equatable {
        let virtualKey: CGKeyCode
        let keyDown: Bool
        let flags: CGEventFlags
        /// Empty for modifier events — a real modifier carries no character.
        let unicode: String
        /// Whether to wait `charDelayMs` after posting. True only after a
        /// character's key-up, so a shift press and the key it modifies are not
        /// delivered in the same instant.
        let settleAfter: Bool
    }

    static func emissions(for text: String) -> [Emission] {
        var out: [Emission] = []
        for step in typePlan(for: text) {
            switch step {
            case let .shift(down):
                out.append(
                    Emission(
                        virtualKey: shiftKeyCode,
                        keyDown: down,
                        flags: down ? .maskShift : [],
                        unicode: "",
                        settleAfter: down
                    )
                )
            case let .key(code, flags, characterText):
                out.append(
                    Emission(
                        virtualKey: code, keyDown: true, flags: flags,
                        unicode: characterText, settleAfter: false
                    )
                )
                out.append(
                    Emission(
                        virtualKey: code, keyDown: false, flags: flags,
                        unicode: characterText, settleAfter: true
                    )
                )
            }
        }
        return out
    }

    /// One step in a typing sequence.
    ///
    /// `type` is untestable without a GUI, a target app and Accessibility
    /// permission, so the decision-making half — which keycode, which modifiers,
    /// which unicode payload, in what order — is expressed as pure data here and
    /// `type` becomes a thin interpreter over it. The original bug (every
    /// character sent as keycode 0) lived in exactly this half, so this is the
    /// part that needs a test.
    enum TypeStep: Equatable {
        /// Press or release the physical shift key.
        case shift(down: Bool)
        /// Post a keyDown/keyUp pair for one character.
        case key(code: CGKeyCode, flags: CGEventFlags, text: String)
    }

    /// Build the event sequence for `text`, holding shift across runs of shifted
    /// characters and always releasing it at the end so the plan is balanced.
    static func typePlan(for text: String) -> [TypeStep] {
        var steps: [TypeStep] = []
        var shiftHeld = false

        func setShift(_ down: Bool) {
            guard down != shiftHeld else { return }
            steps.append(.shift(down: down))
            shiftHeld = down
        }

        for character in text {
            let stroke = keyStroke(for: character)
            let flags = stroke?.flags ?? []
            setShift(flags.contains(.maskShift))
            steps.append(.key(code: stroke?.code ?? 0, flags: flags, text: String(character)))
        }
        // Never leave shift stuck down in the target.
        setShift(false)
        return steps
    }

    /// kVK_Shift — also used by `type` to bracket shifted characters.
    static let shiftKeyCode: CGKeyCode = 0x38

    /// Virtual keycodes for modifier keys, so chords can bracket the base key
    /// with real modifier down/up events (kVK_Command etc.).
    private static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 0x37), (.maskShift, shiftKeyCode), (.maskAlternate, 0x3A), (.maskControl, 0x3B),
    ]

    /// Press a key chord once, e.g. "down", "tab", "cmd+k", "cmd+shift+p".
    /// Returns false if the chord can't be parsed.
    ///
    /// When modifiers are present we post real modifier-key down/up events around
    /// the base key (cmd↓ k↓ k↑ cmd↑) rather than just setting the flag — AppKit's
    /// menu key-equivalent matching (e.g. ⌘K) needs the bracketed sequence.
    @discardableResult
    static func press(_ spec: String, toPid pid: pid_t? = nil) -> Bool {
        guard let (code, flags) = parseChord(spec) else { return false }
        let source = CGEventSource(stateID: .privateState)
        let active = modifierKeyCodes.filter { flags.contains($0.0) }

        for (_, modCode) in active {
            if let e = CGEvent(keyboardEventSource: source, virtualKey: modCode, keyDown: true) {
                e.flags = flags
                post(e, toPid: pid)
            }
        }
        for keyDown in [true, false] {
            if let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) {
                e.flags = flags
                post(e, toPid: pid)
            }
        }
        for (_, modCode) in active.reversed() {
            if let e = CGEvent(keyboardEventSource: source, virtualKey: modCode, keyDown: false) {
                e.flags = []
                post(e, toPid: pid)
            }
        }
        return true
    }

    /// Bring an app to the front so the user can see what's happening.
    /// Returns false if no running app matches the bundle id.
    @discardableResult
    static func activate(bundleId: String) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else { return false }
        app.activate(options: [.activateAllWindows])
        return true
    }
}
