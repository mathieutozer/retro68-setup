import ArgumentParser
import Foundation
import Noora

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the Retro68 toolchain installation"
    )

    @Flag(name: .long, help: "Keep downloaded Apple Universal Interfaces")
    var keepInterfaces: Bool = false

    @Flag(name: .long, help: "Skip confirmation prompt")
    var force: Bool = false

    func run() async throws {
        let noora = Noora()

        print("")
        print("Retro68 Uninstaller")
        print("===================")
        print("")

        let config = Configuration.load()

        if !config.isInstalled && !Paths.exists(Paths.retro68Root) {
            noora.warning("Retro68 does not appear to be installed.")
            return
        }

        // Calculate size
        let size = calculateDirectorySize(Paths.retro68Root)
        let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

        print("Installation location: \(Paths.retro68Root.path)")
        print("Size: \(sizeStr)")
        print("")

        if keepInterfaces {
            print("Apple Universal Interfaces will be preserved.")
            print("")
        }

        if !force {
            let confirm = noora.yesOrNoChoicePrompt(
                title: "Confirm Uninstall",
                question: "Are you sure you want to remove the Retro68 installation?",
                defaultAnswer: false,
                description: "This will delete \(sizeStr) from \(Paths.retro68Root.path)"
            )

            if !confirm {
                print("Uninstall cancelled.")
                return
            }
        }

        print("")
        print("Removing Retro68...")

        do {
            if keepInterfaces {
                // Remove everything except the interfaces directory
                try await removeExceptInterfaces()
            } else {
                try Paths.remove(Paths.retro68Root)
            }

            noora.success("Retro68 has been removed from your system.")

            if keepInterfaces && Paths.exists(Paths.interfacesDir) {
                print("")
                print("Apple Universal Interfaces preserved at:")
                print("  \(Paths.interfacesDir.path)")
            }

        } catch {
            noora.error("Failed to remove installation: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("")
    }

    private func removeExceptInterfaces() async throws {
        let fm = FileManager.default

        // Get all items in retro68Root
        let contents = try fm.contentsOfDirectory(
            at: Paths.retro68Root,
            includingPropertiesForKeys: nil
        )

        for item in contents {
            if item.lastPathComponent == "interfaces" {
                continue
            }
            try fm.removeItem(at: item)
        }
    }

    private func calculateDirectorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var size: Int64 = 0

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            size += Int64(fileSize)
        }

        return size
    }
}
