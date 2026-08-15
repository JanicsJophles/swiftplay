import CoreGraphics
import XCTest

@testable import swiftplay

/// Character → virtual-keycode mapping used by `Keyboard.type`.
///
/// This is pure logic: no GUI, no target app, no Accessibility permission, so it
/// runs anywhere. The event *posting* is still unverifiable in a sandbox — these
/// tests cover which keycode/modifier/unicode payload gets built, which is where
/// the "Krish" → "Aaaaa" bug actually lived.
final class KeyboardMappingTests: XCTestCase {

    // MARK: - The regression that motivated this

    /// Every character used to be sent as virtual keycode 0 (`kVK_ANSI_A`).
    /// Native apps hid it by reading the unicode payload; the iOS Simulator reads
    /// the keycode, so "Krish" arrived as "Aaaaa" — right length, every character
    /// wrong. Guard the exact reported string.
    func testKrishDoesNotCollapseToKeycodeZero() {
        let codes = Keyboard.typePlan(for: "Krish").compactMap { step -> CGKeyCode? in
            if case let .key(code, _, _) = step { return code }
            return nil
        }
        // K r i s h — five keys, and they must not all be 0.
        XCTAssertEqual(codes.count, 5)
        XCTAssertEqual(codes, [0x28, 0x0F, 0x22, 0x01, 0x04])
        XCTAssertNotEqual(Set(codes).count, 1, "all characters collapsed to one keycode")
    }

    /// The sharpest form of the bug: keycode 0 is a real key ('a'), so it must be
    /// produced *only* by 'a' and 'A'. Any other character resolving to 0 means it
    /// fell through to the unicode-only fallback.
    func testKeycodeZeroIsReachableOnlyByLetterA() {
        let printableASCII = (0x20...0x7E).map { Character(UnicodeScalar($0)!) }
        for character in printableASCII {
            let stroke = Keyboard.keyStroke(for: character)
            XCTAssertNotNil(stroke, "no keycode for printable ASCII '\(character)'")
            if stroke?.code == 0 {
                XCTAssertTrue(
                    character == "a" || character == "A",
                    "'\(character)' resolved to keycode 0 (kVK_ANSI_A)"
                )
            }
        }
    }

    // MARK: - Letters

    func testLowercaseLettersMapToTheirKeycodeWithoutShift() {
        // kVK_ANSI_* for a…z, in alphabetical order.
        let expected: [Character: CGKeyCode] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
            "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
            "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
            "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
            "y": 0x10, "z": 0x06,
        ]
        for (character, code) in expected {
            let stroke = Keyboard.keyStroke(for: character)
            XCTAssertEqual(stroke?.code, code, "keycode for '\(character)'")
            XCTAssertEqual(stroke?.flags, [], "'\(character)' must not carry shift")
        }
    }

    func testUppercaseLettersReuseTheLowercaseKeycodePlusShift() {
        for lower in "abcdefghijklmnopqrstuvwxyz" {
            let upper = Character(String(lower).uppercased())
            let lowerStroke = Keyboard.keyStroke(for: lower)
            let upperStroke = Keyboard.keyStroke(for: upper)
            XCTAssertEqual(upperStroke?.code, lowerStroke?.code, "'\(upper)' vs '\(lower)' keycode")
            XCTAssertEqual(upperStroke?.flags, .maskShift, "'\(upper)' needs shift")
        }
    }

    // MARK: - Digits and their shifted symbols

    func testDigitsMapWithoutShift() {
        let expected: [Character: CGKeyCode] = [
            "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
            "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
        ]
        for (character, code) in expected {
            let stroke = Keyboard.keyStroke(for: character)
            XCTAssertEqual(stroke?.code, code, "keycode for '\(character)'")
            XCTAssertEqual(stroke?.flags, [], "'\(character)' must not carry shift")
        }
    }

    func testShiftedDigitSymbolsReuseTheDigitKeycodePlusShift() {
        let pairs: [(Character, Character)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"),
            ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"), (")", "0"),
        ]
        for (symbol, digit) in pairs {
            let symbolStroke = Keyboard.keyStroke(for: symbol)
            let digitStroke = Keyboard.keyStroke(for: digit)
            XCTAssertEqual(symbolStroke?.code, digitStroke?.code, "'\(symbol)' sits on the '\(digit)' key")
            XCTAssertEqual(symbolStroke?.flags, .maskShift, "'\(symbol)' needs shift")
        }
    }

    // MARK: - Punctuation

    func testUnshiftedPunctuation() {
        let expected: [Character: CGKeyCode] = [
            "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A,
            ";": 0x29, "'": 0x27, "`": 0x32, ",": 0x2B, ".": 0x2F, "/": 0x2C,
        ]
        for (character, code) in expected {
            let stroke = Keyboard.keyStroke(for: character)
            XCTAssertEqual(stroke?.code, code, "keycode for '\(character)'")
            XCTAssertEqual(stroke?.flags, [], "'\(character)' must not carry shift")
        }
    }

    func testShiftedPunctuationSharesTheUnshiftedKey() {
        let pairs: [(Character, Character)] = [
            ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"),
            (":", ";"), ("\"", "'"), ("~", "`"), ("<", ","), (">", "."), ("?", "/"),
        ]
        for (shifted, base) in pairs {
            let shiftedStroke = Keyboard.keyStroke(for: shifted)
            let baseStroke = Keyboard.keyStroke(for: base)
            XCTAssertEqual(shiftedStroke?.code, baseStroke?.code, "'\(shifted)' sits on the '\(base)' key")
            XCTAssertEqual(shiftedStroke?.flags, .maskShift, "'\(shifted)' needs shift")
        }
    }

    func testWhitespaceMapsToRealKeys() {
        XCTAssertEqual(Keyboard.keyStroke(for: " ")?.code, 0x31, "space")
        XCTAssertEqual(Keyboard.keyStroke(for: "\t")?.code, 0x30, "tab")
        XCTAssertEqual(Keyboard.keyStroke(for: "\n")?.code, 0x24, "return")
        XCTAssertEqual(Keyboard.keyStroke(for: "\r")?.code, 0x24, "carriage return → return")
        for character in " \t\n\r" {
            XCTAssertEqual(Keyboard.keyStroke(for: character)?.flags, [], "whitespace must not carry shift")
        }
    }

    // MARK: - Characters with no US-QWERTY key

    /// Emoji, accented letters and CJK have no US-QWERTY keycode. They must
    /// return nil so `type` falls back to the unicode-only path (which still
    /// works on native macOS) rather than sending a wrong keycode.
    func testUnmappableCharactersReturnNil() {
        for character in "é😀日本語ß—" {
            XCTAssertNil(Keyboard.keyStroke(for: character), "'\(character)' should have no US-QWERTY keycode")
        }
    }

    func testUnmappableCharactersStillCarryTheirUnicodePayload() {
        let plan = Keyboard.typePlan(for: "é😀")
        let keys = plan.compactMap { step -> (CGKeyCode, String)? in
            if case let .key(code, _, text) = step { return (code, text) }
            return nil
        }
        XCTAssertEqual(keys.count, 2)
        // Fallback keycode 0, but the character itself is preserved for native apps.
        XCTAssertEqual(keys.map(\.0), [0, 0])
        XCTAssertEqual(keys.map(\.1), ["é", "😀"])
    }

    // MARK: - Plan shape

    func testPlanHoldsShiftAcrossARunAndReleasesItOnce() {
        let plan = Keyboard.typePlan(for: "ABc")
        XCTAssertEqual(plan, [
            .shift(down: true),
            .key(code: 0x00, flags: .maskShift, text: "A"),
            .key(code: 0x0B, flags: .maskShift, text: "B"),
            .shift(down: false),
            .key(code: 0x08, flags: [], text: "c"),
        ])
    }

    func testPlanEmitsNoShiftForAnAllLowercaseString() {
        let plan = Keyboard.typePlan(for: "hello world")
        XCTAssertFalse(plan.contains { if case .shift = $0 { return true } else { return false } })
    }

    /// A stuck shift key in the target would corrupt everything typed afterwards,
    /// so every plan must leave shift released.
    func testPlanIsAlwaysShiftBalanced() {
        let samples = [
            "Krish", "ABC", "aBcD", "Hello, World!", "", "a", "A",
            "user@example.com", "P@ssw0rd!", "😀A", "A😀", "  ", "\n\tX",
        ]
        for sample in samples {
            var held = false
            for step in Keyboard.typePlan(for: sample) {
                if case let .shift(down) = step {
                    XCTAssertNotEqual(down, held, "redundant shift event in '\(sample)'")
                    held = down
                }
            }
            XCTAssertFalse(held, "shift left held down after typing '\(sample)'")
        }
    }

    func testEveryCharacterProducesExactlyOneKeyStep() {
        let text = "Hello, World! 123 😀"
        let keySteps = Keyboard.typePlan(for: text).filter { if case .key = $0 { return true } else { return false } }
        XCTAssertEqual(keySteps.count, text.count)
    }

    func testEmptyStringProducesNoSteps() {
        XCTAssertEqual(Keyboard.typePlan(for: ""), [])
    }

    // MARK: - A realistic form-fill string

    func testEmailAddressResolvesEveryCharacter() {
        for character in "rep.one+test@example.com" {
            XCTAssertNotNil(Keyboard.keyStroke(for: character), "no keycode for '\(character)'")
        }
        // '@' and '+' are shifted; the rest are not.
        let plan = Keyboard.typePlan(for: "a+b@c")
        XCTAssertEqual(plan, [
            .key(code: 0x00, flags: [], text: "a"),
            .shift(down: true),
            .key(code: 0x18, flags: .maskShift, text: "+"),
            .shift(down: false),
            .key(code: 0x0B, flags: [], text: "b"),
            .shift(down: true),
            .key(code: 0x13, flags: .maskShift, text: "@"),
            .shift(down: false),
            .key(code: 0x08, flags: [], text: "c"),
        ])
    }

    // MARK: - Chord parsing still works off the same map

    /// `keyStroke` reuses `namedKeys`, which `parseChord` also reads. Extending
    /// that map for text input must not disturb chords.
    func testChordParsingUnaffectedByTheAddedPunctuation() {
        XCTAssertEqual(Keyboard.parseChord("cmd+k")?.code, 0x28)
        XCTAssertEqual(Keyboard.parseChord("cmd+k")?.flags, .maskCommand)
        XCTAssertEqual(Keyboard.parseChord("cmd+comma")?.code, 0x2B)
        XCTAssertEqual(Keyboard.parseChord("tab")?.code, 0x30)
        XCTAssertNil(Keyboard.parseChord("cmd+nope"))
    }

    /// The new tokens are usable as chord bases too (e.g. ⌘- to zoom out).
    func testAddedPunctuationTokensAreChordable() {
        XCTAssertEqual(Keyboard.parseChord("cmd+minus")?.code, 0x1B)
        XCTAssertEqual(Keyboard.parseChord("cmd+equal")?.code, 0x18)
    }

    // MARK: - Emission tests
    //
    // These assert on `Keyboard.emissions`, which is what `type` actually posts.
    // The rest of this file tests `typePlan` — intent — and every one of those
    // stayed green when `virtualKey: code` was reverted to `virtualKey: 0`, the
    // exact defect the suite is named for. Intent was never the broken layer.

    /// The revert test. Reintroducing `virtualKey: 0` MUST fail this.
    func testEmissionsCarryTheCharactersOwnKeycodeNotZero() {
        let out = Keyboard.emissions(for: "Krish")
        // Two events per character (down, up); "K" is shifted so it is bracketed.
        let characterKeys = out.filter { !$0.unicode.isEmpty }
        XCTAssertEqual(characterKeys.count, 10, "5 characters × down+up")

        // kVK_ANSI_A is 0. If every character collapsed to it, the Simulator
        // types "Aaaaa" — the reported symptom.
        let keycodes = Set(characterKeys.map { $0.virtualKey })
        XCTAssertFalse(
            keycodes == [0],
            "every character emitted keycode 0 (kVK_ANSI_A) — this is the 'Krish' → 'Aaaaa' bug"
        )
        XCTAssertEqual(
            keycodes.count, 5,
            "K/r/i/s/h are five distinct keys and must emit five distinct keycodes, got \(keycodes.sorted())"
        )

        // And each emitted keycode must be the one the plan chose for that char.
        for emission in characterKeys {
            guard let expected = Keyboard.namedKeys[emission.unicode.lowercased()] else { continue }
            XCTAssertEqual(
                emission.virtualKey, expected,
                "'\(emission.unicode)' emitted keycode \(emission.virtualKey), expected \(expected)"
            )
        }
    }

    /// Shift must be a real modifier key, held around the shifted character, and
    /// must not carry a character payload of its own.
    func testShiftIsBracketedAndCarriesNoCharacter() {
        let out = Keyboard.emissions(for: "aB")
        let shifts = out.filter { $0.unicode.isEmpty }
        XCTAssertEqual(shifts.count, 2, "one shift down and one shift up around 'B'")
        XCTAssertTrue(shifts.allSatisfy { $0.virtualKey == Keyboard.shiftKeyCode })

        guard let downIndex = out.firstIndex(where: { $0.unicode.isEmpty && $0.keyDown }),
              let bIndex = out.firstIndex(where: { $0.unicode == "B" }),
              let upIndex = out.lastIndex(where: { $0.unicode.isEmpty && !$0.keyDown })
        else { return XCTFail("expected a shift-down, a 'B', and a shift-up") }
        XCTAssertLessThan(downIndex, bIndex, "shift must go down BEFORE the character")
        XCTAssertGreaterThan(upIndex, bIndex, "shift must lift AFTER the character")
    }

    /// A shift-down must be followed by the settle delay. Without it the modifier
    /// and the key it modifies arrive in the same instant and a consumer that
    /// reads key-down before registering the modifier types the unshifted char.
    func testShiftDownSettlesBeforeTheKeyItModifies() {
        let out = Keyboard.emissions(for: "aB")
        guard let shiftDown = out.first(where: { $0.unicode.isEmpty && $0.keyDown }) else {
            return XCTFail("no shift-down emitted")
        }
        XCTAssertTrue(shiftDown.settleAfter, "shift-down must be followed by charDelayMs")
    }

    /// Characters with no US-QWERTY key still type on native macOS through the
    /// unicode payload. They are knowingly unsupported against the Simulator;
    /// what must NOT happen is dropping them.
    func testUnmappableCharactersStillEmitTheirUnicodePayload() {
        let out = Keyboard.emissions(for: "é")
        let chars = out.filter { !$0.unicode.isEmpty }
        XCTAssertEqual(chars.count, 2, "down + up")
        XCTAssertEqual(chars.first?.unicode, "é", "the character must survive as unicode")
    }
}

final class FrontmostAppTrackerTests: XCTestCase {
    func testRestoresTheAppThatWasFocusedBeforeTargetActivation() {
        var tracker = FrontmostAppTracker(initialPID: 101)

        XCTAssertEqual(
            tracker.observe(frontmostPID: 202, targetPID: 202),
            101
        )
    }

    func testFollowsAUserInitiatedFocusChangeDuringLaunch() {
        var tracker = FrontmostAppTracker(initialPID: 101)

        XCTAssertNil(tracker.observe(frontmostPID: 303, targetPID: 202))
        XCTAssertEqual(
            tracker.observe(frontmostPID: 202, targetPID: 202),
            303
        )
    }

    func testDoesNotRestoreTheTargetToItself() {
        var tracker = FrontmostAppTracker(initialPID: 202)

        XCTAssertNil(tracker.observe(frontmostPID: 202, targetPID: 202))
    }

    func testMissingFrontmostStateDoesNotEraseTheLastSafeApp() {
        var tracker = FrontmostAppTracker(initialPID: 101)

        XCTAssertNil(tracker.observe(frontmostPID: nil, targetPID: 202))
        XCTAssertEqual(
            tracker.observe(frontmostPID: 202, targetPID: 202),
            101
        )
    }
}
