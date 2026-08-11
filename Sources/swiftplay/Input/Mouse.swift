import CoreGraphics
import Foundation

/// CGEvent-based mouse synthesis.
///
/// This is the *fallback* substrate, not the primary one. Anything that exposes
/// a semantic AX action should be driven through `AXElement.perform` instead —
/// see `ClickCommand`, which only reaches for this when the matched element has
/// no `kAXPressAction`. Mouse synthesis is reserved for what AX cannot express:
/// hover states, and hit areas in Metal/Canvas-drawn surfaces.
///
/// Click coordinates are always resolved from an element's `kAXPosition` +
/// `kAXSize` (never hard-coded) — the caller passes the already-resolved screen
/// point. Events are posted globally at the HID tap, which hit-tests against
/// whatever window is topmost at that point; callers are therefore responsible
/// for ensuring the target is frontmost first, and `clickRestoringCursor` exists
/// so the automation path can put the user's pointer back afterwards.
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

    /// `click(at:)`, but the pointer is returned to wherever the user had it.
    ///
    /// A synthesized click physically moves the cursor and leaves it on the
    /// element — on a machine someone is working at, that is half of the
    /// intrusion (the other half, focus, is restored by the caller). We read the
    /// current location first, click, then warp back.
    ///
    /// The warp is deliberately silent: `CGWarpMouseCursorPosition` moves the
    /// cursor without synthesizing a move event, so no app sees a spurious
    /// mouse-exited/entered pair from the restore. It does briefly decouple the
    /// cursor from the physical mouse, hence the re-associate.
    static func clickRestoringCursor(at point: CGPoint) {
        let origin = CGEvent(source: nil)?.location
        click(at: point)
        guard let origin else { return }
        // Let the target consume the mouse-up before the pointer leaves the
        // element; warping mid-dispatch can register as a drag.
        usleep(20_000)
        _ = CGWarpMouseCursorPosition(origin)
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }
}
