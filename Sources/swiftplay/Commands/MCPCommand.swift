import AppKit
import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation

/// `swiftplay mcp` — expose swiftplay as a Model Context Protocol server so an
/// agent (Claude, etc.) can drive native macOS apps: read the AX tree, find
/// elements, click, type, press keys, launch.
///
/// This is a minimal, dependency-free stdio MCP server. Transport is JSON-RPC
/// 2.0 over stdin/stdout, newline-delimited (one message per line, no embedded
/// newlines on the wire — JSON escapes them). Logs go to stderr so they never
/// corrupt the protocol stream. Tools dispatch straight to the same primitives
/// the CLI subcommands use (`Query`, `Keyboard`, `Mouse`, `AXElement`).
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run swiftplay as a stdio MCP server so an agent can drive native macOS apps."
    )

    func run() throws {
        MCPServer().serve()
    }
}

// MARK: - Server

private struct MCPServer {
    let serverName = "swiftplay"
    let serverVersion = "0.0.0"
    /// Protocol version we'll fall back to if the client doesn't name one.
    let defaultProtocolVersion = "2024-11-05"

    func log(_ message: String) {
        FileHandle.standardError.write(Data("[swiftplay-mcp] \(message)\n".utf8))
    }

    func serve() {
        log("listening on stdio")
        // Newline-delimited JSON-RPC. readLine() pulls one message per line.
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            handle(trimmed)
        }
        log("stdin closed, exiting")
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            send(error: nil, code: -32700, message: "Parse error")
            return
        }

        let method = msg["method"] as? String ?? ""
        // Notifications have no "id" and expect no response.
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let clientVersion = params["protocolVersion"] as? String ?? defaultProtocolVersion
            send(result: [
                "protocolVersion": clientVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": serverVersion],
            ], id: id)

        case "notifications/initialized", "notifications/cancelled":
            break // notifications: no reply

        case "ping":
            send(result: [String: Any](), id: id)

        case "tools/list":
            send(result: ["tools": Tools.all], id: id)

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let outcome = Tools.call(name: name, args: args)
            send(result: [
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError,
            ], id: id)

        default:
            if id != nil {
                send(error: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: wire

    private func send(result: [String: Any], id: Any?) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "result": result]
        envelope["id"] = id ?? NSNull()
        write(envelope)
    }

    private func send(error id: Any?, code: Int, message: String) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        envelope["id"] = id ?? NSNull()
        write(envelope)
    }

    private func write(_ envelope: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            log("failed to encode response")
            return
        }
        // JSONSerialization produces single-line JSON; append the delimiter.
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// MARK: - Tools

private enum Tools {
    /// Tool definitions advertised via `tools/list`. inputSchema is JSON Schema.
    static let all: [[String: Any]] = [
        [
            "name": "swiftplay_launch",
            "description": "Launch a macOS app. By default it starts hidden + in the background (never appears on screen, doesn't steal focus) so the agent can drive it headless. Set show=true to bring it to the foreground (needed for mouse clicks and menu key-equivalents).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleId": ["type": "string", "description": "Bundle id, e.g. ai.rackmind.macos."],
                    "path": ["type": "string", "description": "Path to the .app bundle. Use bundleId OR path."],
                    "show": ["type": "boolean", "description": "Launch visible/foreground instead of hidden/background. Default false."],
                ],
            ],
        ],
        [
            "name": "swiftplay_tree",
            "description": "Dump the accessibility (AX) tree of a running app — the agent's equivalent of the DOM. Use this first to discover roles, identifiers, titles, and values of elements you can target.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleId": ["type": "string", "description": "Bundle id of a running app. Use bundleId OR pid."],
                    "pid": ["type": "integer", "description": "Process id of a running app."],
                    "maxDepth": ["type": "integer", "description": "Max tree depth. Default 25."],
                    "showGeometry": ["type": "boolean", "description": "Include position/size for each element. Default false."],
                ],
            ],
        ],
        [
            "name": "swiftplay_find",
            "description": "Find AX elements by role and/or a case-insensitive text substring (matched against value/title/description/identifier). Returns each match's role, identifier, text, and geometry. Doubles as an assertion: reports a count and whether anything matched.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleId": ["type": "string", "description": "Bundle id of a running app. Use bundleId OR pid."],
                    "pid": ["type": "integer", "description": "Process id of a running app."],
                    "role": ["type": "string", "description": "AX role substring, e.g. AXButton, AXStaticText."],
                    "text": ["type": "string", "description": "Case-insensitive substring to match."],
                    "maxDepth": ["type": "integer", "description": "Max tree depth. Default 40."],
                ],
            ],
        ],
        [
            "name": "swiftplay_click",
            "description": "Click the first element matching role/text. By default uses the element's AX press action (works in the background, no focus steal). Set mouse=true to synthesize a real mouse click at the element's center (requires the app to be foreground — launch with show=true).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleId": ["type": "string", "description": "Bundle id of a running app. Use bundleId OR pid."],
                    "pid": ["type": "integer", "description": "Process id of a running app."],
                    "role": ["type": "string", "description": "AX role substring to match, e.g. AXButton."],
                    "text": ["type": "string", "description": "Case-insensitive substring to match."],
                    "mouse": ["type": "boolean", "description": "Use a synthesized mouse click instead of the AX press action. Default false (AX press)."],
                    "maxDepth": ["type": "integer", "description": "Max tree depth. Default 40."],
                ],
            ],
        ],
        [
            "name": "swiftplay_type",
            "description": "Type literal text into the focused element of an app. Delivered to the app via its pid without stealing focus, unless foreground=true.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to type."],
                    "bundleId": ["type": "string", "description": "Bundle id of the target app (optional; without it, goes to the frontmost app)."],
                    "foreground": ["type": "boolean", "description": "Bring the app to the front before typing. Default false."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "swiftplay_press",
            "description": "Press a key or chord: a named key (down/up/left/right/tab/return/escape/space/delete), a letter/digit, or a chord like cmd+k / cmd+shift+p. Menu key-equivalents (e.g. cmd+k) require foreground=true.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "Key or chord, e.g. 'down', 'tab', 'cmd+k'."],
                    "bundleId": ["type": "string", "description": "Bundle id of the target app (optional)."],
                    "repeat": ["type": "integer", "description": "Press this many times. Default 1."],
                    "foreground": ["type": "boolean", "description": "Bring the app to the front first (required for menu key-equivalents). Default false."],
                ],
                "required": ["key"],
            ],
        ],
    ]

    struct Outcome { let text: String; let isError: Bool }
    static func ok(_ text: String) -> Outcome { Outcome(text: text, isError: false) }
    static func fail(_ text: String) -> Outcome { Outcome(text: text, isError: true) }

    static func call(name: String, args: [String: Any]) -> Outcome {
        switch name {
        case "swiftplay_launch": return launch(args)
        case "swiftplay_tree": return tree(args)
        case "swiftplay_find": return find(args)
        case "swiftplay_click": return click(args)
        case "swiftplay_type": return type(args)
        case "swiftplay_press": return press(args)
        default: return fail("Unknown tool: \(name)")
        }
    }

    // MARK: helpers

    /// Gate AX-dependent tools. Returns an error message if not trusted, else nil.
    private static func requireAX() -> String? {
        AccessibilityPermission.isTrusted
            ? nil
            : "Accessibility permission is not granted. Enable the app running this MCP server (your terminal, or the host app) in System Settings → Privacy & Security → Accessibility, then retry."
    }

    private enum TargetResult { case ok(TargetApp); case err(String) }

    private static func resolveTarget(_ args: [String: Any]) -> TargetResult {
        if let bundleId = args["bundleId"] as? String, !bundleId.isEmpty {
            guard let t = TargetApp.find(bundleId: bundleId) else {
                return .err("No running app found with bundle id '\(bundleId)'. Launch it first with swiftplay_launch.")
            }
            return .ok(t)
        }
        if let pidAny = args["pid"], let pid = intValue(pidAny) {
            guard let t = TargetApp.find(pid: pid_t(pid)) else {
                return .err("No process with pid \(pid).")
            }
            return .ok(t)
        }
        return .err("Provide either bundleId or pid.")
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String { return s == "true" || s == "1" }
        return false
    }

    // MARK: tool impls

    private static func launch(_ args: [String: Any]) -> Outcome {
        let show = boolValue(args["show"])
        let appPath: String
        if let path = args["path"] as? String, !path.isEmpty {
            appPath = path
        } else if let bundleId = args["bundleId"] as? String, !bundleId.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                return fail("Could not resolve a path for bundle id '\(bundleId)'.")
            }
            appPath = url.path
        } else {
            return fail("Provide either bundleId or path.")
        }

        // `open -g` = don't foreground; `-j` = launch hidden. AX + postToPid still
        // reach a hidden app, so this drives fully headless.
        var openArgs: [String] = []
        if !show { openArgs += ["-g", "-j"] }
        openArgs.append(appPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = openArgs
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return fail("Failed to launch \(appPath): \(error.localizedDescription)")
        }
        guard proc.terminationStatus == 0 else {
            return fail("`open` failed for \(appPath) (status \(proc.terminationStatus)).")
        }
        return ok("Launched \(appPath) (\(show ? "visible" : "hidden/background")).")
    }

    private static func tree(_ args: [String: Any]) -> Outcome {
        if let err = requireAX() { return fail(err) }
        let target: TargetApp
        switch resolveTarget(args) {
        case .ok(let t): target = t
        case .err(let m): return fail(m)
        }
        let maxDepth = intValue(args["maxDepth"]) ?? 25
        let showGeometry = boolValue(args["showGeometry"])

        var out = "# \(target.localizedName ?? "?") (\(target.bundleId ?? "?"), pid \(target.pid))\n"
        let app = AXElement.application(pid: target.pid)
        out += treeString(app, depth: 0, maxDepth: maxDepth, prefix: "", isLast: true, showGeometry: showGeometry)
        return ok(out)
    }

    private static func find(_ args: [String: Any]) -> Outcome {
        if let err = requireAX() { return fail(err) }
        let target: TargetApp
        switch resolveTarget(args) {
        case .ok(let t): target = t
        case .err(let m): return fail(m)
        }
        let role = args["role"] as? String
        let text = args["text"] as? String
        let maxDepth = intValue(args["maxDepth"]) ?? 40

        let app = AXElement.application(pid: target.pid)
        let matches = Query.find(in: app, role: role, text: text, maxDepth: maxDepth)
        if matches.isEmpty {
            return ok("0 matches.")
        }
        var lines = ["\(matches.count) match(es):"]
        for m in matches {
            var parts = [m.role]
            if let id = m.identifier, !id.isEmpty { parts.append("#\(id)") }
            if !m.text.isEmpty { parts.append("\"\(m.text)\"") }
            if let p = m.position, let s = m.size {
                parts.append(String(format: "@(%.0f,%.0f %.0fx%.0f)", p.x, p.y, s.width, s.height))
            }
            lines.append(parts.joined(separator: " "))
        }
        return ok(lines.joined(separator: "\n"))
    }

    private static func click(_ args: [String: Any]) -> Outcome {
        if let err = requireAX() { return fail(err) }
        let target: TargetApp
        switch resolveTarget(args) {
        case .ok(let t): target = t
        case .err(let m): return fail(m)
        }
        let role = args["role"] as? String
        let text = args["text"] as? String
        let maxDepth = intValue(args["maxDepth"]) ?? 40
        let useMouse = boolValue(args["mouse"])

        // Mouse mode needs the target frontmost so the click hit-tests against it.
        if useMouse {
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateAllWindows])
            usleep(300_000)
        }

        let app = AXElement.application(pid: target.pid)
        let matches = Query.find(in: app, role: role, text: text, maxDepth: maxDepth)
        guard let first = matches.first else {
            return fail("No element matched role=\(role ?? "*") text=\(text ?? "*").")
        }

        if useMouse {
            guard let pos = first.position, let size = first.size else {
                return fail("Matched element has no geometry to click.")
            }
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            Mouse.click(at: center)
            return ok("Mouse-clicked \(first.role) \"\(first.text)\" @ (\(Int(center.x)),\(Int(center.y))).")
        } else {
            guard first.element.perform(kAXPressAction as String) else {
                return fail("Element \(first.role) \"\(first.text)\" does not support AXPress. Retry with mouse=true (app must be foreground).")
            }
            return ok("AX-pressed \(first.role) \"\(first.text)\".")
        }
    }

    private static func type(_ args: [String: Any]) -> Outcome {
        if let err = requireAX() { return fail(err) }
        guard let text = args["text"] as? String else {
            return fail("Missing required argument: text.")
        }
        let foreground = boolValue(args["foreground"])
        var targetPid: pid_t?
        if let bundleId = args["bundleId"] as? String, !bundleId.isEmpty {
            guard let t = TargetApp.find(bundleId: bundleId) else {
                return fail("No running app with bundle id '\(bundleId)'.")
            }
            targetPid = t.pid
            if foreground {
                Keyboard.activate(bundleId: bundleId)
                usleep(400_000)
            }
        }
        Keyboard.type(text, toPid: targetPid)
        return ok("Typed \(text.count) character(s).")
    }

    private static func press(_ args: [String: Any]) -> Outcome {
        if let err = requireAX() { return fail(err) }
        guard let key = args["key"] as? String, !key.isEmpty else {
            return fail("Missing required argument: key.")
        }
        guard Keyboard.parseChord(key) != nil else {
            return fail("Could not parse key/chord '\(key)'. Use a named key, a letter/digit, or a chord like cmd+k.")
        }
        let foreground = boolValue(args["foreground"])
        let repeatCount = max(1, intValue(args["repeat"]) ?? 1)
        var targetPid: pid_t?
        if let bundleId = args["bundleId"] as? String, !bundleId.isEmpty {
            guard let t = TargetApp.find(bundleId: bundleId) else {
                return fail("No running app with bundle id '\(bundleId)'.")
            }
            targetPid = t.pid
            if foreground {
                Keyboard.activate(bundleId: bundleId)
                usleep(400_000)
            }
        }
        // Foreground → global HID tap so menu key-equivalents route through
        // NSApplication. Background → postToPid (reaches the focused field).
        let postPid: pid_t? = foreground ? nil : targetPid
        for i in 0 ..< repeatCount {
            Keyboard.press(key, toPid: postPid)
            if i < repeatCount - 1 { usleep(120_000) }
        }
        return ok("Pressed '\(key)'\(repeatCount > 1 ? " ×\(repeatCount)" : "").")
    }
}

// MARK: - Tree serialization (string form of TreeCommand's printer)

private func treeString(
    _ elem: AXElement,
    depth: Int,
    maxDepth: Int,
    prefix: String,
    isLast: Bool,
    showGeometry: Bool
) -> String {
    let connector = depth == 0 ? "" : (isLast ? "└── " : "├── ")
    var out = prefix + connector + describeElement(elem, showGeometry: showGeometry) + "\n"
    if depth >= maxDepth { return out }

    let children = elem.children
    let nextPrefix = depth == 0 ? "" : prefix + (isLast ? "    " : "│   ")
    for (i, child) in children.enumerated() {
        out += treeString(
            child,
            depth: depth + 1,
            maxDepth: maxDepth,
            prefix: nextPrefix,
            isLast: i == children.count - 1,
            showGeometry: showGeometry
        )
    }
    return out
}

private func describeElement(_ elem: AXElement, showGeometry: Bool) -> String {
    var parts: [String] = [elem.role ?? "?"]
    if let sub = elem.subrole { parts.append("(\(sub))") }
    if let id = elem.identifier, !id.isEmpty { parts.append("#\(id)") }
    if let t = elem.title, !t.isEmpty { parts.append("title=\(clip(t))") }
    if let l = elem.label, !l.isEmpty { parts.append("desc=\(clip(l))") }
    if let v = elem.value, !v.isEmpty { parts.append("value=\(clip(v))") }
    if !elem.isEnabled { parts.append("[disabled]") }
    if showGeometry, let p = elem.position, let s = elem.size {
        parts.append(String(format: "@(%.0f,%.0f %.0fx%.0f)", p.x, p.y, s.width, s.height))
    }
    return parts.joined(separator: " ")
}

private func clip(_ s: String) -> String {
    let clipped = s.count > 60 ? String(s.prefix(57)) + "..." : s
    return "\"\(clipped.replacingOccurrences(of: "\"", with: "\\\""))\""
}
