import Foundation

enum EmulatorType: String, Codable, CaseIterable {
    case basilisk = "BasiliskII"
    case sheepshaver = "SheepShaver"

    var displayName: String {
        switch self {
        case .basilisk: return "BasiliskII (68K)"
        case .sheepshaver: return "SheepShaver (PowerPC)"
        }
    }

    var downloadPageURL: String {
        switch self {
        case .basilisk: return "https://www.emaculation.com/forum/viewtopic.php?t=7361"
        case .sheepshaver: return "https://www.emaculation.com/forum/viewtopic.php?t=7360"
        }
    }

    var directDownloadURL: String {
        switch self {
        case .basilisk: return "https://www.emaculation.com/basilisk/BasiliskII_universal_20250125.zip"
        case .sheepshaver: return "https://www.emaculation.com/sheepshaver/SheepShaver_universal_20250125.zip"
        }
    }

    var setupGuideURL: String {
        switch self {
        case .basilisk: return "https://www.emaculation.com/doku.php/basiliskii_osx_setup"
        case .sheepshaver: return "https://www.emaculation.com/doku.php/sheepshaver_mac_os_x_setup"
        }
    }

    var appName: String {
        switch self {
        case .basilisk: return "BasiliskII"
        case .sheepshaver: return "SheepShaver"
        }
    }

    var prefsPath: URL {
        switch self {
        case .basilisk: return Paths.basiliskPrefs
        case .sheepshaver: return Paths.sheepshaverPrefs
        }
    }

    var defaultRAM: Int {
        switch self {
        case .basilisk: return 64 * 1024 * 1024  // 64MB
        case .sheepshaver: return 128 * 1024 * 1024  // 128MB
        }
    }
}

struct DiskImageInfo: Codable, Equatable {
    var name: String
    var path: String
    var sizeBytes: Int64
    var emulator: EmulatorType

    var displaySize: String {
        let mb = Double(sizeBytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}

struct EmulatorConfiguration: Codable {
    var basiliskInstalled: Bool
    var sheepshaverInstalled: Bool
    var basiliskRomPath: String?
    var sheepshaverRomPath: String?
    var basiliskSharedFolder: String?
    var sheepshaverSharedFolder: String?
    var diskImages: [DiskImageInfo]

    static let `default` = EmulatorConfiguration(
        basiliskInstalled: false,
        sheepshaverInstalled: false,
        basiliskRomPath: nil,
        sheepshaverRomPath: nil,
        basiliskSharedFolder: nil,
        sheepshaverSharedFolder: nil,
        diskImages: []
    )

    func sharedFolder(for emulator: EmulatorType) -> String? {
        switch emulator {
        case .basilisk: return basiliskSharedFolder
        case .sheepshaver: return sheepshaverSharedFolder
        }
    }

    mutating func setSharedFolder(_ path: String?, for emulator: EmulatorType) {
        switch emulator {
        case .basilisk: basiliskSharedFolder = path
        case .sheepshaver: sheepshaverSharedFolder = path
        }
    }

    func romPath(for emulator: EmulatorType) -> String? {
        switch emulator {
        case .basilisk: return basiliskRomPath
        case .sheepshaver: return sheepshaverRomPath
        }
    }

    mutating func setRomPath(_ path: String?, for emulator: EmulatorType) {
        switch emulator {
        case .basilisk: basiliskRomPath = path
        case .sheepshaver: sheepshaverRomPath = path
        }
    }

    func isInstalled(_ emulator: EmulatorType) -> Bool {
        switch emulator {
        case .basilisk: return basiliskInstalled
        case .sheepshaver: return sheepshaverInstalled
        }
    }

    mutating func setInstalled(_ installed: Bool, for emulator: EmulatorType) {
        switch emulator {
        case .basilisk: basiliskInstalled = installed
        case .sheepshaver: sheepshaverInstalled = installed
        }
    }

    func diskImages(for emulator: EmulatorType) -> [DiskImageInfo] {
        diskImages.filter { $0.emulator == emulator }
    }
}

struct Configuration: Codable {
    var installedAt: Date?
    var buildTargets: [BuildTarget]
    var activeInterfaceVersion: String?
    var interfaceType: InterfaceType
    var emulators: EmulatorConfiguration?

    enum InterfaceType: String, Codable {
        case multiversal
        case apple
    }

    static let `default` = Configuration(
        installedAt: nil,
        buildTargets: [],
        activeInterfaceVersion: nil,
        interfaceType: .multiversal,
        emulators: nil
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
