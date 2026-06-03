import CoreGraphics
import Foundation

/// A single AX element that matched a query, with the fields useful for
/// reporting and for resolving a click point.
struct ElementMatch {
    let element: AXElement
    let role: String
    let text: String
    let identifier: String?
    let position: CGPoint?
    let size: CGSize?
}

/// Selector engine: match by role and/or a case-insensitive text substring
/// tested against value, title, description, and identifier. Locators stay
/// lazy — this re-walks the live tree on demand.
enum Query {
    static func find(in root: AXElement, role: String?, text: String?, maxDepth: Int) -> [ElementMatch] {
        var results: [ElementMatch] = []
        walk(root, depth: 0, maxDepth: maxDepth) { elem in
            let elemRole = elem.role ?? ""
            if let role, !role.isEmpty,
               elemRole.range(of: role, options: .caseInsensitive) == nil { return }

            let fields = [elem.value, elem.title, elem.label, elem.identifier].compactMap { $0 }
            if let text, !text.isEmpty {
                let hit = fields.contains { $0.range(of: text, options: .caseInsensitive) != nil }
                guard hit else { return }
            }

            let display = elem.value ?? elem.title ?? elem.label ?? ""
            results.append(ElementMatch(
                element: elem,
                role: elemRole,
                text: display,
                identifier: elem.identifier,
                position: elem.position,
                size: elem.size
            ))
        }
        return results
    }

    private static func walk(_ elem: AXElement, depth: Int, maxDepth: Int, visit: (AXElement) -> Void) {
        visit(elem)
        if depth >= maxDepth { return }
        for child in elem.children {
            walk(child, depth: depth + 1, maxDepth: maxDepth, visit: visit)
        }
    }
}
