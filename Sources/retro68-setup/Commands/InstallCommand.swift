import ArgumentParser
import Foundation
import Noora

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Retro68 toolchain"
    )

    @Flag(name: .long, help: "Skip dependency checks")
    var skipDeps: Bool = false

    @Flag(name: .long, help: "Skip cloning the repository (use existing)")
    var skipClone: Bool = false

    @Flag(name: .long, help: "Rebuild only Retro68-specific code, not GCC/binutils")
    var rebuildOnly: Bool = false

    func run() async throws {
        let noora = Noora()

        print("")
        print("Retro68 Toolchain Installer")
        print("===========================")
        print("")
        print("This will install the Retro68 toolchain for classic Mac development.")
        print("Installation location: \(Paths.retro68Root.path)")
        print("")

        // Check if already installed
        let config = Configuration.load()
        if config.isInstalled && !rebuildOnly {
            let proceed = noora.yesOrNoChoicePrompt(
                title: "Already Installed",
                question: "Retro68 appears to be already installed. Do you want to reinstall?",
                defaultAnswer: false,
                description: "This will rebuild the toolchain from scratch."
            )

            if !proceed {
                print("Installation cancelled.")
                return
            }
        }

        // Step 1: Check dependencies
        if !skipDeps {
            try await checkDependencies(noora: noora)
        }

        // Step 2: Clone repository
        if !skipClone {
            try await cloneRepository(noora: noora)
        }

        // Step 3: Select build targets
        let targets = try selectBuildTargets(noora: noora)

        if targets.isEmpty {
            noora.error("No targets selected. You must select at least one build target.")
            return
        }

        // Step 4: Ask about Universal Interfaces BEFORE building
        try await configureInterfacesPreBuild(noora: noora)

        // Step 5: Build toolchain
        try await buildToolchain(noora: noora, targets: targets, rebuildOnly: rebuildOnly)

        // Step 6: Save configuration
        var newConfig = Configuration.load()
        newConfig.installedAt = Date()
        newConfig.buildTargets = targets
        try newConfig.save()

        // Success!
        print("")
        noora.success("Retro68 toolchain has been installed successfully!")

        print("")
        print("Next steps:")
        print("-----------")
        print("1. Build a sample: retro68-setup build")
        print("2. Check status:   retro68-setup status")
        print("3. Add interfaces: retro68-setup interfaces add")
        print("")
    }

    private func checkDependencies(noora: Noora) async throws {
        print("Checking dependencies...")

        let checker = DependencyChecker()

        // First check Homebrew
        print("  Checking Homebrew...", terminator: "")
        fflush(stdout)
        let hasHomebrew = await checker.checkHomebrew()
        if !hasHomebrew {
            print(" not found")
            noora.error("Homebrew is required but not installed. Please install it from https://brew.sh")
            throw ExitCode.failure
        }
        print(" OK")

        print("  Checking packages...", terminator: "")
        fflush(stdout)
        let missing = await checker.getMissingDependencies()
        print(" done")
        print("")

        if missing.isEmpty {
            noora.success("All required dependencies are installed.")
            return
        }

        print("Missing dependencies:")
        for dep in missing {
            print("  - \(dep.name) (\(dep.brewPackage))")
        }
        print("")

        let install = noora.yesOrNoChoicePrompt(
            title: "Install Dependencies",
            question: "Would you like to install the missing dependencies via Homebrew?",
            defaultAnswer: true,
            description: "This will run: brew install \(missing.map(\.brewPackage).joined(separator: " "))"
        )

        if !install {
            noora.warning("Please install the missing dependencies manually and run the installer again.")
            throw ExitCode.failure
        }

        print("")
        print("Installing dependencies...")

        do {
            try await noora.progressStep(
                message: "Installing dependencies via Homebrew",
                successMessage: "Dependencies installed",
                errorMessage: "Failed to install dependencies",
                showSpinner: true
            ) { _ in
                try await checker.installMissingDependencies(missing)
            }
        } catch {
            noora.error("Failed to install dependencies: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("")
    }

    private func cloneRepository(noora: Noora) async throws {
        let builder = ToolchainBuilder()

        if builder.isRepositoryCloned() {
            print("Repository already exists at \(Paths.sourceDir.path)")

            let update = noora.yesOrNoChoicePrompt(
                title: "Update Repository",
                question: "Would you like to update the existing repository?",
                defaultAnswer: true,
                description: "This will run 'git pull' and update submodules."
            )

            if !update {
                return
            }
        }

        print("")
        print("Cloning Retro68 repository...")
        print("")

        do {
            try await builder.cloneRepository { output in
                print(output, terminator: "")
            }
            print("")
            noora.success("Retro68 repository is ready.")
        } catch {
            noora.error("Failed to clone repository: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("")
    }

    private func selectBuildTargets(noora: Noora) throws -> [BuildTarget] {
        print("")
        print("Select Build Targets")
        print("--------------------")
        print("Choose which platforms you want to build for.")
        print("You can add more targets later with: retro68-setup install --rebuild-only")
        print("")

        struct TargetOption: CustomStringConvertible, Equatable {
            let target: BuildTarget
            var description: String { target.displayName }
        }

        let options = BuildTarget.allCases.map { TargetOption(target: $0) }

        let selected = noora.multipleChoicePrompt(
            title: "Build Targets",
            question: "Which platforms do you want to target?",
            options: options,
            description: "Press SPACE to select, ENTER to confirm. You can add more later.",
            minLimit: .limited(count: 1, errorMessage: "You must select at least one target")
        )

        return selected.map { $0.target }
    }

    private func configureInterfacesPreBuild(noora: Noora) async throws {
        print("")
        print("Universal Interfaces")
        print("--------------------")
        print("")

        // Check if Apple interfaces are already in place
        let interfacesPath = Paths.sourceDir.appendingPathComponent("InterfacesAndLibraries")
        let existingVersion = detectAppleInterfacesVersion(at: interfacesPath)

        if let version = existingVersion {
            noora.success("Apple Universal Interfaces \(version) detected!")
            print("  Location: \(interfacesPath.path)")
            print("")
            return
        }

        print("Retro68 needs API headers and libraries to compile Mac programs.")
        print("You have two options:")
        print("")
        print("  1. Apple Universal Interfaces (recommended)")
        print("     Full API coverage for all classic Mac development")
        print("     Requires downloading MPW (Macintosh Programmer's Workshop)")
        print("")
        print("  2. Multiversal Interfaces")
        print("     Open-source, included with Retro68")
        print("     Limitation: No Carbon, MacTCP, OpenTransport, or post-System 7 APIs")
        print("")

        let useApple = noora.yesOrNoChoicePrompt(
            title: "Interfaces",
            question: "Do you want to use Apple Universal Interfaces?",
            defaultAnswer: true,
            description: "Recommended for full compatibility. Select No for open-source Multiversal."
        )

        if !useApple {
            print("")
            print("Using Multiversal Interfaces (open-source).")
            print("You can add Apple interfaces later with: retro68-setup interfaces add")
            print("")
            return
        }

        // User wants Apple interfaces - guide them through setup
        print("")
        print("Apple Universal Interfaces Setup")
        print("---------------------------------")
        print("")
        print("To use Apple's interfaces, you need to:")
        print("")
        print("  1. Download MPW (Macintosh Programmer's Workshop) Golden Master")
        print("     - Search for 'MPW-GM.img.bin' or 'mpw-gm.img_.bin'")
        print("     - Common sources: Archive.org, Macintosh Garden")
        print("")
        print("  2. Extract the disk image and find 'Interfaces&Libraries' folder")
        print("     - On modern macOS, you may need an emulator to mount old disk images")
        print("     - The folder should contain: Interfaces/, Libraries/, etc.")
        print("")
        print("  3. Copy/move the contents to:")
        print("     \(interfacesPath.path)")
        print("")
        print("  Tip: You can do this now in another terminal window.")
        print("")

        let ready = noora.yesOrNoChoicePrompt(
            title: "Ready",
            question: "Have you placed the InterfacesAndLibraries contents in the location above?",
            defaultAnswer: true,
            description: "Select No to continue with Multiversal for now."
        )

        if ready {
            // Check again for version
            if let version = detectAppleInterfacesVersion(at: interfacesPath) {
                noora.success("Apple Universal Interfaces \(version) detected!")
                print("")
            } else if Paths.exists(interfacesPath) {
                // Folder exists but couldn't detect version
                noora.success("InterfacesAndLibraries folder detected!")
                print("  (Could not determine version)")
                print("")
            } else {
                noora.warning("Folder not found at expected location. Continuing with Multiversal.")
                print("You can add Apple interfaces later with: retro68-setup interfaces add")
                print("")
            }
        } else {
            print("")
            print("Continuing with Multiversal Interfaces.")
            print("You can add Apple interfaces later with: retro68-setup interfaces add")
            print("")
        }
    }

    /// Detects the version of Apple Universal Interfaces by parsing MacTypes.h
    private func detectAppleInterfacesVersion(at path: URL) -> String? {
        // Try common locations for MacTypes.h
        let possiblePaths = [
            path.appendingPathComponent("Interfaces/CIncludes/MacTypes.h"),
            path.appendingPathComponent("CIncludes/MacTypes.h"),
            path.appendingPathComponent("Interfaces/MacTypes.h")
        ]

        for macTypesPath in possiblePaths {
            guard let content = try? String(contentsOf: macTypesPath, encoding: .utf8) else {
                continue
            }

            // Look for: "Release:    Universal Interfaces 3.4"
            if let range = content.range(of: "Universal Interfaces ") {
                let startIndex = range.upperBound
                let endIndex = content[startIndex...].firstIndex(where: { $0.isNewline || $0 == "*" }) ?? content.endIndex
                let version = String(content[startIndex..<endIndex]).trimmingCharacters(in: .whitespaces)
                if !version.isEmpty {
                    return version
                }
            }
        }

        return nil
    }

    private func buildToolchain(noora: Noora, targets: [BuildTarget], rebuildOnly: Bool) async throws {
        print("")
        print("Building Retro68 Toolchain")
        print("--------------------------")

        if rebuildOnly {
            print("Rebuilding Retro68-specific components only (skipping GCC/binutils)...")
        } else {
            print("The build includes GCC, binutils, and all Retro68 components.")
        }

        print("")
        print("Building for: \(targets.map(\.displayName).joined(separator: ", "))")
        print("")

        let proceed = noora.yesOrNoChoicePrompt(
            title: "Start Build",
            question: "Ready to start the build?",
            defaultAnswer: true,
            description: "You can safely cancel with Ctrl+C and resume later with --skip-clone."
        )

        if !proceed {
            print("Build cancelled.")
            throw ExitCode.failure
        }

        print("")
        print("Build output:")
        print("=============")
        print("")

        let builder = ToolchainBuilder()

        do {
            try await builder.buildToolchain(targets: targets, skipThirdParty: rebuildOnly) { output in
                print(output, terminator: "")
            }
        } catch {
            print("")
            noora.error("Toolchain build failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("")
        noora.success("Toolchain built successfully!")
    }
}
