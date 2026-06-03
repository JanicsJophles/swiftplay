#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "CVirtualDisplay.h"

// Private CoreGraphics interfaces (CGVirtualDisplay*). Declared here so the Swift
// side stays clean. Layout is the long-standing one used by every virtual-display
// tool (BetterDisplay et al.); verified working on this machine's macOS.
@interface CGVirtualDisplayDescriptor : NSObject
@property(strong) dispatch_queue_t queue;
@property(copy) NSString *name;
@property uint32_t maxPixelsWide, maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property uint32_t serialNum, productID, vendorID;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)w height:(uint32_t)h refreshRate:(double)r;
@end

@interface CGVirtualDisplaySettings : NSObject
@property uint32_t hiDPI;
@property(copy) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property(readonly) CGDirectDisplayID displayID;
@end

// We retain the CGVirtualDisplay instance for the lifetime of the handle; ARC
// drops it (destroying the display) on SPVirtualDisplayRelease.
struct SPVirtualDisplay {
    CFTypeRef display;  // retained CGVirtualDisplay *
};

SPVirtualDisplayRef SPVirtualDisplayCreate(uint32_t width, uint32_t height, bool retina, CGDirectDisplayID *outDisplayID) {
    @autoreleasepool {
        Class DescC = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class SetC  = NSClassFromString(@"CGVirtualDisplaySettings");
        Class ModeC = NSClassFromString(@"CGVirtualDisplayMode");
        Class DispC = NSClassFromString(@"CGVirtualDisplay");
        if (!DescC || !SetC || !ModeC || !DispC) return NULL;

        // Recipe (verified on macOS 26): mode dimensions are POINTS, maxPixels is
        // scale× those points, hiDPI flags it retina. So mode=points + max=2×
        // + hiDPI=1 → a 2× display; scale=1 + hiDPI=0 → a 1× display.
        uint32_t scale = retina ? 2 : 1;

        CGVirtualDisplayDescriptor *d = [[DescC alloc] init];
        d.queue = dispatch_get_main_queue();
        d.name = @"swiftplay-headless";
        d.maxPixelsWide = width * scale;
        d.maxPixelsHigh = height * scale;
        // A plausible physical size keeps the DPI sane; exact value is cosmetic.
        d.sizeInMillimeters = CGSizeMake(width * 0.2117, height * 0.2117);
        d.productID = 0x7059;  // "py"
        d.vendorID  = 0x5350;  // "SP"
        d.serialNum = 0x0001;
        d.redPrimary   = CGPointMake(0.640, 0.330);
        d.greenPrimary = CGPointMake(0.300, 0.600);
        d.bluePrimary  = CGPointMake(0.150, 0.060);
        d.whitePoint   = CGPointMake(0.3127, 0.3290);
        d.terminationHandler = ^(id a, id b) { (void)a; (void)b; };

        CGVirtualDisplay *disp = [[DispC alloc] initWithDescriptor:d];
        if (!disp) return NULL;

        CGVirtualDisplayMode *mode = [[ModeC alloc] initWithWidth:width height:height refreshRate:60.0];
        CGVirtualDisplaySettings *s = [[SetC alloc] init];
        s.hiDPI = retina ? 1 : 0;
        s.modes = @[mode];
        if (![disp applySettings:s]) return NULL;

        CGDirectDisplayID did = [disp displayID];
        if (did == 0) return NULL;
        if (outDisplayID) *outDisplayID = did;

        struct SPVirtualDisplay *handle = calloc(1, sizeof(struct SPVirtualDisplay));
        handle->display = CFBridgingRetain(disp);
        return handle;
    }
}

void SPVirtualDisplayRelease(SPVirtualDisplayRef handle) {
    if (!handle) return;
    if (handle->display) CFRelease(handle->display);  // drops the CGVirtualDisplay -> display goes away
    free(handle);
}
