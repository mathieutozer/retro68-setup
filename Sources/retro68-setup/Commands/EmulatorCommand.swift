import ArgumentParser
import Foundation
import Noora

struct EmulatorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emulator",
        abstract: "Install and manage classic Mac emulators for testing your builds",
        subcommands: [
            EmulatorInstallCommand.self,
            EmulatorSetupCommand.self,
            EmulatorGuideCommand.self,
            EmulatorRunCommand.self,
            EmulatorDiskCommand.self,
            EmulatorStatusCommand.self,
        ],
        defaultSubcommand: EmulatorStatusCommand.self
    )
}

// MARK: - Install Command

struct EmulatorInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install BasiliskII and/or SheepShaver emulators"
    )

    func run() async throws {
        let noora = Noora()
        let manager = EmulatorManager()

        print("")
        print("Emulator Installation")
        print("=====================")
        print("")
        print("Classic Mac emulators to test your Retro68 builds:")
        print("")
        print("  BasiliskII  - 68K Mac emulator (for 68K builds)")
        print("                Runs Mac OS 7.x - 8.1")
        print("")
        print("  SheepShaver - PowerPC Mac emulator (for PPC/Carbon builds)")
        print("                Runs Mac OS 8.5 - 9.0.4")
        print("")

        // Check current installation status
        let basiliskInstalled = await manager.isEmulatorInstalled(.basilisk)
        let sheepshaverInstalled = await manager.isEmulatorInstalled(.sheepshaver)

        print("Current Status:")
        print("  BasiliskII:  \(basiliskInstalled ? "Installed" : "Not installed")")
        print("  SheepShaver: \(sheepshaverInstalled ? "Installed" : "Not installed")")
        print("")

        if basiliskInstalled && sheepshaverInstalled {
            noora.success("Both emulators are already installed!")
            print("")
            print("Next steps:")
            print("  retro68-setup emulator setup  - Configure emulators")
            print("  retro68-setup emulator run    - Launch an emulator")
            return
        }

        // Select emulators to install
        struct EmulatorOption: CustomStringConvertible, Equatable {
            let emulator: EmulatorType
            let installed: Bool
            var description: String {
                if installed {
                    return "\(emulator.displayName) (already installed)"
                }
                return emulator.displayName
            }
        }

        let options = EmulatorType.allCases.map {
            EmulatorOption(
                emulator: $0,
                installed: $0 == .basilisk ? basiliskInstalled : sheepshaverInstalled
            )
        }

        let selected = noora.multipleChoicePrompt(
            title: "Select Emulators",
            question: "Which emulators would you like to install?",
            options: options,
            description: "Press SPACE to select, ENTER to confirm"
        )

        let toInstall = selected.filter { !$0.installed }.map { $0.emulator }

        if toInstall.isEmpty {
            print("")
            if selected.isEmpty {
                print("No emulators selected.")
            } else {
                noora.success("Selected emulators are already installed!")
            }
            print("")
            print("Next steps:")
            print("  retro68-setup emulator setup  - Configure emulators")
            print("  retro68-setup emulator status - View installation status")
            return
        }

        // Show what will be installed
        for emulator in toInstall {
            print("")
            print(await manager.downloadInstructions(for: emulator))
        }

        print("")

        // Confirm installation
        let confirm = noora.yesOrNoChoicePrompt(
            title: "Install",
            question: "Download and install \(toInstall.map(\.displayName).joined(separator: " and "))?",
            defaultAnswer: true,
            description: "This will download from E-Maculation and install to /Applications."
        )

        if !confirm {
            print("Installation cancelled.")
            print("")
            print("You can also download manually from:")
            for emulator in toInstall {
                print("  \(emulator.displayName): \(emulator.downloadPageURL)")
            }
            return
        }

        // Download and install each emulator
        var installedEmulators: [EmulatorType] = []

        for emulator in toInstall {
            print("")
            print("=" .repeated(60))
            print("")

            do {
                try await manager.downloadAndInstall(emulator) { progress in
                    print("  \(progress)")
                }
                print("")
                noora.success("\(emulator.displayName) installed successfully!")
                installedEmulators.append(emulator)
            } catch {
                noora.error("Failed to install \(emulator.displayName): \(error.localizedDescription)")
                print("")
                print("You can try downloading manually from:")
                print("  \(emulator.downloadPageURL)")
            }
        }

        if !installedEmulators.isEmpty {
            // Update configuration
            var config = Configuration.load()
            var emuConfig = config.emulators ?? EmulatorConfiguration.default

            for emulator in installedEmulators {
                emuConfig.setInstalled(true, for: emulator)
            }

            config.emulators = emuConfig
            try config.save()

            // Create directories for ROM and disk images
            try await manager.ensureDirectoriesExist()

            // Show ROM guidance
            print("")
            print("=" .repeated(60))
            print("")
            print("ROM FILES REQUIRED")
            print("==================")
            print("")
            print("The emulators need ROM files to function. Please read carefully:")
            print("")

            for emulator in installedEmulators {
                print(await manager.romGuidance(for: emulator))
                print("")
            }

            print("=" .repeated(60))
            print("")
            print("Directories created for you:")
            print("  ROM files:    \(Paths.romDir.path)")
            print("  Disk images:  \(Paths.diskImagesDir.path)")
            print("")
            print("Next steps:")
            print("-----------")
            print("1. Obtain ROM file(s) as described above")
            print("2. Place them in the ROM directory shown above")
            print("3. Run: retro68-setup emulator setup")
        }

        print("")
    }
}

// MARK: - Setup Command

struct EmulatorSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Configure emulators with ROM and disk images"
    )

    func run() async throws {
        let noora = Noora()
        let manager = EmulatorManager()
        let diskManager = DiskImageManager()

        print("")
        print("Emulator Setup")
        print("==============")
        print("")

        // Ensure directories exist
        try await manager.ensureDirectoriesExist()

        // Check which emulators are installed
        let basiliskInstalled = await manager.isEmulatorInstalled(.basilisk)
        let sheepshaverInstalled = await manager.isEmulatorInstalled(.sheepshaver)

        if !basiliskInstalled && !sheepshaverInstalled {
            noora.warning("No emulators installed.")
            print("Run 'retro68-setup emulator install' first.")
            print("")
            print("Directories have been created for when you're ready:")
            print("  ROM files:    \(Paths.romDir.path)")
            print("  Disk images:  \(Paths.diskImagesDir.path)")
            return
        }

        // Setup each installed emulator
        let installedEmulators = EmulatorType.allCases.filter { emu in
            emu == .basilisk ? basiliskInstalled : sheepshaverInstalled
        }

        for emulator in installedEmulators {
            print("")
            print("\(emulator.displayName) Setup")
            print("-".repeated(emulator.displayName.count + 6))
            print("")

            // Check for ROM
            let romPath = await manager.findRomFile(for: emulator)

            if let rom = romPath {
                noora.success("ROM found: \(rom.lastPathComponent)")
            } else {
                noora.warning("No ROM file found for \(emulator.displayName)")
                print("")
                print(await manager.romGuidance(for: emulator))
                print("")

                let proceed = noora.yesOrNoChoicePrompt(
                    title: "Continue",
                    question: "Continue setup without ROM? (You can add it later)",
                    defaultAnswer: true,
                    description: "The emulator won't run without a ROM, but we can configure other settings."
                )

                if !proceed {
                    continue
                }
            }

            // Check for disk images
            let existingDisks = await diskManager.listDiskImages()
            let emuDisks = existingDisks.filter { disk in
                // Simple heuristic: assume .img files work with both for now
                true
            }

            if emuDisks.isEmpty {
                print("")
                print("No disk images found.")

                let createDisk = noora.yesOrNoChoicePrompt(
                    title: "Create Disk",
                    question: "Would you like to create a disk image now?",
                    defaultAnswer: true,
                    description: "You'll need a disk image to install Mac OS and run applications."
                )

                if createDisk {
                    try await createDiskImageInteractive(noora: noora, diskManager: diskManager, for: emulator)
                }
            } else {
                print("")
                noora.success("Found \(emuDisks.count) disk image(s)")
                for disk in emuDisks {
                    print("  - \(disk.lastPathComponent)")
                }
            }

            // Generate preferences if we have ROM
            if let rom = romPath {
                let diskPaths = await diskManager.listDiskImages().map { $0.path }
                let prefs = await manager.generatePreferences(for: emulator, romPath: rom.path, diskPaths: diskPaths)

                print("")
                let writePrefs = noora.yesOrNoChoicePrompt(
                    title: "Preferences",
                    question: "Generate emulator preferences file?",
                    defaultAnswer: true,
                    description: "This will configure \(emulator.displayName) to use your ROM and disk images."
                )

                if writePrefs {
                    try await manager.writePreferences(prefs, for: emulator)
                    noora.success("Preferences saved to \(emulator.prefsPath.path)")
                }
            }

            // Show system requirements info
            print("")
            print(await manager.systemRequirements(for: emulator))
        }

        // Update configuration
        var config = Configuration.load()
        var emuConfig = config.emulators ?? EmulatorConfiguration.default
        emuConfig.basiliskInstalled = basiliskInstalled
        emuConfig.sheepshaverInstalled = sheepshaverInstalled

        // Update ROM paths
        for emulator in installedEmulators {
            if let romPath = await manager.findRomFile(for: emulator) {
                emuConfig.setRomPath(romPath.path, for: emulator)
            }
        }

        // Update disk images
        let allDisks = await diskManager.listDiskImages()
        var diskInfos: [DiskImageInfo] = []
        for url in allDisks {
            // Determine emulator based on simple heuristics
            let emulator: EmulatorType = .basilisk  // Default, could be smarter
            if let info = await diskManager.getDiskImageInfo(url, for: emulator) {
                diskInfos.append(info)
            }
        }
        emuConfig.diskImages = diskInfos

        config.emulators = emuConfig
        try config.save()

        print("")
        print("=" .repeated(50))
        print("")
        noora.success("Setup complete!")
        print("")
        print("Next steps:")
        print("-----------")
        print("1. retro68-setup emulator guide    - How to install Mac OS")
        print("2. retro68-setup emulator run      - Launch an emulator")
        print("3. retro68-setup emulator disk     - Manage disk images")
        print("4. retro68-setup build             - Build sample apps")
        print("")
    }

    private func createDiskImageInteractive(noora: Noora, diskManager: DiskImageManager, for emulator: EmulatorType) async throws {
        let name = noora.textPrompt(
            title: "Disk Name",
            prompt: "Enter a name for the disk image (default: MacOS):",
            description: "This will be the volume name visible in the emulator."
        )
        let diskName = name.isEmpty ? "MacOS" : name

        struct SizeOption: CustomStringConvertible, Equatable {
            let size: Int
            let label: String
            var description: String { label }
        }

        let sizeOptions = [
            SizeOption(size: 100, label: "100 MB (minimal)"),
            SizeOption(size: 500, label: "500 MB (recommended)"),
            SizeOption(size: 1024, label: "1 GB (spacious)"),
            SizeOption(size: 2048, label: "2 GB (maximum for HFS)")
        ]

        let selectedSize = noora.singleChoicePrompt(
            title: "Size",
            question: "Select disk image size:",
            options: sizeOptions,
            description: "Larger disks can hold more applications."
        )

        print("")
        print("Creating disk image...")

        do {
            let path = try await diskManager.createDiskImage(name: diskName, sizeMB: selectedSize.size, for: emulator)
            print("")
            noora.success("Disk image created: \(path.lastPathComponent)")
        } catch {
            noora.error("Failed to create disk image: \(error.localizedDescription)")
        }
    }
}

// MARK: - Guide Command

struct EmulatorGuideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Interactive step-by-step guide to installing Mac OS in an emulator"
    )

    @Option(name: .shortAndLong, help: "Emulator to show guide for (basilisk or sheepshaver)")
    var emulator: String?

    func run() async throws {
        let noora = Noora()
        let manager = EmulatorManager()
        let diskManager = DiskImageManager()

        // Ensure directories exist
        try await manager.ensureDirectoriesExist()

        print("")
        print("=".repeated(60))
        print("  MAC OS INSTALLATION WIZARD")
        print("=".repeated(60))
        print("")
        print("This wizard will guide you through installing Mac OS")
        print("in an emulator step by step.")
        print("")

        // Determine which emulator
        let selectedEmulator: EmulatorType

        if let specified = emulator {
            switch specified.lowercased() {
            case "basilisk", "basiliskii", "68k":
                selectedEmulator = .basilisk
            case "sheepshaver", "ppc", "powerpc":
                selectedEmulator = .sheepshaver
            default:
                noora.error("Unknown emulator: \(specified)")
                print("Use 'basilisk' or 'sheepshaver'")
                throw ExitCode.failure
            }
        } else {
            let basiliskInstalled = await manager.isEmulatorInstalled(.basilisk)
            let sheepshaverInstalled = await manager.isEmulatorInstalled(.sheepshaver)

            struct EmuOption: CustomStringConvertible, Equatable {
                let emulator: EmulatorType
                let installed: Bool
                var description: String {
                    installed ? "\(emulator.displayName) (installed)" : emulator.displayName
                }
            }

            let options = EmulatorType.allCases.map {
                EmuOption(emulator: $0, installed: $0 == .basilisk ? basiliskInstalled : sheepshaverInstalled)
            }

            let selected = noora.singleChoicePrompt(
                title: "Emulator",
                question: "Which emulator are you setting up?",
                options: options,
                description: "Select the emulator to configure."
            )
            selectedEmulator = selected.emulator
        }

        // Run the appropriate wizard
        switch selectedEmulator {
        case .basilisk:
            try await runBasiliskWizard(noora: noora, manager: manager, diskManager: diskManager)
        case .sheepshaver:
            try await runSheepShaverWizard(noora: noora, manager: manager, diskManager: diskManager)
        }
    }

    // MARK: - BasiliskII Wizard

    private func runBasiliskWizard(noora: Noora, manager: EmulatorManager, diskManager: DiskImageManager) async throws {
        // Check if emulator is installed
        let isInstalled = await manager.isEmulatorInstalled(.basilisk)
        if !isInstalled {
            print("")
            noora.warning("BasiliskII is not installed yet.")
            let install = noora.yesOrNoChoicePrompt(
                title: "Install",
                question: "Would you like to install BasiliskII first?",
                defaultAnswer: true,
                description: "We'll download and install it automatically."
            )
            if install {
                try await manager.downloadAndInstall(.basilisk) { progress in
                    print("  \(progress)")
                }
                noora.success("BasiliskII installed!")
            } else {
                print("Please install BasiliskII first, then run this guide again.")
                return
            }
        }

        // Step 1: ROM Check
        print("")
        print("-".repeated(60))
        print("STEP 1: ROM FILE")
        print("-".repeated(60))
        print("")

        var romPath = await manager.findRomFile(for: .basilisk)
        if let rom = romPath {
            noora.success("ROM file found: \(rom.lastPathComponent)")
            print("")
            let cont = noora.yesOrNoChoicePrompt(
                title: "Continue",
                question: "ROM is ready. Continue to next step?",
                defaultAnswer: true,
                description: ""
            )
            if !cont { return }
        } else {
            print("BasiliskII needs a 68K Macintosh ROM file to run.")
            print("")
            print("ROM requirements:")
            print("  • Size: 256KB - 1MB")
            print("  • Compatible: Mac II, IIci, Quadra, Performa (68K)")
            print("")
            print("Where to find ROMs:")
            print("  • Dump from your own vintage Mac")
            print("  • Internet Archive: search 'Macintosh ROM'")
            print("  • Macintosh Repository: macintoshrepository.org")
            print("")
            print("Place the ROM file in:")
            print("  \(Paths.romDir.path)")
            print("")

            var hasRom = false
            while !hasRom {
                let ready = noora.yesOrNoChoicePrompt(
                    title: "ROM",
                    question: "Have you placed a ROM file in the directory above?",
                    defaultAnswer: false,
                    description: "You'll need to obtain one before continuing."
                )

                if !ready {
                    print("")
                    print("Please obtain a ROM file and place it in:")
                    print("  \(Paths.romDir.path)")
                    print("")
                    print("Then run this guide again.")
                    return
                }

                // Check again
                romPath = await manager.findRomFile(for: .basilisk)
                if romPath != nil {
                    hasRom = true
                    noora.success("ROM file found: \(romPath!.lastPathComponent)")
                } else {
                    noora.warning("ROM file not detected in the expected location.")
                    print("")
                    print("Make sure to place a valid ROM file (256KB-1MB) in:")
                    print("  \(Paths.romDir.path)")
                    print("")
                }
            }
        }

        // Step 2: Download Mac OS
        print("")
        print("-".repeated(60))
        print("STEP 2: DOWNLOAD MAC OS 7.5.3")
        print("-".repeated(60))
        print("")
        print("Mac OS 7.5.3 was released as freeware by Apple.")
        print("It's the recommended OS for BasiliskII.")
        print("")
        print("You'll need to download a pre-built System 7.5.3 disk image.")
        print("")
        print("Download from Internet Archive:")
        print("  https://archive.org/details/AppleMacintoshSystem753")
        print("")

        let openDownload = noora.yesOrNoChoicePrompt(
            title: "Download",
            question: "Open the download page in your browser?",
            defaultAnswer: true,
            description: "Download the disk image, then continue."
        )

        if openDownload {
            _ = try? await ShellRunner.shared.run("open \"https://archive.org/details/AppleMacintoshSystem753\"")
            print("")
            print("Browser opened. Download the disk image file.")
            print("")
            print("Look for a file like:")
            print("  • Apple Macintosh System 7.5.3.img")
            print("  • system753.dsk")
            print("  • or similar .img/.dsk file")
        }

        print("")
        var hasOS = noora.yesOrNoChoicePrompt(
            title: "Downloaded",
            question: "Have you downloaded the Mac OS disk image?",
            defaultAnswer: false,
            description: "Take your time - the download may take a few minutes."
        )

        while !hasOS {
            print("")
            print("Waiting for download... Take your time!")
            print("")
            hasOS = noora.yesOrNoChoicePrompt(
                title: "Ready",
                question: "Ready to continue?",
                defaultAnswer: false,
                description: ""
            )
        }

        // Step 2b: Locate the downloaded Mac OS image
        print("")
        print("-".repeated(60))
        print("STEP 2b: LOCATE MAC OS DISK IMAGE")
        print("-".repeated(60))
        print("")
        print("Please provide the path to the Mac OS disk image you downloaded.")
        print("")
        print("Tip: You can drag and drop the file from Finder into this terminal")
        print("     to paste its path.")
        print("")

        var macOSImagePath: String = ""
        while macOSImagePath.isEmpty {
            let inputPath = noora.textPrompt(
                title: "Mac OS Image",
                prompt: "Enter the path to the Mac OS disk image:",
                description: "The .img or .dsk file you downloaded."
            )

            let cleanPath = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\ ", with: " ")  // Handle escaped spaces
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))  // Remove quotes

            if cleanPath.isEmpty {
                noora.warning("Please enter a path.")
                continue
            }

            let expandedPath = NSString(string: cleanPath).expandingTildeInPath
            let sourceURL = URL(fileURLWithPath: expandedPath)
            if Paths.exists(sourceURL) {
                // Copy to our managed os-images directory
                let destURL = Paths.osImagesDir.appendingPathComponent(sourceURL.lastPathComponent)

                if Paths.exists(destURL) {
                    // Already exists in our directory
                    macOSImagePath = destURL.path
                    noora.success("Found: \(destURL.lastPathComponent)")
                    print("  (Already in: \(Paths.osImagesDir.path))")
                } else {
                    print("")
                    print("Copying to: \(Paths.osImagesDir.path)")
                    do {
                        try FileManager.default.copyItem(at: sourceURL, to: destURL)
                        macOSImagePath = destURL.path
                        noora.success("Copied: \(destURL.lastPathComponent)")
                    } catch {
                        noora.warning("Could not copy file: \(error.localizedDescription)")
                        print("Using original location instead.")
                        macOSImagePath = expandedPath
                    }
                }
            } else {
                noora.warning("File not found: \(cleanPath)")
                print("Please check the path and try again.")
                print("")
            }
        }

        // Step 3: Create hard disk image
        print("")
        print("-".repeated(60))
        print("STEP 3: CREATE HARD DISK IMAGE")
        print("-".repeated(60))
        print("")
        print("You need a blank disk image to install Mac OS onto.")
        print("")

        var hardDiskPath: String = ""
        let existingDisks = await diskManager.listDiskImages()

        if !existingDisks.isEmpty {
            print("Existing disk images found:")
            for disk in existingDisks {
                if let info = await diskManager.getDiskImageInfo(disk, for: .basilisk) {
                    print("  • \(info.name) (\(info.displaySize)) - \(disk.path)")
                }
            }
            print("")

            struct DiskChoice: CustomStringConvertible, Equatable {
                let label: String
                let path: String?
                var description: String { label }
            }

            var choices = existingDisks.map { disk -> DiskChoice in
                let name = disk.deletingPathExtension().lastPathComponent
                return DiskChoice(label: "Use: \(name)", path: disk.path)
            }
            choices.append(DiskChoice(label: "Create new disk image", path: nil))

            let choice = noora.singleChoicePrompt(
                title: "Disk",
                question: "Select a disk image:",
                options: choices,
                description: "Choose an existing disk or create a new one."
            )

            if let path = choice.path {
                hardDiskPath = path
                noora.success("Using: \(URL(fileURLWithPath: path).lastPathComponent)")
            } else {
                let newDisk = try await createDiskInteractive(noora: noora, diskManager: diskManager, recommendedSize: 500)
                hardDiskPath = newDisk.path
            }
        } else {
            print("No disk images found. Let's create one.")
            print("")
            let newDisk = try await createDiskInteractive(noora: noora, diskManager: diskManager, recommendedSize: 500)
            hardDiskPath = newDisk.path
        }

        // Step 4: Configure BasiliskII
        print("")
        print("-".repeated(60))
        print("STEP 4: CONFIGURE BASILISKII")
        print("-".repeated(60))
        print("")
        print("Now we'll configure BasiliskII for you.")
        print("")
        print("BasiliskII doesn't have a built-in settings GUI, so we'll")
        print("create the configuration file directly.")
        print("")

        // RAM selection
        struct RAMOption: CustomStringConvertible, Equatable {
            let mb: Int
            var description: String {
                mb == 64 ? "\(mb) MB (recommended)" : "\(mb) MB"
            }
        }

        let ramOptions = [
            RAMOption(mb: 32),
            RAMOption(mb: 64),
            RAMOption(mb: 128)
        ]

        let selectedRAM = noora.singleChoicePrompt(
            title: "RAM",
            question: "How much RAM for the emulated Mac?",
            options: ramOptions,
            description: "More RAM allows running larger applications."
        )

        // Screen size
        struct ScreenOption: CustomStringConvertible, Equatable {
            let width: Int
            let height: Int
            var description: String {
                let rec = (width == 800 && height == 600) ? " (recommended)" : ""
                return "\(width) x \(height)\(rec)"
            }
        }

        let screenOptions = [
            ScreenOption(width: 640, height: 480),
            ScreenOption(width: 800, height: 600),
            ScreenOption(width: 1024, height: 768)
        ]

        let selectedScreen = noora.singleChoicePrompt(
            title: "Screen",
            question: "Select screen resolution:",
            options: screenOptions,
            description: "The size of the emulator window."
        )

        // Shared folder setup
        print("")
        print("SHARED FOLDER")
        print("")
        print("A shared folder lets you easily transfer files between your Mac")
        print("and the emulated system. It appears as a 'Unix' disk on the desktop.")
        print("")
        print("This is how you'll copy your Retro68 builds into the emulator.")
        print("")

        var sharedFolderPath: String? = nil
        let setupShared = noora.yesOrNoChoicePrompt(
            title: "Shared",
            question: "Set up a shared folder?",
            defaultAnswer: true,
            description: "Recommended for transferring built apps."
        )

        if setupShared {
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
                .appendingPathComponent("BasiliskII Shared")
                .path

            print("")
            print("Default location: \(defaultPath)")
            print("")

            let customPath = noora.textPrompt(
                title: "Path",
                prompt: "Enter shared folder path (or press Enter for default):",
                description: "This folder will be accessible from within the emulator."
            )

            let finalPath = customPath.isEmpty ? defaultPath : NSString(string: customPath).expandingTildeInPath
            let folderURL = URL(fileURLWithPath: finalPath)

            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                sharedFolderPath = finalPath
                noora.success("Shared folder created: \(finalPath)")
            } catch {
                noora.warning("Could not create folder: \(error.localizedDescription)")
            }
        }

        // Generate and write preferences
        print("")
        print("Generating configuration...")

        let prefs = EmulatorManager.BasiliskPrefs(
            romPath: romPath!.path,
            diskPaths: [macOSImagePath, hardDiskPath],
            sharedFolderPath: sharedFolderPath,
            ramSizeMB: selectedRAM.mb,
            screenWidth: selectedScreen.width,
            screenHeight: selectedScreen.height
        )

        try await manager.writeBasiliskPrefs(prefs)

        // Save shared folder to config
        if let sharedPath = sharedFolderPath {
            var config = Configuration.load()
            var emuConfig = config.emulators ?? EmulatorConfiguration.default
            emuConfig.setSharedFolder(sharedPath, for: .basilisk)
            config.emulators = emuConfig
            try config.save()
        }

        print("")
        noora.success("Configuration saved!")
        print("")
        print("Settings:")
        print("  ROM:    \(romPath!.lastPathComponent)")
        print("  OS:     \(URL(fileURLWithPath: macOSImagePath).lastPathComponent)")
        print("  Disk:   \(URL(fileURLWithPath: hardDiskPath).lastPathComponent)")
        print("  RAM:    \(selectedRAM.mb) MB")
        print("  Screen: \(selectedScreen.width) x \(selectedScreen.height)")
        if let shared = sharedFolderPath {
            print("  Shared: \(shared)")
        }
        print("")

        _ = noora.yesOrNoChoicePrompt(
            title: "Continue",
            question: "Ready to boot BasiliskII?",
            defaultAnswer: true,
            description: "Press Enter to continue."
        )

        // Step 5: Install Mac OS
        print("")
        print("-".repeated(60))
        print("STEP 5: INSTALL MAC OS")
        print("-".repeated(60))
        print("")
        print("Now we'll launch BasiliskII so you can install Mac OS.")
        print("")
        print("What to do when it starts:")
        print("")
        print("1. Your blank hard disk will appear as 'unreadable'")
        print("   • Click 'Initialize' when prompted")
        print("   • Name it (e.g., 'Macintosh HD')")
        print("   • Choose 'Mac OS Standard' format")
        print("")
        print("2. Install Mac OS using ONE of these methods:")
        print("")
        print("   METHOD A - If system boots and is usable:")
        print("   • The disk image may already be a bootable system")
        print("   • Open the System Folder, select all, drag to your hard disk")
        print("   • Make sure to copy the complete System Folder")
        print("")
        print("   METHOD B - If there's an installer:")
        print("   • Look for 'Install System Software' or similar")
        print("   • Double-click and follow the prompts")
        print("   • Select your hard disk as the destination")
        print("")
        print("3. When done, choose 'Special > Shut Down'")
        print("   (Do NOT use Restart - it may crash)")
        print("")

        let launchForInstall = noora.yesOrNoChoicePrompt(
            title: "Launch",
            question: "Launch BasiliskII now to install Mac OS?",
            defaultAnswer: true,
            description: "The emulator will open with the installer disk."
        )

        if launchForInstall {
            do {
                try await manager.launchEmulator(.basilisk)
                print("")
                noora.success("BasiliskII launched!")
                print("")
                print("Complete the installation as described above.")
                print("When finished, use 'Special > Shut Down' to quit.")
            } catch {
                noora.warning("Could not launch: \(error.localizedDescription)")
                print("You can launch manually from /Applications/BasiliskII.app")
            }
        }

        print("")
        var installComplete = false
        while !installComplete {
            installComplete = noora.yesOrNoChoicePrompt(
                title: "Done",
                question: "Have you completed the Mac OS installation and shut down?",
                defaultAnswer: false,
                description: "Make sure you used 'Shut Down', not 'Restart'."
            )
            if !installComplete {
                print("")
                print("Take your time! Complete the installation, then come back.")
                print("")
            }
        }

        // Step 6: First boot
        print("")
        print("-".repeated(60))
        print("STEP 6: CONFIGURE FOR NORMAL BOOT")
        print("-".repeated(60))
        print("")
        print("Now that Mac OS is installed, we need to reconfigure BasiliskII")
        print("to boot from your hard disk instead of the installer.")
        print("")

        let updatePrefs = noora.yesOrNoChoicePrompt(
            title: "Update",
            question: "Remove the installer disk from configuration?",
            defaultAnswer: true,
            description: "This will make BasiliskII boot directly from your installed OS."
        )

        if updatePrefs {
            // Update prefs to only include the hard disk (not the installer)
            let bootPrefs = EmulatorManager.BasiliskPrefs(
                romPath: romPath!.path,
                diskPaths: [hardDiskPath],  // Only the hard disk, not the installer
                sharedFolderPath: sharedFolderPath,
                ramSizeMB: selectedRAM.mb,
                screenWidth: selectedScreen.width,
                screenHeight: selectedScreen.height
            )

            do {
                try await manager.writeBasiliskPrefs(bootPrefs)
                noora.success("Configuration updated!")
                print("")
                print("BasiliskII will now boot from: \(URL(fileURLWithPath: hardDiskPath).lastPathComponent)")
            } catch {
                noora.warning("Could not update configuration: \(error.localizedDescription)")
                print("You may need to manually edit: \(Paths.basiliskPrefs.path)")
            }
        } else {
            print("")
            print("To change disk configuration later, edit:")
            print("  \(Paths.basiliskPrefs.path)")
            print("")
            print("Remove the 'disk' line for the installer image.")
        }

        print("")
        _ = noora.yesOrNoChoicePrompt(
            title: "Continue",
            question: "Ready to launch BasiliskII?",
            defaultAnswer: true,
            description: "Press Enter to continue."
        )

        // Done!
        print("")
        print("=".repeated(60))
        noora.success("SETUP COMPLETE!")
        print("=".repeated(60))
        print("")
        print("Tips for using BasiliskII:")
        print("  • Always use 'Shut Down', never 'Restart'")
        print("  • If it crashes, the preferences include 'ignoresegv true'")
        print("  • Copy apps to Mac HD before running them")
        print("")

        let launchNow = noora.yesOrNoChoicePrompt(
            title: "Launch",
            question: "Launch BasiliskII now?",
            defaultAnswer: true,
            description: "Start the emulator to verify everything works."
        )

        if launchNow {
            do {
                try await manager.launchEmulator(.basilisk)
                print("")
                noora.success("BasiliskII launched!")
            } catch {
                noora.warning("Could not launch: \(error.localizedDescription)")
            }
        }

        print("")
        print("Commands for later:")
        print("  retro68-setup emulator run       - Launch the emulator")
        print("  retro68-setup emulator disk copy - Copy apps to disk images")
        print("")
    }

    // MARK: - SheepShaver Wizard

    private func runSheepShaverWizard(noora: Noora, manager: EmulatorManager, diskManager: DiskImageManager) async throws {
        // Check if emulator is installed
        let isInstalled = await manager.isEmulatorInstalled(.sheepshaver)
        if !isInstalled {
            print("")
            noora.warning("SheepShaver is not installed yet.")
            let install = noora.yesOrNoChoicePrompt(
                title: "Install",
                question: "Would you like to install SheepShaver first?",
                defaultAnswer: true,
                description: "We'll download and install it automatically."
            )
            if install {
                try await manager.downloadAndInstall(.sheepshaver) { progress in
                    print("  \(progress)")
                }
                noora.success("SheepShaver installed!")
            } else {
                print("Please install SheepShaver first, then run this guide again.")
                return
            }
        }

        // Step 1: ROM Check
        print("")
        print("-".repeated(60))
        print("STEP 1: ROM FILE")
        print("-".repeated(60))
        print("")

        var romPath = await manager.findRomFile(for: .sheepshaver)
        if let rom = romPath {
            noora.success("ROM file found: \(rom.lastPathComponent)")
            print("")
            let cont = noora.yesOrNoChoicePrompt(
                title: "Continue",
                question: "ROM is ready. Continue to next step?",
                defaultAnswer: true,
                description: ""
            )
            if !cont { return }
        } else {
            print("SheepShaver needs a PowerPC ROM file to run.")
            print("")
            print("Two options:")
            print("")
            print("  Option A: Old World ROM (from real hardware)")
            print("    • Dump from Power Mac 7500/8500/9500 or beige G3")
            print("    • Size: ~4MB")
            print("")
            print("  Option B: New World ROM (easier)")
            print("    • Extract 'Mac OS ROM' from Mac OS 8.5-9.2.2 installer")
            print("    • Found in: System Folder/Mac OS ROM")
            print("    • Size: ~3MB")
            print("")
            print("Place the ROM file in:")
            print("  \(Paths.romDir.path)")
            print("")

            var hasRom = false
            while !hasRom {
                let ready = noora.yesOrNoChoicePrompt(
                    title: "ROM",
                    question: "Have you placed a ROM file in the directory above?",
                    defaultAnswer: false,
                    description: "You'll need to obtain one before continuing."
                )

                if !ready {
                    print("")
                    print("Please obtain a ROM file and place it in:")
                    print("  \(Paths.romDir.path)")
                    print("")
                    print("Then run this guide again.")
                    return
                }

                // Check again
                romPath = await manager.findRomFile(for: .sheepshaver)
                if romPath != nil {
                    hasRom = true
                    noora.success("ROM file found: \(romPath!.lastPathComponent)")
                } else {
                    noora.warning("ROM file not detected in the expected location.")
                    print("")
                    print("Make sure to place a valid ROM file (1MB-4MB) in:")
                    print("  \(Paths.romDir.path)")
                    print("")
                }
            }
        }

        // Step 2: Download Mac OS 9
        print("")
        print("-".repeated(60))
        print("STEP 2: DOWNLOAD MAC OS 9.0.4")
        print("-".repeated(60))
        print("")
        print("Mac OS 9.0.4 is the recommended version for SheepShaver.")
        print("")
        print("IMPORTANT: Mac OS 9.1 and later are NOT supported!")
        print("")
        print("Download from Macintosh Garden:")
        print("  https://macintoshgarden.org/apps/os-904-us")
        print("")

        let openDownload = noora.yesOrNoChoicePrompt(
            title: "Download",
            question: "Open the download page in your browser?",
            defaultAnswer: true,
            description: "Download the .iso file, then continue."
        )

        if openDownload {
            _ = try? await ShellRunner.shared.run("open \"https://macintoshgarden.org/apps/os-904-us\"")
            print("")
            print("Browser opened. Download the Mac OS 9.0.4 ISO file.")
        }

        print("")
        var hasOS = noora.yesOrNoChoicePrompt(
            title: "Downloaded",
            question: "Have you downloaded Mac OS 9.0.4?",
            defaultAnswer: false,
            description: "The file is about 400MB."
        )

        while !hasOS {
            print("")
            print("Waiting for download...")
            print("")
            hasOS = noora.yesOrNoChoicePrompt(
                title: "Ready",
                question: "Ready to continue?",
                defaultAnswer: false,
                description: ""
            )
        }

        // Step 2b: Locate the downloaded ISO
        print("")
        print("-".repeated(60))
        print("STEP 2b: LOCATE MAC OS 9 ISO")
        print("-".repeated(60))
        print("")
        print("Please provide the path to the Mac OS 9.0.4 ISO you downloaded.")
        print("")
        print("Tip: You can drag and drop the file from Finder into this terminal")
        print("     to paste its path.")
        print("")

        var macOSImagePath: String = ""
        while macOSImagePath.isEmpty {
            let inputPath = noora.textPrompt(
                title: "Mac OS 9 ISO",
                prompt: "Enter the path to the Mac OS 9 ISO:",
                description: "The .iso or .toast file you downloaded."
            )

            let cleanPath = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\ ", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))

            if cleanPath.isEmpty {
                noora.warning("Please enter a path.")
                continue
            }

            let expandedPath = NSString(string: cleanPath).expandingTildeInPath
            let sourceURL = URL(fileURLWithPath: expandedPath)
            if Paths.exists(sourceURL) {
                // Copy to our managed os-images directory
                let destURL = Paths.osImagesDir.appendingPathComponent(sourceURL.lastPathComponent)

                if Paths.exists(destURL) {
                    macOSImagePath = destURL.path
                    noora.success("Found: \(destURL.lastPathComponent)")
                    print("  (Already in: \(Paths.osImagesDir.path))")
                } else {
                    print("")
                    print("Copying to: \(Paths.osImagesDir.path)")
                    do {
                        try FileManager.default.copyItem(at: sourceURL, to: destURL)
                        macOSImagePath = destURL.path
                        noora.success("Copied: \(destURL.lastPathComponent)")
                    } catch {
                        noora.warning("Could not copy file: \(error.localizedDescription)")
                        print("Using original location instead.")
                        macOSImagePath = expandedPath
                    }
                }

                // Lock the file (set immutable flag)
                print("")
                print("Locking the ISO file (required for SheepShaver)...")
                let lockResult = try? await ShellRunner.shared.run("chflags uchg \"\(macOSImagePath)\"")
                if lockResult?.succeeded == true {
                    noora.success("ISO file locked.")
                } else {
                    noora.warning("Could not lock file automatically.")
                    print("Please lock it manually: Get Info > Locked checkbox")
                }
            } else {
                noora.warning("File not found: \(cleanPath)")
                print("Please check the path and try again.")
                print("")
            }
        }

        // Step 3: Create hard disk image
        print("")
        print("-".repeated(60))
        print("STEP 3: CREATE HARD DISK IMAGE")
        print("-".repeated(60))
        print("")
        print("You need a blank disk image to install Mac OS onto.")
        print("Mac OS 9 needs more space than System 7.")
        print("")

        var hardDiskPath: String = ""
        let existingDisks = await diskManager.listDiskImages()

        if !existingDisks.isEmpty {
            print("Existing disk images found:")
            for disk in existingDisks {
                if let info = await diskManager.getDiskImageInfo(disk, for: .sheepshaver) {
                    print("  • \(info.name) (\(info.displaySize)) - \(disk.path)")
                }
            }
            print("")

            struct DiskChoice: CustomStringConvertible, Equatable {
                let label: String
                let path: String?
                var description: String { label }
            }

            var choices = existingDisks.map { disk -> DiskChoice in
                let name = disk.deletingPathExtension().lastPathComponent
                return DiskChoice(label: "Use: \(name)", path: disk.path)
            }
            choices.append(DiskChoice(label: "Create new disk image", path: nil))

            let choice = noora.singleChoicePrompt(
                title: "Disk",
                question: "Select a disk image:",
                options: choices,
                description: "Choose an existing disk or create a new one (recommended: 1GB)."
            )

            if let path = choice.path {
                hardDiskPath = path
                noora.success("Using: \(URL(fileURLWithPath: path).lastPathComponent)")
            } else {
                let newDisk = try await createDiskInteractive(noora: noora, diskManager: diskManager, recommendedSize: 1024)
                hardDiskPath = newDisk.path
            }
        } else {
            print("No disk images found. Let's create one.")
            print("")
            let newDisk = try await createDiskInteractive(noora: noora, diskManager: diskManager, recommendedSize: 1024)
            hardDiskPath = newDisk.path
        }

        // Step 4: Configure SheepShaver
        print("")
        print("-".repeated(60))
        print("STEP 4: CONFIGURE SHEEPSHAVER")
        print("-".repeated(60))
        print("")
        print("Now we'll configure SheepShaver for you.")
        print("")

        // RAM selection
        struct RAMOption: CustomStringConvertible, Equatable {
            let mb: Int
            var description: String {
                mb == 256 ? "\(mb) MB (recommended)" : "\(mb) MB"
            }
        }

        let ramOptions = [
            RAMOption(mb: 128),
            RAMOption(mb: 256),
            RAMOption(mb: 512)
        ]

        let selectedRAM = noora.singleChoicePrompt(
            title: "RAM",
            question: "How much RAM for the emulated Mac?",
            options: ramOptions,
            description: "Mac OS 9 benefits from more RAM."
        )

        // Screen size
        struct ScreenOption: CustomStringConvertible, Equatable {
            let width: Int
            let height: Int
            var description: String {
                let rec = (width == 800 && height == 600) ? " (recommended)" : ""
                return "\(width) x \(height)\(rec)"
            }
        }

        let screenOptions = [
            ScreenOption(width: 640, height: 480),
            ScreenOption(width: 800, height: 600),
            ScreenOption(width: 1024, height: 768)
        ]

        let selectedScreen = noora.singleChoicePrompt(
            title: "Screen",
            question: "Select screen resolution:",
            options: screenOptions,
            description: "The size of the emulator window."
        )

        // Shared folder setup
        print("")
        print("SHARED FOLDER")
        print("")
        print("A shared folder lets you easily transfer files between your Mac")
        print("and the emulated system. It appears as a 'Unix' disk on the desktop.")
        print("")
        print("This is how you'll copy your Retro68 builds into the emulator.")
        print("")

        var sharedFolderPath: String? = nil
        let setupShared = noora.yesOrNoChoicePrompt(
            title: "Shared",
            question: "Set up a shared folder?",
            defaultAnswer: true,
            description: "Recommended for transferring built apps."
        )

        if setupShared {
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
                .appendingPathComponent("SheepShaver Shared")
                .path

            print("")
            print("Default location: \(defaultPath)")
            print("")

            let customPath = noora.textPrompt(
                title: "Path",
                prompt: "Enter shared folder path (or press Enter for default):",
                description: "This folder will be accessible from within the emulator."
            )

            let finalPath = customPath.isEmpty ? defaultPath : NSString(string: customPath).expandingTildeInPath
            let folderURL = URL(fileURLWithPath: finalPath)

            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                sharedFolderPath = finalPath
                noora.success("Shared folder created: \(finalPath)")
            } catch {
                noora.warning("Could not create folder: \(error.localizedDescription)")
            }
        }

        // Generate and write preferences
        print("")
        print("Generating configuration...")

        let prefs = EmulatorManager.SheepShaverPrefs(
            romPath: romPath!.path,
            diskPaths: [macOSImagePath, hardDiskPath],
            sharedFolderPath: sharedFolderPath,
            ramSizeMB: selectedRAM.mb,
            screenWidth: selectedScreen.width,
            screenHeight: selectedScreen.height
        )

        try await manager.writeSheepShaverPrefs(prefs)

        // Save shared folder to config
        if let sharedPath = sharedFolderPath {
            var config = Configuration.load()
            var emuConfig = config.emulators ?? EmulatorConfiguration.default
            emuConfig.setSharedFolder(sharedPath, for: .sheepshaver)
            config.emulators = emuConfig
            try config.save()
        }

        print("")
        noora.success("Configuration saved!")
        print("")
        print("Settings:")
        print("  ROM:    \(romPath!.lastPathComponent)")
        print("  OS:     \(URL(fileURLWithPath: macOSImagePath).lastPathComponent)")
        print("  Disk:   \(URL(fileURLWithPath: hardDiskPath).lastPathComponent)")
        print("  RAM:    \(selectedRAM.mb) MB")
        print("  Screen: \(selectedScreen.width) x \(selectedScreen.height)")
        if let shared = sharedFolderPath {
            print("  Shared: \(shared)")
        }
        print("")

        _ = noora.yesOrNoChoicePrompt(
            title: "Continue",
            question: "Ready to boot SheepShaver for installation?",
            defaultAnswer: true,
            description: "Press Enter to continue."
        )

        // Step 5: Install Mac OS
        print("")
        print("-".repeated(60))
        print("STEP 5: INSTALL MAC OS 9")
        print("-".repeated(60))
        print("")
        print("Now we'll launch SheepShaver so you can install Mac OS 9.")
        print("")
        print("What to do when it starts:")
        print("")
        print("1. Your blank hard disk will appear as 'unreadable'")
        print("   • Click 'Initialize' when prompted")
        print("   • Name it (e.g., 'Macintosh HD')")
        print("   • Choose 'Mac OS Extended' format")
        print("")
        print("2. Install Mac OS 9:")
        print("   • Double-click 'Mac OS Install' on the CD")
        print("   • Follow the installation wizard")
        print("   • Select your newly initialized disk")
        print("")
        print("   IF INSTALLATION STALLS:")
        print("   • Cancel the installer")
        print("   • Restart the installer")
        print("   • Go to Options menu")
        print("   • UNCHECK 'Update Apple Hard Disk Drivers'")
        print("   • Try again")
        print("")
        print("3. When complete, click 'Quit' (NOT Restart!)")
        print("")

        let launchForInstall = noora.yesOrNoChoicePrompt(
            title: "Launch",
            question: "Launch SheepShaver now to install Mac OS 9?",
            defaultAnswer: true,
            description: "The emulator will open with the installer CD."
        )

        if launchForInstall {
            do {
                try await manager.launchEmulator(.sheepshaver)
                print("")
                noora.success("SheepShaver launched!")
                print("")
                print("Complete the installation as described above.")
                print("When finished, click 'Quit' in the installer (not Restart).")
            } catch {
                noora.warning("Could not launch: \(error.localizedDescription)")
                print("You can launch manually from /Applications/SheepShaver.app")
            }
        }

        print("")
        var installComplete = false
        while !installComplete {
            installComplete = noora.yesOrNoChoicePrompt(
                title: "Done",
                question: "Have you completed the Mac OS 9 installation?",
                defaultAnswer: false,
                description: "Make sure you clicked 'Quit', not 'Restart'."
            )
            if !installComplete {
                print("")
                print("Take your time! Complete the installation, then come back.")
                print("")
            }
        }

        // Step 6: Configure for normal boot
        print("")
        print("-".repeated(60))
        print("STEP 6: CONFIGURE FOR NORMAL BOOT")
        print("-".repeated(60))
        print("")
        print("Now that Mac OS is installed, we need to reconfigure SheepShaver")
        print("to boot from your hard disk instead of the installer.")
        print("")

        let updatePrefs = noora.yesOrNoChoicePrompt(
            title: "Update",
            question: "Remove the installer CD from configuration?",
            defaultAnswer: true,
            description: "This will make SheepShaver boot directly from your installed OS."
        )

        if updatePrefs {
            // Update prefs to only include the hard disk (not the installer)
            let bootPrefs = EmulatorManager.SheepShaverPrefs(
                romPath: romPath!.path,
                diskPaths: [hardDiskPath],  // Only the hard disk, not the installer
                sharedFolderPath: sharedFolderPath,
                ramSizeMB: selectedRAM.mb,
                screenWidth: selectedScreen.width,
                screenHeight: selectedScreen.height
            )

            do {
                try await manager.writeSheepShaverPrefs(bootPrefs)
                noora.success("Configuration updated!")
                print("")
                print("SheepShaver will now boot from: \(URL(fileURLWithPath: hardDiskPath).lastPathComponent)")
            } catch {
                noora.warning("Could not update configuration: \(error.localizedDescription)")
                print("You may need to manually edit: \(Paths.sheepshaverPrefs.path)")
            }
        } else {
            print("")
            print("To change disk configuration later, edit:")
            print("  \(Paths.sheepshaverPrefs.path)")
            print("")
            print("Remove the 'disk' line for the installer CD.")
        }

        print("")
        print("IMPORTANT: On first boot, the Mac OS Setup Assistant will launch.")
        print("           QUIT IT IMMEDIATELY (Cmd+Q) - it may freeze!")
        print("")

        _ = noora.yesOrNoChoicePrompt(
            title: "Continue",
            question: "Ready to launch SheepShaver?",
            defaultAnswer: true,
            description: "Press Enter to continue."
        )

        // Done!
        print("")
        print("=".repeated(60))
        noora.success("SETUP COMPLETE!")
        print("=".repeated(60))
        print("")
        print("Tips for using SheepShaver:")
        print("  • Always use 'Shut Down', never 'Restart'")
        print("  • Don't use the Startup Disk control panel")
        print("  • Copy apps to Mac HD before running them")
        print("")

        let launchNow = noora.yesOrNoChoicePrompt(
            title: "Launch",
            question: "Launch SheepShaver now?",
            defaultAnswer: true,
            description: "Start the emulator to verify everything works."
        )

        if launchNow {
            do {
                try await manager.launchEmulator(.sheepshaver)
                print("")
                noora.success("SheepShaver launched!")
                print("")
                print("Remember: Quit the Mac OS Setup Assistant immediately (Cmd+Q)")
            } catch {
                noora.warning("Could not launch: \(error.localizedDescription)")
            }
        }

        print("")
        print("Commands for later:")
        print("  retro68-setup emulator run       - Launch the emulator")
        print("  retro68-setup emulator disk copy - Copy apps to disk images")
        print("")
    }

    // MARK: - Helpers

    @discardableResult
    private func createDiskInteractive(noora: Noora, diskManager: DiskImageManager, recommendedSize: Int) async throws -> URL {
        let name = noora.textPrompt(
            title: "Disk Name",
            prompt: "Enter a name for the disk (default: Macintosh HD):",
            description: "This will be the volume name."
        )
        let diskName = name.isEmpty ? "Macintosh HD" : name

        struct SizeOption: CustomStringConvertible, Equatable {
            let size: Int
            let label: String
            let recommended: Bool
            var description: String {
                recommended ? "\(label) (recommended)" : label
            }
        }

        let sizeOptions = [
            SizeOption(size: 500, label: "500 MB", recommended: recommendedSize == 500),
            SizeOption(size: 1024, label: "1 GB", recommended: recommendedSize == 1024),
            SizeOption(size: 2048, label: "2 GB", recommended: false)
        ]

        let selectedSize = noora.singleChoicePrompt(
            title: "Size",
            question: "Select disk image size:",
            options: sizeOptions,
            description: "Larger disks can hold more applications."
        )

        print("")
        print("Creating disk image...")

        let path = try await diskManager.createDiskImage(name: diskName, sizeMB: selectedSize.size, for: .basilisk)
        print("")
        noora.success("Disk image created: \(path.lastPathComponent)")
        print("  Location: \(path.path)")

        return path
    }
}

// MARK: - Run Command

struct EmulatorRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Launch an emulator"
    )

    @Option(name: .shortAndLong, help: "Emulator to run (basilisk or sheepshaver)")
    var emulator: String?

    func run() async throws {
        let noora = Noora()
        let manager = EmulatorManager()

        print("")
        print("Launch Emulator")
        print("===============")
        print("")

        // Check which emulators are installed
        let basiliskInstalled = await manager.isEmulatorInstalled(.basilisk)
        let sheepshaverInstalled = await manager.isEmulatorInstalled(.sheepshaver)

        if !basiliskInstalled && !sheepshaverInstalled {
            noora.error("No emulators installed.")
            print("Run 'retro68-setup emulator install' first.")
            throw ExitCode.failure
        }

        // Determine which emulator to run
        let selectedEmulator: EmulatorType

        if let specified = emulator {
            switch specified.lowercased() {
            case "basilisk", "basiliskii", "68k":
                selectedEmulator = .basilisk
            case "sheepshaver", "ppc", "powerpc":
                selectedEmulator = .sheepshaver
            default:
                noora.error("Unknown emulator: \(specified)")
                print("Use 'basilisk' or 'sheepshaver'")
                throw ExitCode.failure
            }

            let isInstalled = selectedEmulator == .basilisk ? basiliskInstalled : sheepshaverInstalled
            if !isInstalled {
                noora.error("\(selectedEmulator.displayName) is not installed.")
                throw ExitCode.failure
            }
        } else if basiliskInstalled && sheepshaverInstalled {
            // Both installed, let user choose
            struct EmuOption: CustomStringConvertible, Equatable {
                let emulator: EmulatorType
                var description: String { emulator.displayName }
            }

            let options = EmulatorType.allCases.map { EmuOption(emulator: $0) }
            let selected = noora.singleChoicePrompt(
                title: "Emulator",
                question: "Which emulator would you like to run?",
                options: options,
                description: "Select the emulator to launch."
            )
            selectedEmulator = selected.emulator
        } else {
            // Only one installed
            selectedEmulator = basiliskInstalled ? .basilisk : .sheepshaver
        }

        // Check for ROM
        let romPath = await manager.findRomFile(for: selectedEmulator)
        if romPath == nil {
            noora.warning("No ROM file found for \(selectedEmulator.displayName)")
            print("")
            print("The emulator may not start without a ROM file.")
            print("Place your ROM in: \(Paths.romDir.path)")
            print("")
        }

        // Launch
        print("Launching \(selectedEmulator.displayName)...")

        do {
            try await manager.launchEmulator(selectedEmulator)
            print("")
            noora.success("\(selectedEmulator.displayName) launched!")
            print("")
            print("Tips:")
            print("- To quit, use the emulator's Quit menu or Cmd+Q")
            print("- Use 'retro68-setup emulator disk copy' to add apps to disk images")
            print("")
        } catch {
            noora.error("Failed to launch emulator: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Disk Command

struct EmulatorDiskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk",
        abstract: "Manage disk images",
        subcommands: [
            DiskCreateCommand.self,
            DiskListCommand.self,
            DiskCopyCommand.self,
            DiskDeleteCommand.self,
        ],
        defaultSubcommand: DiskListCommand.self
    )
}

struct DiskCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new disk image"
    )

    @Option(name: .shortAndLong, help: "Name for the disk image")
    var name: String?

    @Option(name: .shortAndLong, help: "Size in MB")
    var size: Int?

    func run() async throws {
        let noora = Noora()
        let diskManager = DiskImageManager()

        print("")
        print("Create Disk Image")
        print("=================")
        print("")

        let diskName: String
        if let n = name {
            diskName = n
        } else {
            let input = noora.textPrompt(
                title: "Name",
                prompt: "Enter a name for the disk image (default: MacOS):",
                description: "This will be the volume name."
            )
            diskName = input.isEmpty ? "MacOS" : input
        }

        let diskSize: Int
        if let s = size {
            diskSize = s
        } else {
            struct SizeOption: CustomStringConvertible, Equatable {
                let size: Int
                let label: String
                var description: String { label }
            }

            let options = [
                SizeOption(size: 100, label: "100 MB"),
                SizeOption(size: 500, label: "500 MB (recommended)"),
                SizeOption(size: 1024, label: "1 GB"),
                SizeOption(size: 2048, label: "2 GB")
            ]

            let selected = noora.singleChoicePrompt(
                title: "Size",
                question: "Select disk image size:",
                options: options,
                description: "HFS supports up to 2GB."
            )
            diskSize = selected.size
        }

        print("")
        print("Creating \(diskSize) MB disk image named '\(diskName)'...")

        do {
            let path = try await diskManager.createDiskImage(name: diskName, sizeMB: diskSize, for: .basilisk)
            print("")
            noora.success("Disk image created!")
            print("  Path: \(path.path)")
            print("")
            print("Next steps:")
            print("1. Boot an emulator with Mac OS installation media")
            print("2. Initialize and format the disk in Drive Setup")
            print("3. Install Mac OS onto the disk")
        } catch {
            noora.error("Failed to create disk image: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct DiskListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List disk images"
    )

    func run() async throws {
        let diskManager = DiskImageManager()

        print("")
        print("Disk Images")
        print("===========")
        print("")
        print("Location: \(Paths.diskImagesDir.path)")
        print("")

        let disks = await diskManager.listDiskImages()

        if disks.isEmpty {
            print("No disk images found.")
            print("")
            print("Create one with: retro68-setup emulator disk create")
            return
        }

        for disk in disks {
            if let info = await diskManager.getDiskImageInfo(disk, for: .basilisk) {
                print("  \(info.name)")
                print("    Size: \(info.displaySize)")
                print("    Path: \(info.path)")

                // Check if mounted
                if let mount = await diskManager.getMountPoint(for: disk) {
                    print("    Status: Mounted at \(mount.mountPoint.path)")
                } else {
                    print("    Status: Not mounted")
                }
                print("")
            }
        }
    }
}

struct DiskCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy a built app to a disk image"
    )

    @Argument(help: "Path to the file or app to copy")
    var source: String?

    @Option(name: .shortAndLong, help: "Target disk image")
    var disk: String?

    func run() async throws {
        let noora = Noora()
        let diskManager = DiskImageManager()

        print("")
        print("Copy to Disk Image")
        print("==================")
        print("")

        // Get source file
        let sourcePath: URL
        if let src = source {
            sourcePath = URL(fileURLWithPath: src)
        } else {
            // List built apps
            print("Looking for built applications...")
            print("")

            var allApps: [(URL, BuildTarget)] = []
            for target in BuildTarget.allCases {
                let apps = await diskManager.findBuiltApps(for: target)
                for app in apps {
                    allApps.append((app, target))
                }
            }

            if allApps.isEmpty {
                noora.warning("No built applications found.")
                print("Build some samples first with: retro68-setup build")
                print("")
                print("Or specify a path directly:")
                print("  retro68-setup emulator disk copy /path/to/app.bin")
                throw ExitCode.failure
            }

            struct AppOption: CustomStringConvertible, Equatable {
                let url: URL
                let target: BuildTarget
                var description: String { "\(url.lastPathComponent) (\(target.rawValue))" }
            }

            let options = allApps.map { AppOption(url: $0.0, target: $0.1) }
            let selected = noora.singleChoicePrompt(
                title: "App",
                question: "Select an application to copy:",
                options: options,
                description: "Choose from built samples."
            )
            sourcePath = selected.url
        }

        guard Paths.exists(sourcePath) else {
            noora.error("Source file not found: \(sourcePath.path)")
            throw ExitCode.failure
        }

        // Get target disk
        let targetDisk: URL
        if let d = disk {
            targetDisk = URL(fileURLWithPath: d)
        } else {
            let disks = await diskManager.listDiskImages()

            if disks.isEmpty {
                noora.error("No disk images found.")
                print("Create one with: retro68-setup emulator disk create")
                throw ExitCode.failure
            }

            struct DiskOption: CustomStringConvertible, Equatable {
                let url: URL
                var description: String { url.lastPathComponent }
            }

            let options = disks.map { DiskOption(url: $0) }
            let selected = noora.singleChoicePrompt(
                title: "Disk",
                question: "Select target disk image:",
                options: options,
                description: "The disk will be mounted temporarily."
            )
            targetDisk = selected.url
        }

        print("")
        print("Copying \(sourcePath.lastPathComponent) to \(targetDisk.lastPathComponent)...")

        do {
            try await diskManager.copyToImage(sourcePath, imagePath: targetDisk)
            print("")
            noora.success("File copied successfully!")
            print("")

            // List contents
            let contents = try await diskManager.listContents(targetDisk)
            print("Disk contents:")
            for line in contents.prefix(10) {
                print("  \(line)")
            }

            // Unmount
            print("")
            print("Unmounting disk...")
            try await diskManager.unmount(targetDisk)
            noora.success("Disk unmounted.")

        } catch {
            noora.error("Failed to copy: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct DiskDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a disk image"
    )

    @Argument(help: "Name or path of disk image to delete")
    var disk: String?

    func run() async throws {
        let noora = Noora()
        let diskManager = DiskImageManager()

        print("")
        print("Delete Disk Image")
        print("=================")
        print("")

        let disks = await diskManager.listDiskImages()

        if disks.isEmpty {
            print("No disk images to delete.")
            return
        }

        let targetDisk: URL
        if let d = disk {
            // Check if it's a name or path
            if d.contains("/") {
                targetDisk = URL(fileURLWithPath: d)
            } else {
                // Search by name
                if let found = disks.first(where: { $0.lastPathComponent.contains(d) }) {
                    targetDisk = found
                } else {
                    noora.error("Disk image not found: \(d)")
                    throw ExitCode.failure
                }
            }
        } else {
            struct DiskOption: CustomStringConvertible, Equatable {
                let url: URL
                var description: String { url.lastPathComponent }
            }

            let options = disks.map { DiskOption(url: $0) }
            let selected = noora.singleChoicePrompt(
                title: "Disk",
                question: "Select disk image to delete:",
                options: options,
                description: "This cannot be undone!"
            )
            targetDisk = selected.url
        }

        let confirm = noora.yesOrNoChoicePrompt(
            title: "Confirm",
            question: "Delete \(targetDisk.lastPathComponent)?",
            defaultAnswer: false,
            description: "This will permanently delete the disk image and all its contents."
        )

        if !confirm {
            print("Deletion cancelled.")
            return
        }

        do {
            try await diskManager.deleteDiskImage(targetDisk)
            noora.success("Disk image deleted.")
        } catch {
            noora.error("Failed to delete: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Status Command

struct EmulatorStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show emulator installation status"
    )

    func run() async throws {
        let manager = EmulatorManager()
        let diskManager = DiskImageManager()

        // Ensure directories exist
        try await manager.ensureDirectoriesExist()

        print("")
        print("Emulator Status")
        print("===============")
        print("")

        // Check installations
        let basiliskInstalled = await manager.isEmulatorInstalled(.basilisk)
        let sheepshaverInstalled = await manager.isEmulatorInstalled(.sheepshaver)

        print("Emulators:")
        print("  BasiliskII:  \(basiliskInstalled ? "Installed" : "Not installed")")
        print("  SheepShaver: \(sheepshaverInstalled ? "Installed" : "Not installed")")
        print("")

        // Check ROMs
        print("ROM Files:")
        for emulator in EmulatorType.allCases {
            let romPath = await manager.findRomFile(for: emulator)
            if let rom = romPath {
                print("  \(emulator.displayName): \(rom.lastPathComponent)")
            } else {
                print("  \(emulator.displayName): Not found")
            }
        }
        print("")
        print("  Place ROM files in: \(Paths.romDir.path)")
        print("")

        // Check disk images
        let disks = await diskManager.listDiskImages()
        print("Disk Images: \(disks.count) found")
        if !disks.isEmpty {
            for disk in disks {
                if let info = await diskManager.getDiskImageInfo(disk, for: .basilisk) {
                    print("  - \(info.name) (\(info.displaySize))")
                }
            }
        }
        print("")
        print("  Disk images location: \(Paths.diskImagesDir.path)")
        print("")

        // Check shared folders
        let config = Configuration.load()
        let emuConfig = config.emulators

        print("Shared Folders:")
        if let basiliskShared = emuConfig?.basiliskSharedFolder {
            print("  BasiliskII:  \(basiliskShared)")
        } else {
            print("  BasiliskII:  Not configured")
        }
        if let sheepshaverShared = emuConfig?.sheepshaverSharedFolder {
            print("  SheepShaver: \(sheepshaverShared)")
        } else {
            print("  SheepShaver: Not configured")
        }
        print("")
        print("  Shared folders appear as 'Unix' disk on the emulated desktop.")
        print("  Build artifacts are automatically copied here after building.")
        print("")

        // Show next steps based on status
        if !basiliskInstalled && !sheepshaverInstalled {
            print("Get started:")
            print("  retro68-setup emulator install  - Install emulators")
        } else {
            print("Commands:")
            print("  retro68-setup emulator guide    - Setup wizard (configure shared folder)")
            print("  retro68-setup emulator run      - Launch an emulator")
            print("  retro68-setup emulator disk     - Manage disk images")
        }
        print("")
    }
}

// MARK: - Helpers

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
