import ArgumentParser
import Foundation
import Noora

struct InterfacesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interfaces",
        abstract: "Manage Universal Interfaces for Retro68",
        subcommands: [
            ListInterfaces.self,
            UseInterface.self,
            AddInterface.self,
            RemoveInterface.self,
            InfoInterfaces.self,
        ],
        defaultSubcommand: ListInterfaces.self
    )
}

struct ListInterfaces: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available Universal Interfaces"
    )

    func run() async throws {
        let noora = Noora()
        let manager = InterfaceManager()

        print("")
        print("Universal Interfaces")
        print("====================")
        print("")

        let interfaces = await manager.getAvailableInterfaces()
        let active = await manager.getActiveInterface()

        if interfaces.isEmpty {
            noora.warning("No interfaces available. Install Retro68 first.")
            return
        }

        for interface in interfaces {
            let isActive = active?.path == interface.path
            let marker = isActive ? " [ACTIVE]" : ""

            print("  \(interface.displayName)\(marker)")
            print("    Type: \(interface.type == .multiversal ? "Open Source" : "Apple Proprietary")")
            print("    Path: \(interface.path.path)")
            print("")
        }

        print("Use 'retro68-setup interfaces use' to switch interfaces.")
        print("Use 'retro68-setup interfaces add' to add Apple Universal Interfaces.")
        print("")
    }
}

struct UseInterface: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Switch to a different Universal Interface version"
    )

    @Argument(help: "Interface version to use (e.g., '3.4' or 'multiversal')")
    var version: String?

    func run() async throws {
        let noora = Noora()
        let manager = InterfaceManager()

        let interfaces = await manager.getAvailableInterfaces()

        if interfaces.isEmpty {
            noora.error("No interfaces available. Install Retro68 first.")
            return
        }

        let selected: InterfaceVersion

        if let version = version {
            // Find by version string
            if version.lowercased() == "multiversal" {
                guard let multiversal = interfaces.first(where: { $0.type == .multiversal }) else {
                    noora.error("Multiversal interfaces not found.")
                    return
                }
                selected = multiversal
            } else {
                guard let found = interfaces.first(where: { $0.version == version }) else {
                    noora.error("Interface version '\(version)' not found.")
                    return
                }
                selected = found
            }
        } else {
            // Interactive selection
            print("")
            print("Select Universal Interface")
            print("==========================")
            print("")

            struct InterfaceOption: CustomStringConvertible, Equatable {
                let interface: InterfaceVersion
                var description: String { interface.displayName }
            }

            let options = interfaces.map { InterfaceOption(interface: $0) }

            let choice = noora.singleChoicePrompt(
                title: "Interface",
                question: "Which interface version do you want to use?",
                options: options,
                description: "Select the Universal Interface version for your builds."
            )

            selected = choice.interface
        }

        do {
            try manager.setActiveInterface(selected)
            print("")
            noora.success("Now using \(selected.displayName)")
        } catch {
            noora.error("Could not set interface: \(error.localizedDescription)")
        }

        print("")
    }
}

struct AddInterface: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add Apple Universal Interfaces"
    )

    @Option(name: .long, help: "Path to InterfacesAndLibraries folder")
    var path: String?

    @Option(name: .long, help: "Version label (e.g., '3.4')")
    var version: String?

    func run() async throws {
        let noora = Noora()
        let manager = InterfaceManager()

        print("")
        print("Add Apple Universal Interfaces")
        print("==============================")
        print("")

        if path == nil {
            // Show instructions
            print(InterfaceManager.appleInterfacesInfo)
            print("")

            let ready = noora.yesOrNoChoicePrompt(
                title: "Ready",
                question: "Do you have the InterfacesAndLibraries folder extracted and ready?",
                defaultAnswer: false,
                description: "You'll need to provide the path to the extracted folder."
            )

            if !ready {
                print("")
                print("When you have the files ready, run:")
                print("  retro68-setup interfaces add --path /path/to/InterfacesAndLibraries --version 3.4")
                print("")
                return
            }
        }

        // Get path
        let sourcePath: URL
        if let providedPath = path {
            sourcePath = URL(fileURLWithPath: providedPath)
        } else {
            let inputPath = noora.textPrompt(
                title: "Path",
                prompt: "Enter the path to the InterfacesAndLibraries folder:",
                description: "This should be the extracted folder containing the interface headers."
            )
            sourcePath = URL(fileURLWithPath: inputPath)
        }

        // Validate path exists
        guard Paths.exists(sourcePath) else {
            noora.error("The specified path does not exist: \(sourcePath.path)")
            return
        }

        // Get version
        let versionStr: String
        if let providedVersion = version {
            versionStr = providedVersion
        } else {
            versionStr = noora.textPrompt(
                title: "Version",
                prompt: "Enter the version label (e.g., '3.4'):",
                description: "This helps identify the interface version."
            )
        }

        print("")
        print("Installing Apple Universal Interfaces \(versionStr)...")

        do {
            try await manager.addAppleInterfaces(from: sourcePath, version: versionStr)

            noora.success("Apple Universal Interfaces \(versionStr) installed successfully.")

            print("")
            let useNow = noora.yesOrNoChoicePrompt(
                title: "Activate",
                question: "Would you like to switch to these interfaces now?",
                defaultAnswer: true,
                description: "You can also switch later with 'retro68-setup interfaces use'."
            )

            if useNow {
                let interfaces = await manager.getAvailableInterfaces()
                if let newInterface = interfaces.first(where: { $0.version == versionStr }) {
                    try manager.setActiveInterface(newInterface)
                    noora.success("Now using Apple Universal Interfaces \(versionStr)")
                }
            }

        } catch {
            noora.error("Failed to install interfaces: \(error.localizedDescription)")
        }

        print("")
    }
}

struct RemoveInterface: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an installed interface version"
    )

    @Argument(help: "Interface version to remove")
    var version: String?

    func run() async throws {
        let noora = Noora()
        let manager = InterfaceManager()

        let interfaces = await manager.getAvailableInterfaces()
        let appleInterfaces = interfaces.filter { $0.type == .apple }

        if appleInterfaces.isEmpty {
            noora.warning("No Apple Universal Interfaces are installed.")
            return
        }

        let toRemove: InterfaceVersion

        if let version = version {
            guard let found = appleInterfaces.first(where: { $0.version == version }) else {
                noora.error("Interface version '\(version)' not found.")
                return
            }
            toRemove = found
        } else {
            print("")

            struct InterfaceOption: CustomStringConvertible, Equatable {
                let interface: InterfaceVersion
                var description: String { interface.displayName }
            }

            let options = appleInterfaces.map { InterfaceOption(interface: $0) }

            let choice = noora.singleChoicePrompt(
                title: "Remove Interface",
                question: "Which interface version do you want to remove?",
                options: options,
                description: "Note: You cannot remove the Multiversal interfaces."
            )

            toRemove = choice.interface
        }

        let confirm = noora.yesOrNoChoicePrompt(
            title: "Confirm",
            question: "Remove \(toRemove.displayName)?",
            defaultAnswer: false,
            description: "This cannot be undone."
        )

        if !confirm {
            print("Cancelled.")
            return
        }

        do {
            try manager.removeInterface(toRemove)
            noora.success("\(toRemove.displayName) has been removed.")
        } catch {
            noora.error("Could not remove interface: \(error.localizedDescription)")
        }

        print("")
    }
}

struct InfoInterfaces: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show detailed information about Universal Interfaces"
    )

    func run() async throws {
        print("")
        print(InterfaceManager.multiversalInfo)
        print("")
        print(InterfaceManager.appleInterfacesInfo)
        print("")
    }
}
