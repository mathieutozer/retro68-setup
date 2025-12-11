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

        // Step 4: Build toolchain
        try await buildToolchain(noora: noora, targets: targets, rebuildOnly: rebuildOnly)

        // Step 5: Save configuration
        var newConfig = Configuration.load()
        newConfig.installedAt = Date()
        newConfig.buildTargets = targets
        try newConfig.save()

        // Step 6: Offer to configure interfaces
        print("")
        let configureInterfaces = noora.yesOrNoChoicePrompt(
            title: "Universal Interfaces",
            question: "Would you like to configure Universal Interfaces now?",
            defaultAnswer: false,
            description: "You can use the default Multiversal interfaces or add Apple's Universal Interfaces for better compatibility."
        )

        if configureInterfaces {
            print("")
            print(InterfaceManager.multiversalInfo)
            print("")
            print(InterfaceManager.appleInterfacesInfo)
            print("")
            print("Run 'retro68-setup interfaces add' when you have the files ready.")
        }

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
        print("This may take several minutes depending on your connection.")
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

    private func buildToolchain(noora: Noora, targets: [BuildTarget], rebuildOnly: Bool) async throws {
        print("")
        print("Building Retro68 Toolchain")
        print("--------------------------")

        if rebuildOnly {
            print("Rebuilding Retro68-specific components only (skipping GCC/binutils)...")
        } else {
            print("This will take a LONG time (potentially 1-2 hours or more).")
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
