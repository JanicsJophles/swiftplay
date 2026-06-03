import ArgumentParser

@main
struct Swiftplay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftplay",
        abstract: "Playwright-style end-to-end testing for native macOS apps.",
        version: "0.1.0",
        subcommands: [
            LaunchCommand.self,
            TreeCommand.self,
            InspectCommand.self,
            FindCommand.self,
            TypeCommand.self,
            PressCommand.self,
            ClickCommand.self,
            ScreenshotCommand.self,
            HoldDisplayCommand.self,
            ConfigCommand.self,
            TestCommand.self,
            MCPCommand.self,
        ]
    )
}
