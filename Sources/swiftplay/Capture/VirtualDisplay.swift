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

    /// Whether this display ended up presenting at 2× (retina).
    var isRetina: Bool {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return false }
        return mode.pixelWidth / mode.width >= 2
    }

    /// Global (points) bounds of the display, for positioning windows onto it.
    var bounds: CGRect { CGDisplayBounds(displayID) }

    deinit { SPVirtualDisplayRelease(handle) }
}
