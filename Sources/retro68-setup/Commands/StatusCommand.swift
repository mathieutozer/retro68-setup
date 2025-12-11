import ArgumentParser
import Foundation
import Noora

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the current Retro68 installation status"
    )

    func run() async throws {
        let noora = Noora()
        let status = await InstallationStatus.current()

        print("")
        print("Retro68 Toolchain Status")
        print("========================")
        print("")

        if status.isInstalled {
            noora.success("Retro68 is installed: \(status.statusDescription)")
        } else {
            noora.warning("Retro68 is not installed. Run 'retro68-setup install' to begin.")
            return
        }

        print("")
        print("Configuration:")
        print("--------------")
        print("  Install path:    \(Paths.retro68Root.path)")
        print("  Repository:      \(status.repositoryCloned ? "Cloned" : "Not cloned")")
        print("  Toolchain:       \(status.toolchainBuilt ? "Built" : "Not built")")
        print("  Build targets:   \(status.targetDescription)")
        print("")

        if let interface = status.activeInterface {
            print("Active Interfaces:")
            print("------------------")
            print("  Type:    \(interface.type == .multiversal ? "Multiversal (Open Source)" : "Apple Universal Interfaces")")
            if let version = interface.version {
                print("  Version: \(version)")
            }
            print("  Path:    \(interface.path.path)")
        }

        print("")

        if let toolchainPath = status.toolchainPath {
            print("Toolchain Binaries:")
            print("-------------------")
            print("  \(toolchainPath.appendingPathComponent("bin").path)")
            print("")
            print("To use with CMake, specify the toolchain file:")

            for target in status.buildTargets {
                print("  \(target.displayName):")
                print("    -DCMAKE_TOOLCHAIN_FILE=\(Paths.toolchainFile(for: target).path)")
            }
        }

        print("")
    }
}
