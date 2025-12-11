import Foundation

struct InstallationStatus {
    let isInstalled: Bool
    let repositoryCloned: Bool
    let toolchainBuilt: Bool
    let buildTargets: [BuildTarget]
    let activeInterface: InterfaceVersion?
    let installedAt: Date?
    let toolchainPath: URL?

    static func current() async -> InstallationStatus {
        let config = Configuration.load()
        let builder = ToolchainBuilder()
        let interfaceManager = InterfaceManager()

        let repoCloned = builder.isRepositoryCloned()
        let toolchainBuilt = builder.isToolchainBuilt()
        let activeInterface = await interfaceManager.getActiveInterface()

        return InstallationStatus(
            isInstalled: config.isInstalled,
            repositoryCloned: repoCloned,
            toolchainBuilt: toolchainBuilt,
            buildTargets: config.buildTargets,
            activeInterface: activeInterface,
            installedAt: config.installedAt,
            toolchainPath: toolchainBuilt ? Paths.toolchainDir : nil
        )
    }

    var statusDescription: String {
        if !isInstalled {
            return "Not installed"
        }

        var parts: [String] = ["Installed"]

        if let date = installedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append("on \(formatter.string(from: date))")
        }

        return parts.joined(separator: " ")
    }

    var targetDescription: String {
        if buildTargets.isEmpty {
            return "None"
        }
        return buildTargets.map(\.displayName).joined(separator: ", ")
    }
}
