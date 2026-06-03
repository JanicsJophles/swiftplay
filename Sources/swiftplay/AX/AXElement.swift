import ApplicationServices
import CoreGraphics
import Foundation

struct AXElement {
    let ref: AXUIElement

    static var systemWide: AXElement {
        AXElement(ref: AXUIElementCreateSystemWide())
    }

    static func application(pid: pid_t) -> AXElement {
        AXElement(ref: AXUIElementCreateApplication(pid))
    }

    func element(at point: CGPoint) -> AXElement? {
        var elem: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(ref, Float(point.x), Float(point.y), &elem)
        guard err == .success, let elem else { return nil }
        return AXElement(ref: elem)
    }

    func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
        return err == .success ? value : nil
    }

    var role: String? { attribute(kAXRoleAttribute) as? String }
    var subrole: String? { attribute(kAXSubroleAttribute) as? String }
    var roleDescription: String? { attribute(kAXRoleDescriptionAttribute) as? String }
    var title: String? { attribute(kAXTitleAttribute) as? String }
    var label: String? { attribute(kAXDescriptionAttribute) as? String }
    var help: String? { attribute(kAXHelpAttribute) as? String }
    var identifier: String? { attribute(kAXIdentifierAttribute) as? String }

    var value: String? {
        guard let v = attribute(kAXValueAttribute) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    var isEnabled: Bool {
        (attribute(kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true
    }

    var isFocused: Bool {
        (attribute(kAXFocusedAttribute) as? NSNumber)?.boolValue ?? false
    }

    var position: CGPoint? {
        guard let v = attribute(kAXPositionAttribute) else { return nil }
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let axValue = v as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    var size: CGSize? {
        guard let v = attribute(kAXSizeAttribute) else { return nil }
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let axValue = v as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    var children: [AXElement] {
        guard let raw = attribute(kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return raw.map { AXElement(ref: $0) }
    }

    var actions: [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(ref, &names)
        guard err == .success, let names = names as? [String] else { return [] }
        return names
    }

    /// Perform a semantic AX action (e.g. `kAXPressAction`). Unlike a synthesized
    /// mouse click this needs neither foreground focus nor cursor movement, so it
    /// works against a backgrounded app.
    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(ref, action as CFString) == .success
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        let err = AXUIElementGetPid(ref, &pid)
        return err == .success ? pid : nil
    }
}
