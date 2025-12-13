import Foundation

actor EmulatorManager {
    private let shell = ShellRunner.shared

    // MARK: - Installation Detection

    func isEmulatorInstalled(_ emulator: EmulatorType) async -> Bool {
        // Check if the app exists in /Applications
        let appPath = "/Applications/\(emulator.appName).app"
        return Paths.exists(URL(fileURLWithPath: appPath))
    }

    func getAppPath(_ emulator: EmulatorType) -> URL? {
        let appPath = URL(fileURLWithPath: "/Applications/\(emulator.appName).app")
        return Paths.exists(appPath) ? appPath : nil
    }

    /// Opens the download page in the user's browser
    func openDownloadPage(_ emulator: EmulatorType) async throws {
        _ = try await shell.run("open \"\(emulator.downloadPageURL)\"")
    }

    /// Opens the setup guide in the user's browser
    func openSetupGuide(_ emulator: EmulatorType) async throws {
        _ = try await shell.run("open \"\(emulator.setupGuideURL)\"")
    }

    /// Downloads and installs an emulator
    func downloadAndInstall(_ emulator: EmulatorType, onProgress: @escaping @Sendable (String) -> Void) async throws {
        let downloadURL = emulator.directDownloadURL
        let tempDir = FileManager.default.temporaryDirectory
        let zipPath = tempDir.appendingPathComponent("\(emulator.appName).zip")
        let extractDir = tempDir.appendingPathComponent("\(emulator.appName)_extract")

        // Clean up any previous attempts
        try? FileManager.default.removeItem(at: zipPath)
        try? FileManager.default.removeItem(at: extractDir)

        // Download
        onProgress("Downloading \(emulator.displayName)...")
        let downloadCommand = "curl -L -o \"\(zipPath.path)\" \"\(downloadURL)\""
        let downloadResult = try await shell.run(downloadCommand, timeout: 300)

        if !downloadResult.succeeded {
            throw ShellError.commandFailed(
                command: "curl",
                exitCode: downloadResult.exitCode,
                stderr: "Failed to download: \(downloadResult.stderr)"
            )
        }

        // Verify download
        guard Paths.exists(zipPath) else {
            throw ShellError.commandFailed(command: "curl", exitCode: 1, stderr: "Download file not found")
        }

        // Extract
        onProgress("Extracting...")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzipCommand = "unzip -q \"\(zipPath.path)\" -d \"\(extractDir.path)\""
        let unzipResult = try await shell.run(unzipCommand, timeout: 60)

        if !unzipResult.succeeded {
            throw ShellError.commandFailed(
                command: "unzip",
                exitCode: unzipResult.exitCode,
                stderr: "Failed to extract: \(unzipResult.stderr)"
            )
        }

        // Find the .app bundle
        onProgress("Installing to /Applications...")
        let appName = "\(emulator.appName).app"
        let findCommand = "find \"\(extractDir.path)\" -name '\(appName)' -type d | head -1"
        let findResult = try await shell.run(findCommand)

        guard findResult.succeeded, !findResult.stdout.isEmpty else {
            throw ShellError.commandFailed(
                command: "find",
                exitCode: 1,
                stderr: "Could not find \(appName) in extracted files"
            )
        }

        let appSourcePath = findResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let appDestPath = "/Applications/\(appName)"

        // Remove existing installation if present
        if Paths.exists(URL(fileURLWithPath: appDestPath)) {
            try FileManager.default.removeItem(atPath: appDestPath)
        }

        // Move to /Applications
        let moveCommand = "mv \"\(appSourcePath)\" \"\(appDestPath)\""
        let moveResult = try await shell.run(moveCommand)

        if !moveResult.succeeded {
            throw ShellError.commandFailed(
                command: "mv",
                exitCode: moveResult.exitCode,
                stderr: "Failed to install: \(moveResult.stderr)"
            )
        }

        // Remove quarantine attribute (allows running without Gatekeeper prompt)
        onProgress("Removing quarantine attribute...")
        _ = try? await shell.run("xattr -rd com.apple.quarantine \"\(appDestPath)\"")

        // Clean up temp files
        try? FileManager.default.removeItem(at: zipPath)
        try? FileManager.default.removeItem(at: extractDir)

        onProgress("Done!")
    }

    func downloadInstructions(for emulator: EmulatorType) -> String {
        switch emulator {
        case .basilisk:
            return """
            BasiliskII Installation
            -----------------------
            We'll download and install BasiliskII automatically from E-Maculation.

            Source: \(emulator.directDownloadURL)

            The app will be installed to /Applications/BasiliskII.app

            Manual alternative: \(emulator.downloadPageURL)
            Setup Guide: \(emulator.setupGuideURL)
            """

        case .sheepshaver:
            return """
            SheepShaver Installation
            ------------------------
            We'll download and install SheepShaver automatically from E-Maculation.

            Source: \(emulator.directDownloadURL)

            The app will be installed to /Applications/SheepShaver.app

            Manual alternative: \(emulator.downloadPageURL)
            Setup Guide: \(emulator.setupGuideURL)
            """
        }
    }

    // MARK: - ROM Detection

    func findRomFile(for emulator: EmulatorType) async -> URL? {
        // Check our managed ROM directory first
        let romDir = Paths.romDir
        if Paths.exists(romDir) {
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(at: romDir, includingPropertiesForKeys: nil) {
                for file in contents {
                    if isValidRom(file, for: emulator) {
                        return file
                    }
                }
            }
        }

        // Check common locations
        let commonPaths: [String]
        switch emulator {
        case .basilisk:
            commonPaths = [
                "~/Library/Preferences/BasiliskII",
                "~/.basilisk_ii_rom",
                "~/Documents/BasiliskII/ROM",
            ]
        case .sheepshaver:
            commonPaths = [
                "~/Library/Preferences/SheepShaver",
                "~/.sheepshaver_rom",
                "~/Documents/SheepShaver/ROM",
            ]
        }

        for path in commonPaths {
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if Paths.exists(url) {
                // Check if it's a directory with ROM inside
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                    if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        for file in contents {
                            if isValidRom(file, for: emulator) {
                                return file
                            }
                        }
                    }
                } else if isValidRom(url, for: emulator) {
                    return url
                }
            }
        }

        return nil
    }

    private func isValidRom(_ url: URL, for emulator: EmulatorType) -> Bool {
        // Check file size to validate ROM
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return false
        }

        switch emulator {
        case .basilisk:
            // 68K ROMs are typically 256KB, 512KB, or 1MB
            return size >= 256 * 1024 && size <= 1024 * 1024
        case .sheepshaver:
            // PPC ROMs are typically 1MB-4MB, or "Mac OS ROM" is ~3MB
            return size >= 1024 * 1024 && size <= 4 * 1024 * 1024
        }
    }

    // MARK: - Preferences

    struct BasiliskPrefs {
        var romPath: String
        var diskPaths: [String]
        var sharedFolderPath: String?
        var ramSizeMB: Int = 64
        var screenWidth: Int = 800
        var screenHeight: Int = 600
        var fullscreen: Bool = false
        var modelID: Int = 14  // 14 = Quadra 900
        var cpuType: Int = 4   // 4 = 68040
        var fpuEnabled: Bool = true
        var ignoreIllegalMemory: Bool = true
        var frameskip: Int = 1

        func generate() -> String {
            var prefs: [String] = []

            prefs.append("rom \(romPath)")

            for diskPath in diskPaths {
                prefs.append("disk \(diskPath)")
            }

            // Shared folder (appears as "Unix" volume on desktop)
            if let extfs = sharedFolderPath {
                prefs.append("extfs \(extfs)")
            }

            let ramBytes = ramSizeMB * 1024 * 1024
            prefs.append("ramsize \(ramBytes)")

            let screenMode = fullscreen ? "dga" : "win"
            prefs.append("screen \(screenMode)/\(screenWidth)/\(screenHeight)")

            prefs.append("frameskip \(frameskip)")
            prefs.append("modelid \(modelID)")
            prefs.append("cpu \(cpuType)")
            prefs.append("fpu \(fpuEnabled)")
            prefs.append("nocdrom true")

            if ignoreIllegalMemory {
                prefs.append("ignoresegv true")
                prefs.append("ignoreillegal true")
            }

            // Audio settings
            prefs.append("nosound false")

            // Misc
            prefs.append("seriala /dev/null")
            prefs.append("serialb /dev/null")

            return prefs.joined(separator: "\n") + "\n"
        }
    }

    struct SheepShaverPrefs {
        var romPath: String
        var diskPaths: [String]
        var sharedFolderPath: String?
        var ramSizeMB: Int = 256
        var screenWidth: Int = 800
        var screenHeight: Int = 600
        var fullscreen: Bool = false
        var jitEnabled: Bool = true
        var idleWait: Bool = true

        func generate() -> String {
            var prefs: [String] = []

            prefs.append("rom \(romPath)")

            for diskPath in diskPaths {
                prefs.append("disk \(diskPath)")
            }

            // Shared folder (appears as "Unix" volume on desktop)
            if let extfs = sharedFolderPath {
                prefs.append("extfs \(extfs)")
            }

            let ramBytes = ramSizeMB * 1024 * 1024
            prefs.append("ramsize \(ramBytes)")

            let screenMode = fullscreen ? "dga" : "win"
            prefs.append("screen \(screenMode)/\(screenWidth)/\(screenHeight)")

            prefs.append("frameskip 1")

            if jitEnabled {
                prefs.append("jit true")
            }
            if idleWait {
                prefs.append("idlewait true")
            }

            prefs.append("nocdrom true")
            prefs.append("nosound false")

            return prefs.joined(separator: "\n") + "\n"
        }
    }

    func generatePreferences(for emulator: EmulatorType, romPath: String, diskPaths: [String]) -> String {
        switch emulator {
        case .basilisk:
            let prefs = BasiliskPrefs(romPath: romPath, diskPaths: diskPaths)
            return prefs.generate()
        case .sheepshaver:
            let prefs = SheepShaverPrefs(romPath: romPath, diskPaths: diskPaths)
            return prefs.generate()
        }
    }

    func writePreferences(_ content: String, for emulator: EmulatorType) throws {
        try Paths.ensureDirectoryExists(Paths.emulatorsDir)
        try content.write(to: emulator.prefsPath, atomically: true, encoding: .utf8)
    }

    func writeBasiliskPrefs(_ prefs: BasiliskPrefs) throws {
        try Paths.ensureDirectoryExists(Paths.emulatorsDir)
        try prefs.generate().write(to: EmulatorType.basilisk.prefsPath, atomically: true, encoding: .utf8)
    }

    func writeSheepShaverPrefs(_ prefs: SheepShaverPrefs) throws {
        try Paths.ensureDirectoryExists(Paths.emulatorsDir)
        try prefs.generate().write(to: EmulatorType.sheepshaver.prefsPath, atomically: true, encoding: .utf8)
    }

    func readPreferences(for emulator: EmulatorType) -> String? {
        try? String(contentsOf: emulator.prefsPath, encoding: .utf8)
    }

    /// Parse disk paths from existing preferences
    func parseDisksFromPrefs(for emulator: EmulatorType) -> [String] {
        guard let content = readPreferences(for: emulator) else { return [] }
        var disks: [String] = []
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("disk ") {
                let path = String(line.dropFirst(5))
                disks.append(path)
            }
        }
        return disks
    }

    /// Add a disk to existing preferences
    func addDiskToPrefs(_ diskPath: String, for emulator: EmulatorType) throws {
        var content = readPreferences(for: emulator) ?? ""
        content += "disk \(diskPath)\n"
        try content.write(to: emulator.prefsPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Launch

    func launchEmulator(_ emulator: EmulatorType) async throws {
        let appPath = "/Applications/\(emulator.appName).app"

        guard Paths.exists(URL(fileURLWithPath: appPath)) else {
            throw ShellError.commandNotFound("\(emulator.appName).app not found in /Applications")
        }

        // Set prefs file location via environment or symlink
        // BasiliskII and SheepShaver look in specific locations
        switch emulator {
        case .basilisk:
            // Create symlink in expected location
            let expectedPrefs = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".basilisk_ii_prefs")
            try? FileManager.default.removeItem(at: expectedPrefs)
            try FileManager.default.createSymbolicLink(at: expectedPrefs, withDestinationURL: emulator.prefsPath)
        case .sheepshaver:
            // Create symlink in expected location
            let expectedPrefs = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".sheepshaver_prefs")
            try? FileManager.default.removeItem(at: expectedPrefs)
            try FileManager.default.createSymbolicLink(at: expectedPrefs, withDestinationURL: emulator.prefsPath)
        }

        // Launch the app
        _ = try await shell.run("open \"\(appPath)\"")
    }

    // MARK: - Directory Setup

    /// Ensures all emulator directories exist
    func ensureDirectoriesExist() throws {
        try Paths.ensureDirectoryExists(Paths.emulatorsDir)
        try Paths.ensureDirectoryExists(Paths.romDir)
        try Paths.ensureDirectoryExists(Paths.diskImagesDir)
        try Paths.ensureDirectoryExists(Paths.osImagesDir)
    }

    // MARK: - ROM Guidance

    func romGuidance(for emulator: EmulatorType) -> String {
        switch emulator {
        case .basilisk:
            return """
            BasiliskII ROM Requirements
            ---------------------------
            BasiliskII emulates 68K Macintosh computers and requires a ROM file
            from a real Mac or a legally obtained copy.

            Supported ROMs:
            - Mac II, IIx, IIcx, IIci, IIfx
            - Mac SE/30
            - Quadra 700, 800, 900, 950
            - Performa series (68K models)

            ROM Size: 256KB - 1MB

            Where to obtain:
            1. Dump from your own Mac using tools like CopyROM
            2. Internet Archive (archive.org) - search for "Mac ROM"
            3. Macintosh Repository (macintoshrepository.org)

            Place the ROM file in:
              \(Paths.romDir.path)/

            The file can have any name, but common names are:
            - QUADRA800.ROM
            - PERFORMA.ROM
            - MAC2CI.ROM
            """

        case .sheepshaver:
            return """
            SheepShaver ROM Requirements
            ----------------------------
            SheepShaver emulates PowerPC Macintosh computers. It can use either:

            Option 1: Old World ROM (from real hardware)
            - Power Mac 7500, 8500, 9500 series
            - Power Mac G3 (beige)
            - ROM Size: 4MB

            Option 2: New World ROM (from Mac OS installer)
            - Extract "Mac OS ROM" file from Mac OS 8.5 - 9.2.2 installer
            - This is the easiest legal option
            - Found in: System Folder/Mac OS ROM

            Where to obtain:
            1. Dump from your own PowerPC Mac
            2. Extract from Mac OS 8.5+ installation media
            3. Internet Archive - search for "Mac OS ROM"
            4. Macintosh Garden (macintoshgarden.org)

            Place the ROM file in:
              \(Paths.romDir.path)/

            Common file names:
            - Mac OS ROM
            - newworld.rom
            - PowerMac.ROM
            """
        }
    }

    // MARK: - OS Installation Guide

    func osInstallationGuide(for emulator: EmulatorType) -> String {
        switch emulator {
        case .basilisk:
            return """
            ============================================================
            INSTALLING MAC OS FOR BASILISKII (68K)
            ============================================================

            BasiliskII runs Mac OS 7.0 through 8.1. We recommend Mac OS 7.5.3
            as it's stable, freely available, and works well in emulation.

            STEP 1: DOWNLOAD MAC OS
            -----------------------
            Download Mac OS 7.5.3 from Internet Archive (free & legal):

              https://archive.org/details/AppleMacintoshSystem753

            You need TWO disk images:
            • Boot floppy: "Network Access Disk" or "DiskTools" image
            • Install CD/disk: The main System 7.5.3 installer

            Alternative sources:
            • https://archive.org/details/apple-mac-os-7.5.3
            • https://macintoshgarden.org (search "System 7.5.3")

            STEP 2: CREATE A HARD DISK IMAGE
            --------------------------------
            Run: retro68-setup emulator disk create

            Recommended size: 500 MB (enough for OS + apps)
            This creates a blank disk image for installing the OS.

            STEP 3: CONFIGURE BASILISKII
            ----------------------------
            1. Launch BasiliskII
            2. In Preferences > Volumes:
               - Add your boot floppy image (.img)
               - Add the installer CD/disk image
               - Add your blank hard disk image
            3. Set RAM to at least 32 MB
            4. Set CPU to 68040

            STEP 4: BOOT AND INITIALIZE
            ---------------------------
            1. Start BasiliskII - it will boot from the floppy
            2. Your blank hard disk will appear as "unreadable"
            3. Click "Initialize" when prompted
            4. Name your disk (e.g., "Macintosh HD")
            5. Choose "Mac OS Standard" format

            STEP 5: INSTALL MAC OS
            ----------------------
            1. Open the installer disk/CD
            2. Double-click the Installer
            3. Select your newly initialized disk as the destination
            4. Click Install and wait for completion
            5. When done, choose "Shut Down" (NOT Restart!)

            STEP 6: FIRST BOOT
            ------------------
            1. Quit BasiliskII completely
            2. In Preferences > Volumes, REMOVE the boot floppy and installer
            3. Keep only your hard disk image
            4. Start BasiliskII - it will now boot from your installed OS!

            TIPS:
            • Always use "Shut Down", never "Restart" (may crash)
            • Check "Ignore Illegal Memory Accesses" in preferences
            • Copy apps to the Mac HD before running (don't run from shared folders)
            """

        case .sheepshaver:
            return """
            ============================================================
            INSTALLING MAC OS FOR SHEEPSHAVER (POWERPC)
            ============================================================

            SheepShaver runs Mac OS 7.5.2 through 9.0.4. We recommend Mac OS 9.0.4
            as it's the most compatible with classic Mac software.

            NOTE: Mac OS 9.1 and later are NOT supported by SheepShaver!

            STEP 1: DOWNLOAD MAC OS 9.0.4
            -----------------------------
            Download from Macintosh Garden or Internet Archive:

              https://macintoshgarden.org/apps/os-904-us
              https://archive.org/details/Macintosh_Garden_OS_Collection

            Download the .iso or .toast CD image file.

            IMPORTANT: The CD image must be LOCKED before use:
            1. In Finder, Get Info on the .iso file
            2. Check the "Locked" checkbox
            (This prevents corruption and allows booting)

            STEP 2: CREATE A HARD DISK IMAGE
            --------------------------------
            Run: retro68-setup emulator disk create

            Recommended size: 1 GB (Mac OS 9 + apps need more space)
            This creates a blank disk image for installing the OS.

            STEP 3: CONFIGURE SHEEPSHAVER
            -----------------------------
            1. Launch SheepShaver
            2. In Preferences > Volumes:
               - Add your Mac OS 9.0.4 CD image (.iso)
               - Add your blank hard disk image
            3. Set RAM to at least 128 MB (256 MB recommended)
            4. Ensure your ROM file is configured

            STEP 4: BOOT AND INITIALIZE
            ---------------------------
            1. Start SheepShaver - it will boot from the CD
            2. Your blank hard disk will appear as "unreadable"
            3. Click "Initialize" when prompted
            4. Name your disk (e.g., "Macintosh HD")
            5. Choose "Mac OS Extended" format

            STEP 5: INSTALL MAC OS
            ----------------------
            1. Double-click "Mac OS Install" on the CD
            2. Follow the installation wizard
            3. Select your newly initialized disk as the destination

            IF INSTALLATION STALLS:
            - Cancel the installer
            - Restart the installer
            - Go to Options menu and UNCHECK "Update Apple Hard Disk Drivers"
            - Try again

            4. When complete, click "Quit" (NOT Restart!)

            STEP 6: FIRST BOOT
            ------------------
            1. Quit SheepShaver completely
            2. In Preferences > Volumes, REMOVE the CD image
            3. Keep only your hard disk image
            4. Start SheepShaver - it will boot from your installed OS!

            STEP 7: SKIP SETUP ASSISTANT
            ----------------------------
            On first boot, the Mac OS Setup Assistant will launch.
            QUIT IT IMMEDIATELY (File > Quit or Cmd+Q)
            - It may freeze during network setup
            - You can configure settings manually later

            TIPS:
            • Always "Shut Down", never use "Restart" (may crash)
            • Don't use the Startup Disk control panel (causes issues)
            • Copy apps to Mac HD before running them
            • For best performance, enable JIT in preferences
            """
        }
    }

    // MARK: - System Requirements

    func systemRequirements(for emulator: EmulatorType) -> String {
        switch emulator {
        case .basilisk:
            return """
            System Software for BasiliskII
            -------------------------------
            BasiliskII can run Mac OS 7.0 through 8.1.

            Recommended: Mac OS 7.5.3 or 7.6.1
            - Freely available from Apple's legacy software
            - Good compatibility with most software
            - Runs well in emulation

            You'll need to install Mac OS onto a disk image.
            Use 'retro68-setup emulator disk create' to create one.

            Sources for Mac OS:
            - Internet Archive (archive.org)
            - WinWorld (winworldpc.com)
            - Macintosh Garden
            """

        case .sheepshaver:
            return """
            System Software for SheepShaver
            --------------------------------
            SheepShaver can run Mac OS 8.5 through 9.0.4.

            Recommended: Mac OS 9.0.4
            - Best compatibility for PowerPC software
            - Supports Carbon applications
            - Good performance in emulation

            Note: Mac OS 9.1+ is NOT supported by SheepShaver.

            You'll need to install Mac OS onto a disk image.
            Use 'retro68-setup emulator disk create' to create one.

            Sources for Mac OS:
            - Internet Archive (archive.org)
            - WinWorld (winworldpc.com)
            - Macintosh Garden
            """
        }
    }
}
