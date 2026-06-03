#ifndef CVIRTUALDISPLAY_H
#define CVIRTUALDISPLAY_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

/// Opaque owner of a headless `CGVirtualDisplay`. The display exists only while
/// the handle is alive — release it (or let the process die) and macOS tears the
/// display down and relocates any windows on it back to a physical screen.
///
/// This wraps the private CoreGraphics `CGVirtualDisplay*` ObjC classes behind a
/// plain-C surface so the Swift side never touches the private symbols directly.
/// swiftplay's driver is un-sandboxed Developer-ID and never ships via the Mac
/// App Store, so the private API is acceptable here.
typedef struct SPVirtualDisplay *SPVirtualDisplayRef;

/// Create an off-screen virtual display whose *point* size is width×height. When
/// `retina` is true the display is backed at 2× (HiDPI), so captures come out at
/// 2× resolution; otherwise it's 1×. Returns NULL on failure (private classes
/// missing or `applySettings` rejected). On success `*outDisplayID` receives the
/// CGDirectDisplayID and the returned handle must be kept alive for as long as
/// the display should exist; free it with `SPVirtualDisplayRelease`.
SPVirtualDisplayRef SPVirtualDisplayCreate(uint32_t width, uint32_t height, bool retina, CGDirectDisplayID *outDisplayID);

/// Release the display (and the handle). Safe to call with NULL.
void SPVirtualDisplayRelease(SPVirtualDisplayRef handle);

#endif /* CVIRTUALDISPLAY_H */
