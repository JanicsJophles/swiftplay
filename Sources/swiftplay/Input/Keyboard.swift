import AppKit
import CoreGraphics
import Foundation

/// CGEvent-based keyboard synthesis.
///
/// Text input goes through `keyboardSetUnicodeString` so we can type arbitrary
/// characters without maintaining a keycode map; named keys (arrows, Tab,
/// Return…) need real virtual keycodes because they carry no character payload.
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
    /// Each character is posted as a keyDown/keyUp pair carrying its unicode value.
    static func type(_ text: String, toPid pid: pid_t? = nil, charDelayMs: Int = 8) {
        let source = CGEventSource(stateID: .privateState)
        for scalarChar in text {
            let utf16 = Array(String(scalarChar).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                utf16.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                    }
                }
                post(event, toPid: pid)
            }
            usleep(UInt32(charDelayMs * 1000))
        }
    }

    /// Virtual keycodes for modifier keys, so chords can bracket the base key
    /// with real modifier down/up events (kVK_Command etc.).
    private static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 0x37), (.maskShift, 0x38), (.maskAlternate, 0x3A), (.maskControl, 0x3B),
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
