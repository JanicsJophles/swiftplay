import AppKit
import SwiftplayCore

/// swiftplay's menu-bar "control center". A lightweight `NSStatusItem` agent
/// (no Dock icon) that reads and writes the SAME `~/.swiftplay/config.json` the
/// CLI uses — so toggling a setting here changes what `swiftplay launch` does.
/// It also shows whether a headless session is live and can stop it.
///
/// Deliberately an `NSMenu`, not a fancy popover: a menu is the most robust,
/// least-surprising macOS control surface, and rebuilds from config every time
/// it opens so it always reflects the current state (including edits made via
/// the CLI).
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func install() {
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "swiftplay") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "sp"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild(menu)
    }

    // Rebuild on every open so CLI-side edits and live session state are reflected.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = ConfigStore.load()
        let sessionLive = isHolderRunning()

        menu.addItem(disabled(sessionLive ? "● Headless session running" : "○ Idle"))
        menu.addItem(.separator())

        // Offscreen mode submenu.
        let modeItem = NSMenuItem(title: "Offscreen Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in Config.OffscreenMode.allCases {
            let item = NSMenuItem(title: label(for: mode), action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (config.offscreen.mode == mode) ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Retina toggle.
        let retina = NSMenuItem(title: "Retina (2×) virtual display", action: #selector(toggleRetina), keyEquivalent: "")
        retina.target = self
        retina.state = config.offscreen.retina ? .on : .off
        menu.addItem(retina)
        menu.addItem(.separator())

        menu.addItem(disabled("Default app:  \(config.defaults.bundleId ?? "—")"))
        menu.addItem(disabled("Screenshots:  \(config.screenshot.dir)"))
        menu.addItem(.separator())

        let edit = NSMenuItem(title: "Edit config.json…", action: #selector(editConfig), keyEquivalent: ",")
        edit.target = self
        menu.addItem(edit)

        if sessionLive {
            let stop = NSMenuItem(title: "Stop headless session", action: #selector(stopSession), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit swiftplay control center", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func label(for mode: Config.OffscreenMode) -> String {
        switch mode {
        case .virtual: return "Virtual display (invisible)"
        case .secondary: return "Secondary physical display"
        case .corner: return "Corner sliver (last resort)"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        mutate { try $0.set(.offscreenMode, raw) }
    }

    @objc private func toggleRetina() {
        mutate { try $0.set(.offscreenRetina, ConfigStore.load().offscreen.retina ? "false" : "true") }
    }

    @objc private func editConfig() {
        if !FileManager.default.fileExists(atPath: ConfigStore.url.path) {
            try? ConfigStore.save(ConfigStore.load())  // materialize defaults so there's something to edit
        }
        NSWorkspace.shared.open(ConfigStore.url)
    }

    @objc private func stopSession() { _ = runTool("/usr/bin/pkill", ["-f", "hold-display --bundle"]) }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Helpers

    private func mutate(_ change: (inout Config) throws -> Void) {
        var config = ConfigStore.load()
        do {
            try change(&config)
            try ConfigStore.save(config)
        } catch {
            NSLog("swiftplay-menubar: config update failed: \(error)")
        }
    }

    /// A `swiftplay hold-display` process means a headless session is live.
    private func isHolderRunning() -> Bool {
        runTool("/usr/bin/pgrep", ["-f", "hold-display --bundle"]) == 0
    }

    @discardableResult
    private func runTool(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)  // menu-bar agent: no Dock icon, no app menu
let controller = MenuController()
controller.install()
application.run()
