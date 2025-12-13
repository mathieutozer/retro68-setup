import Foundation

enum DiskImageError: Error, LocalizedError {
    case creationFailed(String)
    case mountFailed(String)
    case unmountFailed(String)
    case copyFailed(String)
    case notFound(String)
    case alreadyMounted(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let msg): return "Failed to create disk image: \(msg)"
        case .mountFailed(let msg): return "Failed to mount disk image: \(msg)"
        case .unmountFailed(let msg): return "Failed to unmount disk image: \(msg)"
        case .copyFailed(let msg): return "Failed to copy file: \(msg)"
        case .notFound(let msg): return "Disk image not found: \(msg)"
        case .alreadyMounted(let msg): return "Disk image already mounted: \(msg)"
        }
    }
}

actor DiskImageManager {
    private let shell = ShellRunner.shared

    // MARK: - Creation

    /// Create a new HFS disk image
    /// - Parameters:
    ///   - name: Name for the disk image (used for filename and volume name)
    ///   - sizeMB: Size in megabytes
    ///   - emulator: Target emulator (affects recommended format)
    /// - Returns: Path to created disk image
    func createDiskImage(name: String, sizeMB: Int, for emulator: EmulatorType) async throws -> URL {
        try Paths.ensureDirectoryExists(Paths.diskImagesDir)

        let safeName = name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(safeName).img"
        let path = Paths.diskImagesDir.appendingPathComponent(filename)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: path)

        // Create HFS disk image using hdiutil
        // Use HFS format (not HFS+) for classic Mac compatibility
        let command = """
        hdiutil create \
            -size \(sizeMB)m \
            -fs HFS \
            -volname "\(name)" \
            -type UDIF \
            -layout NONE \
            "\(path.path)"
        """

        let result = try await shell.run(command, timeout: 120)

        if !result.succeeded {
            throw DiskImageError.creationFailed(result.stderr)
        }

        return path
    }

    /// Create a raw disk image (more compatible with some emulators)
    func createRawDiskImage(name: String, sizeMB: Int, for emulator: EmulatorType) async throws -> URL {
        try Paths.ensureDirectoryExists(Paths.diskImagesDir)

        let safeName = name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(safeName).dsk"
        let path = Paths.diskImagesDir.appendingPathComponent(filename)

        // Create blank raw disk image
        let command = "dd if=/dev/zero of=\"\(path.path)\" bs=1048576 count=\(sizeMB)"

        let result = try await shell.run(command, timeout: 300)

        if !result.succeeded {
            throw DiskImageError.creationFailed(result.stderr)
        }

        return path
    }

    // MARK: - Mounting

    struct MountInfo {
        let mountPoint: URL
        let deviceNode: String
    }

    /// Mount a disk image and return mount info
    func mount(_ imagePath: URL) async throws -> MountInfo {
        guard Paths.exists(imagePath) else {
            throw DiskImageError.notFound(imagePath.path)
        }

        // Check if already mounted
        if let existing = await getMountPoint(for: imagePath) {
            return existing
        }

        let command = "hdiutil attach \"\(imagePath.path)\" -nobrowse"
        let result = try await shell.run(command, timeout: 60)

        if !result.succeeded {
            throw DiskImageError.mountFailed(result.stderr)
        }

        // Parse output to find mount point
        // Format: /dev/diskN  Apple_HFS  /Volumes/VolumeName
        let lines = result.stdout.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, parts[2].starts(with: "/Volumes/") {
                return MountInfo(
                    mountPoint: URL(fileURLWithPath: parts[2]),
                    deviceNode: parts[0]
                )
            }
        }

        throw DiskImageError.mountFailed("Could not determine mount point")
    }

    /// Unmount a disk image
    func unmount(_ imagePath: URL) async throws {
        guard let mountInfo = await getMountPoint(for: imagePath) else {
            return // Not mounted, nothing to do
        }

        let command = "hdiutil detach \"\(mountInfo.deviceNode)\""
        let result = try await shell.run(command, timeout: 30)

        if !result.succeeded {
            // Try force unmount
            let forceResult = try await shell.run("hdiutil detach \"\(mountInfo.deviceNode)\" -force", timeout: 30)
            if !forceResult.succeeded {
                throw DiskImageError.unmountFailed(result.stderr)
            }
        }
    }

    /// Get mount point for an image if mounted
    func getMountPoint(for imagePath: URL) async -> MountInfo? {
        let result = try? await shell.run("hdiutil info")
        guard let output = result?.stdout else { return nil }

        let blocks = output.components(separatedBy: "================================================")

        for block in blocks {
            if block.contains(imagePath.path) {
                let lines = block.components(separatedBy: "\n")
                var deviceNode: String?
                var mountPoint: String?

                for line in lines {
                    if line.contains("/dev/disk") {
                        let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                        if parts.count >= 1 {
                            deviceNode = parts[0]
                        }
                        if parts.count >= 3, parts[2].starts(with: "/Volumes/") {
                            mountPoint = parts[2]
                        }
                    }
                }

                if let dev = deviceNode, let mount = mountPoint {
                    return MountInfo(mountPoint: URL(fileURLWithPath: mount), deviceNode: dev)
                }
            }
        }

        return nil
    }

    // MARK: - File Operations

    /// Copy a file or app bundle to a mounted disk image
    func copyToImage(_ sourcePath: URL, imagePath: URL) async throws {
        let mountInfo = try await mount(imagePath)

        let destination = mountInfo.mountPoint.appendingPathComponent(sourcePath.lastPathComponent)

        // Use ditto for proper resource fork handling
        let command = "ditto \"\(sourcePath.path)\" \"\(destination.path)\""
        let result = try await shell.run(command, timeout: 120)

        if !result.succeeded {
            throw DiskImageError.copyFailed(result.stderr)
        }
    }

    /// List contents of a mounted disk image
    func listContents(_ imagePath: URL) async throws -> [String] {
        let mountInfo = try await mount(imagePath)

        let result = try await shell.run("ls -la \"\(mountInfo.mountPoint.path)\"")

        if !result.succeeded {
            return []
        }

        return result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Discovery

    /// Find all disk images in our managed directory
    func listDiskImages() -> [URL] {
        let fm = FileManager.default
        guard Paths.exists(Paths.diskImagesDir),
              let contents = try? fm.contentsOfDirectory(at: Paths.diskImagesDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }

        return contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return ["img", "dsk", "dmg", "image", "hfv"].contains(ext)
        }
    }

    /// Get info about a disk image
    func getDiskImageInfo(_ path: URL, for emulator: EmulatorType) -> DiskImageInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }

        return DiskImageInfo(
            name: path.deletingPathExtension().lastPathComponent,
            path: path.path,
            sizeBytes: size,
            emulator: emulator
        )
    }

    // MARK: - Deletion

    func deleteDiskImage(_ path: URL) async throws {
        // Unmount first if mounted
        try await unmount(path)

        // Delete the file
        try FileManager.default.removeItem(at: path)
    }

    // MARK: - Built Apps Discovery

    /// Find built sample apps from Retro68
    func findBuiltApps(for target: BuildTarget) -> [URL] {
        let samplesDir: URL
        switch target {
        case .m68k:
            samplesDir = Paths.samplesDir68K
        case .powerpc, .carbon:
            samplesDir = target == .powerpc ? Paths.samplesDirPPC : Paths.samplesDirCarbon
        }

        guard Paths.exists(samplesDir) else { return [] }

        var apps: [URL] = []
        let fm = FileManager.default

        if let enumerator = fm.enumerator(at: samplesDir, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                // Look for .bin files (Retro68 output) or .dsk files
                let ext = url.pathExtension.lowercased()
                if ext == "bin" || ext == "dsk" || ext == "appl" {
                    apps.append(url)
                }
            }
        }

        return apps
    }
}
