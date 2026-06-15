import AppKit
import CoreText
import Foundation

/// Registers the bundled brand typeface (Geist) so rendered captions, titles, and
/// the end card match the RackMind website instead of falling back to the system
/// font. Geist ships as variable fonts; we register them once and resolve a
/// concrete weight per request via the font descriptor's weight trait.
enum BrandFont {
    /// Family name as exposed by the registered font (the `family` in the TTF).
    static let sansFamily = "Geist"
    static let monoFamily = "Geist Mono"

    private static let register: Void = {
        for name in ["GeistVF", "GeistMonoVF"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            var err: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
            // Already-registered is fine; anything else we silently tolerate and
            // fall back to the system font below.
        }
    }()

    /// A Geist font at the given size + weight, or the system font of the same
    /// weight if registration somehow failed (so the render never crashes).
    static func sans(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        _ = register
        let desc = NSFontDescriptor(fontAttributes: [
            .family: sansFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        if let f = NSFont(descriptor: desc, size: size), f.familyName == sansFamily {
            return f
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}
