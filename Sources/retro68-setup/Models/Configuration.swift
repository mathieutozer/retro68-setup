import Foundation

struct Configuration: Codable {
    var installedAt: Date?
    var buildTargets: [BuildTarget]
    var activeInterfaceVersion: String?
    var interfaceType: InterfaceType

    enum InterfaceType: String, Codable {
        case multiversal
        case apple
    }

    static let `default` = Configuration(
        installedAt: nil,
        buildTargets: [],
        activeInterfaceVersion: nil,
        interfaceType: .multiversal
    )

    static func load() -> Configuration {
        guard Paths.exists(Paths.configFile),
              let data = try? Data(contentsOf: Paths.configFile),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return .default
        }
        return config
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try Paths.ensureDirectoryExists(Paths.retro68Root)
        try data.write(to: Paths.configFile)
    }

    var isInstalled: Bool {
        installedAt != nil && Paths.exists(Paths.toolchainDir)
    }
}
