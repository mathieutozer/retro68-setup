import Foundation

struct InterfaceVersion: Codable, Equatable {
    let name: String
    let type: Configuration.InterfaceType
    let path: URL
    let version: String?

    var displayName: String {
        if let version = version {
            return "\(name) \(version)"
        }
        return name
    }
}

actor InterfaceManager {
    private let shell = ShellRunner.shared

    static let multiversalInfo = """
    Multiversal Interfaces (Open Source)
    =====================================
    The Multiversal Interfaces are an open-source reimplementation of Apple's
    Universal Interfaces. They are included by default with Retro68.

    Limitations:
    - Missing Carbon support
    - Missing MacTCP, OpenTransport, Navigation Services
    - Missing features introduced after System 7.0

    For full compatibility with later Mac OS features, you'll need Apple's
    Universal Interfaces.
    """

    static let appleInterfacesInfo = """
    Apple Universal Interfaces
    ==========================
    Apple's proprietary Universal Interfaces provide full API coverage for
    classic Mac development. Version 3.4 is recommended and most tested.

    To obtain Apple Universal Interfaces:
    1. Download MPW (Macintosh Programmer's Workshop) Golden Master
       - Search for "MPW-GM.img.bin" or "mpw-gm.img_.bin"
       - Archive.org and Macintosh Garden are common sources

    2. Extract the disk image
       - On macOS, you may need to use an emulator or special tools
       - The InterfacesAndLibraries folder contains what you need

    3. Use 'retro68-setup interfaces add' to install them

    Supported formats for resource forks:
    - MacBinary II (.bin extension)
    - AppleDouble (._ prefix or % prefix)
    - Basilisk/Sheepshaver format (.rsrc/ directory)
    """

    func getAvailableInterfaces() async -> [InterfaceVersion] {
        var interfaces: [InterfaceVersion] = []

        // Always have Multiversal as an option (bundled with Retro68)
        if Paths.exists(Paths.sourceDir) {
            interfaces.append(InterfaceVersion(
                name: "Multiversal",
                type: .multiversal,
                path: Paths.sourceDir.appendingPathComponent("multiversal"),
                version: nil
            ))
        }

        // Check for Apple interfaces
        let appleDir = Paths.interfacesDir.appendingPathComponent("apple")
        if Paths.exists(appleDir) {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: appleDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for item in contents {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        interfaces.append(InterfaceVersion(
                            name: "Apple Universal Interfaces",
                            type: .apple,
                            path: item,
                            version: item.lastPathComponent
                        ))
                    }
                }
            }
        }

        return interfaces
    }

    func getActiveInterface() async -> InterfaceVersion? {
        let config = Configuration.load()
        let interfaces = await getAvailableInterfaces()

        if config.interfaceType == .multiversal {
            return interfaces.first { $0.type == .multiversal }
        } else if let version = config.activeInterfaceVersion {
            return interfaces.first { $0.type == .apple && $0.version == version }
        }

        return interfaces.first
    }

    nonisolated func setActiveInterface(_ interface: InterfaceVersion) throws {
        var config = Configuration.load()
        config.interfaceType = interface.type
        config.activeInterfaceVersion = interface.version
        try config.save()

        // Update the symlink in the build directory
        let targetLink = Paths.buildDir.appendingPathComponent("InterfacesAndLibraries")

        try? FileManager.default.removeItem(at: targetLink)

        if interface.type == .apple {
            try FileManager.default.createSymbolicLink(at: targetLink, withDestinationURL: interface.path)
        }
        // For multiversal, no symlink needed - it's the default
    }

    func addAppleInterfaces(from sourcePath: URL, version: String) async throws {
        let destDir = Paths.interfacesDir
            .appendingPathComponent("apple")
            .appendingPathComponent(version)

        try Paths.ensureDirectoryExists(destDir)

        // Copy the InterfacesAndLibraries content
        let sourceContents = try FileManager.default.contentsOfDirectory(
            at: sourcePath,
            includingPropertiesForKeys: nil
        )

        for item in sourceContents {
            let destPath = destDir.appendingPathComponent(item.lastPathComponent)
            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.copyItem(at: item, to: destPath)
        }
    }

    nonisolated func removeInterface(_ interface: InterfaceVersion) throws {
        guard interface.type == .apple else {
            return // Can't remove multiversal
        }

        try FileManager.default.removeItem(at: interface.path)

        // If this was the active interface, switch to multiversal
        var config = Configuration.load()
        if config.interfaceType == .apple && config.activeInterfaceVersion == interface.version {
            config.interfaceType = .multiversal
            config.activeInterfaceVersion = nil
            try config.save()
        }
    }
}
