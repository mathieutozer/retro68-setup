import ArgumentParser

@main
struct Retro68Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retro68-setup",
        abstract: "A tool for installing and managing the Retro68 toolchain for classic Mac development.",
        version: "1.0.0",
        subcommands: [
            InstallCommand.self,
            UninstallCommand.self,
            InterfacesCommand.self,
            BuildCommand.self,
            StatusCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}
