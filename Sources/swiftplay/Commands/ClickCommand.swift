import AppKit
import ArgumentParser
import Foundation

struct ClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Find the first element matching role/text and activate it (AX press by default).",
        discussion: """
        Headless by default. swiftplay activates the matched control through the \
        accessibility API (kAXPressAction), which is delivered straight to the \
        element: no pointer movement, no window raise, and the target never takes \
        focus away from whatever you are working in.

        If the matched element exposes no AX press action — a Metal/Canvas hit \
        area, a custom-drawn control — swiftplay falls back automatically to a \
        synthesized mouse click. That path does need the target frontmost for the \
        click to hit-test against it, so it briefly activates the app; afterwards \
        the pointer is warped back to where you left it and your previously \
        frontmost app is reactivated.

        BEHAVIOUR CHANGE (was: mouse click unless --ax): `click` is now AX-first. \
        Scripts that already pass `--ax` are unaffected — it still means "AX press \
        only, never touch the mouse". Scripts that relied on the mouse default keep \
        working via the automatic fallback, but elements that DO support AXPress are \
        now pressed rather than clicked. Pass `--mouse` to force the old behaviour.
        """
    )

    @Option(name: [.long, .customShort("b")], help: "Bundle identifier, e.g. ai.rackmind.macos.")
    var bundleId: String?

    @Option(name: .long, help: "Process ID. Use either --bundle-id or --pid.")
    var pid: Int32?

    @Option(name: .long, help: "Filter by AX role substring, e.g. AXStaticText, AXButton.")
    var role: String?

    @Option(name: [.long, .customShort("t")], help: "Case-insensitive substring matched against value/title/description/identifier.")
    var text: String?

    @Option(name: .long, help: "Maximum tree depth to search.")
    var maxDepth: Int = 40

    @Flag(name: .long, help: "AX press only: fail rather than falling back to a mouse click. (The default already tries AX press first.)")
    var ax: Bool = false

    @Flag(name: .long, help: "Force a synthesized mouse click, skipping AX press. For hit areas AX cannot express (Metal/Canvas). Briefly activates the target.")
    var mouse: Bool = false

    @Flag(name: .long, help: "After a mouse click, leave the target frontmost instead of restoring your previous app. Use when the click opens a menu or popover that a focus change would dismiss.")
    var keepFocus: Bool = false

    func validate() throws {
        guard !(ax && mouse) else {
            throw ValidationError("--ax and --mouse are mutually exclusive: --ax forbids the mouse fallback, --mouse skips the AX press.")
        }
    }

    func run() throws {
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.printGuidance()
            AccessibilityPermission.requestTrust()
            throw ExitCode(2)
        }

        let target = try TargetApp.resolve(bundleId: bundleId, pid: pid)

        // Note the ordering: the element is located BEFORE anything is activated.
        // Querying the AX tree costs no focus, so a run that ends up not needing
        // the mouse (the common case) never touches the user's screen at all —
        // and a run that fails to match fails without having stolen focus first.
        let app = AXElement.application(pid: target.pid)
        let matches = Query.find(in: app, role: role, text: text, maxDepth: maxDepth)
        guard let first = matches.first else {
            FileHandle.standardError.write(Data("No matching element.\n".utf8))
            throw ExitCode(1)
        }

        // A disabled control swallows both an AX press and a mouse click while
        // reporting success, which turns a failed step into a silent no-op and a
        // green run. `isEnabled` defaults to true when the attribute can't be
        // read, so an unreadable element is still attempted.
        //
        // Menu roles are deliberately exempt. AppKit only runs its menu-item
        // validation while a menu is being tracked, so items in a closed menu
        // report kAXEnabled=false even when they are perfectly usable — measured
        // on this machine, Brave reports Copy/Paste/Undo/Close Tab/Print… as
        // disabled with every menu shut, and 176 of its 338 menu items likewise.
        // Enforcing the check there would reject `click -t Copy` outright.
        if !first.role.hasPrefix("AXMenu"), !first.element.isEnabled {
            FileHandle.standardError.write(Data(
                "Matched \(first.role) \"\(first.text)\" is disabled — refusing to click it.\n".utf8))
            throw ExitCode(1)
        }

        if !mouse {
            if first.element.supportsPress {
                print("AX-pressing \(first.role) \"\(first.text)\"")
                if first.element.perform(kAXPressAction as String) { return }
                guard !ax else {
                    FileHandle.standardError.write(Data("AX press failed on \(first.role) \"\(first.text)\".\n".utf8))
                    throw ExitCode(1)
                }
                FileHandle.standardError.write(Data(
                    "AX press failed; falling back to a mouse click (this briefly activates the target).\n".utf8))
            } else {
                guard !ax else {
                    FileHandle.standardError.write(Data(
                        "\(first.role) \"\(first.text)\" exposes no AX press action. Drop --ax to allow the mouse fallback.\n".utf8))
                    throw ExitCode(1)
                }
                FileHandle.standardError.write(Data(
                    "\(first.role) \"\(first.text)\" exposes no AX press action; falling back to a mouse click (this briefly activates the target).\n".utf8))
            }
        }

        try mouseClick(first, target: target)
    }

    /// The synthetic-mouse fallback. Unlike an AX press this genuinely needs the
    /// target frontmost — the click is posted at the global HID tap and hit-tests
    /// against whatever window is topmost at that screen point, so clicking
    /// without activating would land in the user's own app. We therefore activate,
    /// click, and then undo both halves of the intrusion: the pointer goes back to
    /// where the user left it, and the app that was frontmost is reactivated.
    private func mouseClick(_ match: ElementMatch, target: TargetApp) throws {
        guard let pos = match.position, let size = match.size else {
            FileHandle.standardError.write(Data("Matched element has no geometry to click.\n".utf8))
            throw ExitCode(1)
        }
        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)

        let previousApp = NSWorkspace.shared.frontmostApplication
        let targetApp = NSRunningApplication(processIdentifier: target.pid)
        if targetApp?.isActive != true {
            // `[]` raises only the key window. `.activateAllWindows` (what this
            // used to pass) hoists every window of the target above the user's.
            targetApp?.activate(options: [])
            guard ClickCommand.waitUntilFrontmost(pid: target.pid, timeout: 1.5) else {
                FileHandle.standardError.write(Data(
                    "Could not bring the target to the front; refusing to post a mouse click that would land in another app.\n".utf8))
                throw ExitCode(1)
            }
        }

        print("clicking \(match.role) \"\(match.text)\" @ (\(Int(center.x)),\(Int(center.y)))")
        Mouse.clickRestoringCursor(at: center)

        if !keepFocus, let previousApp, previousApp.processIdentifier != target.pid {
            // Give the target a moment to finish handling the mouse-up before we
            // hand focus back; reactivating mid-dispatch can drop the event.
            usleep(80_000)
            previousApp.activate(options: [])
        }
    }

    /// Poll until `pid` is frontmost. Activation is asynchronous, and this is a
    /// plain CLI with no running runloop, so we spin one — `NSWorkspace`'s
    /// frontmost-app state does not update otherwise. Replaces a blind 300ms
    /// sleep that could either wait too long or proceed before the switch landed.
    static func waitUntilFrontmost(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
}
