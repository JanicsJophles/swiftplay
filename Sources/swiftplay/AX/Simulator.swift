import ApplicationServices
import Foundation

/// Targeting for apps running inside the **iOS Simulator**.
///
/// The Simulator is itself a macOS app, and it bridges the simulated app's
/// accessibility tree up into its own. That is the whole reason this works: the
/// substrate is unchanged — the same `AXUIElement` walk that drives a native Mac
/// app reaches an iOS app running in the Simulator, with no XCUITest, no test
/// bundle, and no device-side agent. (Physical iOS devices have no such bridge
/// and remain out of scope; see CLAUDE.md §1.)
///
/// The tree Simulator exposes looks like this (verified against a booted
/// iPhone 17 Pro on iOS 26.1):
///
/// ```
/// AXApplication "Simulator"
/// ├── AXWindow (AXStandardWindow) title="iPhone 17 Pro – iOS 26.1"
/// │   ├── AXGroup (iOSContentGroup)     ← the simulated app's UI lives here
/// │   ├── AXToolbar                     ┐
/// │   ├── AXButton (AXCloseButton)      │ macOS window chrome —
/// │   ├── AXButton (AXFullScreenButton) │ noise for anyone testing
/// │   ├── AXButton (AXMinimizeButton)   │ the iOS app
/// │   └── AXStaticText "iPhone 17 Pro"  ┘
/// └── AXMenuBar                         ← more noise (Simulator's own menus)
/// ```
///
/// So "target the iOS app" means: find the window belonging to a specific booted
/// device, then scope every query to its `iOSContentGroup` child. That is what
/// `resolve(device:)` returns.
enum Simulator {
    /// Simulator.app's bundle id. The simulated app has no macOS bundle id of its
    /// own, so this is always the process we attach to — the device is selected by
    /// window, not by pid.
    static let bundleId = "com.apple.iphonesimulator"

    /// Subrole Simulator gives the group hosting the simulated app's UI.
    /// Note it carries no `AX` prefix — that is Apple's spelling, not a typo.
    static let contentGroupSubrole = "iOSContentGroup"

    /// A resolved simulator target: which device, which macOS process, and the AX
    /// element every query should be rooted at.
    struct Target {
        let device: SimulatorDevice
        let app: TargetApp
        /// The `iOSContentGroup` element — the simulated app's UI root.
        let root: AXElement
    }

    /// Resolve a booted device (by name or UDID, or the only one booted) and
    /// return its content group, ready to be queried.
    static func resolve(device selector: String?) throws -> Target {
        let device = try resolveDevice(matching: selector)
        guard let app = TargetApp.find(bundleId: bundleId) else {
            throw SimulatorError.simulatorNotRunning
        }
        let axApp = AXElement.application(pid: app.pid)
        let root = try contentGroup(for: device, in: axApp)
        return Target(device: device, app: app, root: root)
    }

    // MARK: - Device discovery

    /// Booted devices, via `xcrun simctl list devices booted -j`.
    ///
    /// simctl is the authority on what is booted. Window titles alone are not:
    /// a device can be booted headlessly (`simctl boot` with no Simulator.app UI),
    /// in which case it has no window and no AX tree — a case worth reporting
    /// honestly rather than silently finding nothing.
    static func bootedDevices() throws -> [SimulatorDevice] {
        let data = try runSimctl(["list", "devices", "booted", "-j"])
        let list: SimctlDeviceList
        do {
            list = try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        } catch {
            throw SimulatorError.simctlFailed("could not parse `simctl list devices booted -j`: \(error.localizedDescription)")
        }
        return list.devices
            .flatMap { runtimeId, devices in
                devices.map { dev in
                    SimulatorDevice(
                        udid: dev.udid,
                        name: dev.name,
                        state: dev.state,
                        runtime: runtimeDisplayName(fromIdentifier: runtimeId)
                    )
                }
            }
            // Stable order so error messages and single-device selection are
            // deterministic across runs (the JSON object's key order is not).
            .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
    }

    /// Pick the device a `--device` selector refers to.
    ///
    /// Matching order: exact UDID, exact name, then case-insensitive substring of
    /// the name (so `--device "17 Pro"` works). Ambiguity is an error rather than
    /// a guess — driving the wrong device would silently test the wrong thing.
    static func resolveDevice(matching selector: String?) throws -> SimulatorDevice {
        let booted = try bootedDevices()
        guard !booted.isEmpty else { throw SimulatorError.noBootedDevices }

        guard let selector, !selector.isEmpty else {
            guard booted.count == 1 else { throw SimulatorError.ambiguousDevice(booted) }
            return booted[0]
        }

        if let exact = booted.first(where: {
            $0.udid.caseInsensitiveCompare(selector) == .orderedSame || $0.name == selector
        }) {
            return exact
        }

        let fuzzy = booted.filter { $0.name.range(of: selector, options: .caseInsensitive) != nil }
        if fuzzy.count == 1 { return fuzzy[0] }
        if fuzzy.count > 1 { throw SimulatorError.ambiguousDevice(fuzzy) }
        throw SimulatorError.deviceNotFound(selector: selector, available: booted)
    }

    /// `"com.apple.CoreSimulator.SimRuntime.iOS-26-1"` → `"iOS 26.1"`.
    static func runtimeDisplayName(fromIdentifier identifier: String) -> String {
        let tail = identifier.components(separatedBy: ".SimRuntime.").last ?? identifier
        let parts = tail.components(separatedBy: "-")
        guard let os = parts.first, parts.count > 1 else { return tail }
        return os + " " + parts.dropFirst().joined(separator: ".")
    }

    // MARK: - AX scoping

    /// Simulator titles each device window `"<device name> – <runtime>"` using a
    /// U+2013 EN DASH (verified, not assumed — an ASCII hyphen will not match).
    /// The other dashes are accepted so a cosmetic change upstream degrades to a
    /// still-working match rather than a hard failure.
    static func deviceName(fromWindowTitle title: String) -> String {
        for separator in [" \u{2013} ", " \u{2014} ", " - "] {
            if let range = title.range(of: separator) {
                return String(title[title.startIndex..<range.lowerBound])
            }
        }
        return title
    }

    /// The `iOSContentGroup` for a device's window — the root every scoped query
    /// should walk from.
    static func contentGroup(for device: SimulatorDevice, in app: AXElement) throws -> AXElement {
        let windows = app.windows

        // Exact device-name match first; prefix match second, so a device named
        // "iPhone 17" can never swallow "iPhone 17 Pro"'s window.
        let window = windows.first { win in
            guard let title = win.title else { return false }
            return deviceName(fromWindowTitle: title) == device.name
        } ?? windows.first { ($0.title ?? "").hasPrefix(device.name) }

        guard let window else {
            throw SimulatorError.noWindow(device, titles: windows.compactMap { $0.title })
        }
        guard let group = findContentGroup(under: window, depth: 0, maxDepth: 3) else {
            throw SimulatorError.noContentGroup(device)
        }
        return group
    }

    /// The content group is a direct child of the window today. The bounded
    /// descent is insurance against Apple nesting it later — cheap, and it fails
    /// fast instead of walking the whole tree.
    private static func findContentGroup(under element: AXElement, depth: Int, maxDepth: Int) -> AXElement? {
        for child in element.children {
            if child.subrole == contentGroupSubrole { return child }
        }
        guard depth < maxDepth else { return nil }
        for child in element.children {
            if let found = findContentGroup(under: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    // MARK: - simctl plumbing

    private static func runSimctl(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw SimulatorError.simctlUnavailable(error.localizedDescription)
        }

        // Drain stderr on another queue: blocking on stdout while the child fills
        // the stderr pipe buffer would deadlock. Small output today, but a hang is
        // an expensive bug to find later.
        let errQueue = DispatchQueue(label: "swiftplay.simctl.stderr")
        let group = DispatchGroup()
        var errData = Data()
        errQueue.async(group: group) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorError.simctlFailed(message.isEmpty ? "exit status \(process.terminationStatus)" : message)
        }
        return outData
    }

    // Shapes of `simctl list devices -j`. Only the fields we use are decoded.
    private struct SimctlDeviceList: Decodable {
        let devices: [String: [Entry]]

        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
        }
    }
}

/// A booted iOS Simulator device, as reported by `xcrun simctl`.
struct SimulatorDevice {
    let udid: String
    let name: String
    let state: String
    /// Human-readable runtime, e.g. `"iOS 26.1"`.
    let runtime: String

    var displayName: String { "\(name) — \(runtime)" }
}

enum SimulatorError: LocalizedError {
    case simctlUnavailable(String)
    case simctlFailed(String)
    case noBootedDevices
    case deviceNotFound(selector: String, available: [SimulatorDevice])
    case ambiguousDevice([SimulatorDevice])
    case simulatorNotRunning
    case noWindow(SimulatorDevice, titles: [String])
    case noContentGroup(SimulatorDevice)

    var errorDescription: String? {
        switch self {
        case .simctlUnavailable(let detail):
            return "Could not run `xcrun simctl` (\(detail)). Install Xcode and its command-line tools."
        case .simctlFailed(let detail):
            return "`xcrun simctl` failed: \(detail)"
        case .noBootedDevices:
            return """
            No booted Simulator devices.
            Boot one with: xcrun simctl boot "iPhone 17 Pro" && open -a Simulator
            """
        case .deviceNotFound(let selector, let available):
            return "No booted device matches '\(selector)'.\n" + Self.deviceList(available)
        case .ambiguousDevice(let devices):
            return "More than one booted device matches. Disambiguate with --device <name-or-udid>.\n"
                + Self.deviceList(devices)
        case .simulatorNotRunning:
            return """
            Simulator.app is not running, so there is no accessibility tree to read.
            A device booted with `simctl boot` alone renders nothing — open the UI with: open -a Simulator
            """
        case .noWindow(let device, let titles):
            let seen = titles.isEmpty ? "(none)" : titles.map { "  - \($0)" }.joined(separator: "\n")
            return """
            Simulator is running but has no window for \(device.displayName).
            The device may be booted headlessly, or its window closed. Windows currently open:
            \(seen)
            """
        case .noContentGroup(let device):
            return """
            Found \(device.displayName)'s window but no '\(Simulator.contentGroupSubrole)' element inside it.
            The simulated app may still be launching, or the window may be showing no app at all.
            """
        }
    }

    private static func deviceList(_ devices: [SimulatorDevice]) -> String {
        guard !devices.isEmpty else { return "No booted devices." }
        return "Booted devices:\n" + devices.map { "  - \($0.name)  [\($0.runtime)]  \($0.udid)" }.joined(separator: "\n")
    }
}
