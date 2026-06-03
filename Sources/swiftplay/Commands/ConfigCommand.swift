import ArgumentParser
import Foundation
import SwiftplayCore

/// `swiftplay config` — git-style get/set/list over `~/.swiftplay/config.json`.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View and change swiftplay defaults (the control center).",
        subcommands: [Get.self, Set.self, List.self, Path.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print every setting and its value.")
        func run() {
            let config = ConfigStore.load()
            let width = Config.Key.allCases.map(\.rawValue.count).max() ?? 0
            for pair in config.pairs {
                let value = pair.value.isEmpty ? "(unset)" : pair.value
                let key = pair.key.padding(toLength: width, withPad: " ", startingAt: 0)
                print("\(key)  = \(value)")
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one setting's value.")
        @Argument(help: "Dotted key, e.g. offscreen.mode.") var key: String
        func run() throws {
            guard let parsed = Config.Key(rawValue: key) else { throw fail(ConfigError.unknownKey(key)) }
            print(ConfigStore.load().get(parsed))
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one setting; pass no value to reset it.")
        @Argument(help: "Dotted key, e.g. offscreen.retina.") var key: String
        @Argument(help: "New value. Omit to reset to default.") var value: String?
        func run() throws {
            guard let parsed = Config.Key(rawValue: key) else { throw fail(ConfigError.unknownKey(key)) }
            var config = ConfigStore.load()
            do {
                try config.set(parsed, value ?? "")
            } catch let error as ConfigError {
                throw fail(error)
            }
            do {
                try ConfigStore.save(config)
            } catch {
                throw fail("Could not write \(ConfigStore.url.path): \(error.localizedDescription)")
            }
            let now = config.get(parsed)
            print("\(key) = \(now.isEmpty ? "(unset)" : now)")
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the config file path.")
        func run() { print(ConfigStore.url.path) }
    }
}

/// Write a message to stderr and return an ExitCode to throw.
private func fail(_ message: CustomStringConvertible) -> ExitCode {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    return ExitCode(1)
}
