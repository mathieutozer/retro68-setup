import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let retro68Root = home.appendingPathComponent(".retro68")
    static let sourceDir = retro68Root.appendingPathComponent("Retro68")
    static let buildDir = retro68Root.appendingPathComponent("Retro68-build")
    static let toolchainDir = buildDir.appendingPathComponent("toolchain")
    static let interfacesDir = retro68Root.appendingPathComponent("interfaces")
    static let configFile = retro68Root.appendingPathComponent("config.json")

    // Emulator paths
    static let emulatorsDir = retro68Root.appendingPathComponent("emulators")
    static let diskImagesDir = emulatorsDir.appendingPathComponent("disks")
    static let osImagesDir = emulatorsDir.appendingPathComponent("os-images")
    static let romDir = emulatorsDir.appendingPathComponent("rom")
    static let basiliskPrefs = emulatorsDir.appendingPathComponent("basilisk_ii_prefs")
    static let sheepshaverPrefs = emulatorsDir.appendingPathComponent("sheepshaver_prefs")

    static let gitRepoURL = "https://github.com/autc04/Retro68.git"

    static var samplesDir68K: URL {
        buildDir.appendingPathComponent("build-target/Samples")
    }

    static var samplesDirPPC: URL {
        buildDir.appendingPathComponent("build-target-ppc/Samples")
    }

    static var samplesDirCarbon: URL {
        buildDir.appendingPathComponent("build-target-carbon/Samples")
    }

    static func toolchainFile(for target: BuildTarget) -> URL {
        switch target {
        case .m68k:
            return toolchainDir.appendingPathComponent("m68k-apple-macos/cmake/retro68.toolchain.cmake")
        case .powerpc:
            return toolchainDir.appendingPathComponent("powerpc-apple-macos/cmake/retroppc.toolchain.cmake")
        case .carbon:
            return toolchainDir.appendingPathComponent("powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake")
        }
    }

    static func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func remove(_ url: URL) throws {
        if exists(url) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

enum BuildTarget: String, CaseIterable, Codable {
    case m68k = "68K"
    case powerpc = "PowerPC"
    case carbon = "Carbon"

    var displayName: String {
        switch self {
        case .m68k: return "68K (Classic Macs)"
        case .powerpc: return "PowerPC (Classic)"
        case .carbon: return "PowerPC (Carbon)"
        }
    }

    var buildFlag: String? {
        switch self {
        case .m68k: return nil
        case .powerpc: return nil
        case .carbon: return nil
        }
    }

    var skipFlag: String {
        switch self {
        case .m68k: return "--no-68k"
        case .powerpc: return "--no-ppc"
        case .carbon: return "--no-carbon"
        }
    }
}
