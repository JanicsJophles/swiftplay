import CoreGraphics
import Foundation

/// CGEvent-based mouse synthesis.
///
/// Click coordinates are always resolved from an element's `kAXPosition` +
/// `kAXSize` (never hard-coded) — the caller passes the already-resolved screen
/// point. Mouse events are posted globally at the HID tap with the target app
/// frontmost, which is the reliable path for pointer hit-testing.
enum Mouse {
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
