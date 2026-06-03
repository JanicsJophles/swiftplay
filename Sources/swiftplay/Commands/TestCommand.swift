import ArgumentParser
import Foundation

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run swiftplay test scripts and report pass/fail. A test is an executable script that exits 0 on success."
    )

    @Argument(help: "Specific test scripts to run. If omitted, discovers *.sh in --dir.")
    var scripts: [String] = []

    @Option(name: .long, help: "Directory to discover *.sh test scripts in (used when no scripts are given).")
    var dir: String?

    @Flag(name: [.long, .customShort("v")], help: "Always print each script's output (default: only on failure).")
    var verbose: Bool = false

    func run() throws {
        let files = try resolveScripts()
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("No test scripts found. Pass script paths or --dir <dir>.\n".utf8))
            throw ExitCode(1)
        }

        // Serial on purpose: these scripts drive a single GUI app instance and
        // seed shared state (servers.json) — running them concurrently collides.
        var passed = 0
        var failures: [(name: String, code: Int32, output: String)] = []
        print("swiftplay test — \(files.count) script\(files.count == 1 ? "" : "s")")
        print(String(repeating: "─", count: 40))

        for file in files {
            let name = (file as NSString).lastPathComponent
            let start = Date()
            let (code, output) = runScript(file)
            let secs = String(format: "%.1fs", Date().timeIntervalSince(start))
            if code == 0 {
                print("  ✓ \(name)  (\(secs))")
                passed += 1
                if verbose, !output.isEmpty { printIndented(output) }
            } else {
                print("  ✗ \(name)  (\(secs), exit \(code))")
                failures.append((name, code, output))
                if !verbose { printIndented(output) } // always surface failing output
            }
        }

        print(String(repeating: "─", count: 40))
        print("\(passed)/\(files.count) passed" + (failures.isEmpty ? "" : ", \(failures.count) failed"))
        if !failures.isEmpty {
            FileHandle.standardError.write(Data("Failed: \(failures.map(\.name).joined(separator: ", "))\n".utf8))
            throw ExitCode(1)
        }
    }

    private func resolveScripts() throws -> [String] {
        if !scripts.isEmpty {
            return scripts.map { ($0 as NSString).expandingTildeInPath }
        }
        guard let dir else { return [] }
        let root = (dir as NSString).expandingTildeInPath
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries
            .filter { $0.hasSuffix(".sh") }
            .sorted()
            .map { (root as NSString).appendingPathComponent($0) }
    }

    private func runScript(_ path: String) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        var data = Data()
        // Drain on a background queue so a chatty script can't deadlock the pipe.
        let handle = pipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = handle.readDataToEndOfFile()
            group.leave()
        }
        do {
            try proc.run()
        } catch {
            return (127, "failed to launch \(path): \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        group.wait()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func printIndented(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            print("      \(line)")
        }
    }
}
