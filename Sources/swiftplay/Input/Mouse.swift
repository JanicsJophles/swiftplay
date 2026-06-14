import CoreGraphics
import Foundation

/// CGEvent-based mouse synthesis.
///
/// Click coordinates are always resolved from an element's `kAXPosition` +
/// `kAXSize` (never hard-coded) — the caller passes the already-resolved screen
/// point. Mouse events are posted globally at the HID tap with the target app
/// frontmost, which is the reliable path for pointer hit-testing.
enum Mouse {
    /// Move the pointer without clicking — drives hover states for the cinematic
    /// recorder. (The footage captures with the system cursor off, so this never
    /// shows up on screen; the renderer draws its own cursor.)
    static func move(to point: CGPoint) {
        let source = CGEventSource(stateID: .privateState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .privateState)
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        usleep(20_000)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }
}
