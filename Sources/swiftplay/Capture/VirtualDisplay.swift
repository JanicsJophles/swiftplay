import CVirtualDisplay
import CoreGraphics

/// A headless virtual display. Exists only while this object is alive — `deinit`
/// (or process death) tears it down and macOS relocates any windows on it back
/// to a physical screen. This is swiftplay's native answer to "render off-screen
/// with no monitor", the equivalent of a browser's offscreen compositor.
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    private let handle: SPVirtualDisplayRef

    /// Create a virtual display of the given *point* size. `retina` backs it at
    /// 2× so captures are full-resolution.
    init?(pointWidth: Int, pointHeight: Int, retina: Bool) {
        var did: CGDirectDisplayID = 0
        guard let handle = SPVirtualDisplayCreate(UInt32(pointWidth), UInt32(pointHeight), retina, &did), did != 0 else {
            return nil
        }
        self.handle = handle
        self.displayID = did
    }

    /// Whether this display is currently presenting at 2× (retina).
    var isRetina: Bool {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return false }
        return mode.pixelWidth / mode.width >= 2
    }

    /// Switch this display to a 2× HiDPI mode at the given point size, if one is
    /// available. Scoped to *this* display only via `CGDisplaySetDisplayMode` — no
    /// global/transactional reconfiguration (that's what could disrupt the
    /// desktop). Keeping the same point size means the display's bounds — and any
    /// window already placed on it — are unaffected; only the backing scale
    /// changes. Returns whether 2× is now active.
    @discardableResult
    func enableRetina(pointWidth: Int, pointHeight: Int) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return false }
        // 2× modes at the exact point size we created the display with — picking a
        // different point size would resize the display and strand the window.
        let match = modes.first {
            $0.width == pointWidth && $0.height == pointHeight
                && $0.pixelWidth == pointWidth * 2 && $0.pixelHeight == pointHeight * 2
        }
        guard let retinaMode = match else { return false }
        CGDisplaySetDisplayMode(displayID, retinaMode, nil)
        return isRetina
    }

    /// Global (points) bounds of the display, for positioning windows onto it.
    var bounds: CGRect { CGDisplayBounds(displayID) }

    deinit { SPVirtualDisplayRelease(handle) }
}
