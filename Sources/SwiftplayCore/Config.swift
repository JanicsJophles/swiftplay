import Foundation

/// User-configurable defaults, persisted at `~/.swiftplay/config.json`. This is
/// swiftplay's "control center": the single source of truth that the CLI reads,
/// the `config` command edits, and the menu-bar app edits too.
///
/// Lives in `SwiftplayCore` precisely so the CLI and the GUI share one schema —
/// no drift. Keys are addressed git-style with dotted paths (`offscreen.mode`).
/// Add a setting by: (1) a stored property, (2) a `Key` case, (3) a get/set branch.
public struct Config: Codable, Equatable {
    public var offscreen = Offscreen()
    public var defaults = Defaults()
    public var screenshot = Screenshot()

    public init() {}

    public struct Offscreen: Codable, Equatable {
        /// How `launch --offscreen` hides the window.
        public var mode: OffscreenMode = .virtual
        /// Attempt a 2× (retina) virtual display. Best-effort; falls back to 1×.
        public var retina: Bool = false
        public init() {}
    }

    public struct Defaults: Codable, Equatable {
        /// Bundle id used when a command is run without `-b`/`--pid`.
        public var bundleId: String? = nil
        public init() {}
    }

    public struct Screenshot: Codable, Equatable {
        /// Directory `screenshot` writes into when `-o` is a bare filename.
        public var dir: String = "."
        public init() {}
    }

    public enum OffscreenMode: String, Codable, CaseIterable {
        case virtual    // headless virtual display — truly invisible (default)
        case secondary  // park fully on a secondary physical display
        case corner     // tuck the unavoidable ~40px sliver into a corner
    }
}

// MARK: - Dotted-key access (powers `swiftplay config` and the menu-bar app)

extension Config {
    /// Every settable key with its current value, for `config list` and the GUI.
    public var pairs: [(key: String, value: String)] {
        Key.allCases.map { ($0.rawValue, get($0)) }
    }

    public enum Key: String, CaseIterable {
        case offscreenMode = "offscreen.mode"
        case offscreenRetina = "offscreen.retina"
        case defaultBundleId = "defaults.bundleId"
        case screenshotDir = "screenshot.dir"

        /// Human hint of accepted values.
        public var allowed: String {
            switch self {
            case .offscreenMode: return Config.OffscreenMode.allCases.map(\.rawValue).joined(separator: "|")
            case .offscreenRetina: return "true|false"
            case .defaultBundleId: return "<bundle id> | (unset)"
            case .screenshotDir: return "<path>"
            }
        }
    }

    public func get(_ key: Key) -> String {
        switch key {
        case .offscreenMode: return offscreen.mode.rawValue
        case .offscreenRetina: return String(offscreen.retina)
        case .defaultBundleId: return defaults.bundleId ?? ""
        case .screenshotDir: return screenshot.dir
        }
    }

    public mutating func set(_ key: Key, _ raw: String) throws {
        switch key {
        case .offscreenMode:
            guard let mode = OffscreenMode(rawValue: raw) else {
                throw ConfigError.badValue(key: key.rawValue, value: raw, allowed: key.allowed)
            }
            offscreen.mode = mode
        case .offscreenRetina:
            guard let flag = Bool(raw) else {
                throw ConfigError.badValue(key: key.rawValue, value: raw, allowed: key.allowed)
            }
            offscreen.retina = flag
        case .defaultBundleId:
            defaults.bundleId = raw.isEmpty ? nil : raw
        case .screenshotDir:
            screenshot.dir = raw
        }
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case unknownKey(String)
    case badValue(key: String, value: String, allowed: String)

    public var description: String {
        switch self {
        case .unknownKey(let k):
            let known = Config.Key.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unknown config key '\(k)'. Known keys: \(known)."
        case .badValue(let key, let value, let allowed):
            return "Invalid value '\(value)' for \(key). Expected: \(allowed)."
        }
    }
}

// MARK: - Persistence

public enum ConfigStore {
    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".swiftplay", isDirectory: true)
    }
    public static var url: URL { directory.appendingPathComponent("config.json") }

    /// Load config, returning defaults if the file is missing or unreadable.
    public static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return config
    }

    public static func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
