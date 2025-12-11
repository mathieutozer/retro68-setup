import Foundation

actor ToolchainBuilder {
    private let shell = ShellRunner.shared

    func cloneRepository(onOutput: @escaping @Sendable (String) -> Void) async throws {
        try Paths.ensureDirectoryExists(Paths.retro68Root)

        if Paths.exists(Paths.sourceDir) {
            onOutput("Repository already exists, updating...\n")
            _ = try await shell.runStreaming(
                "git pull && git submodule update --init",
                at: Paths.sourceDir,
                onOutput: onOutput
            )
        } else {
            onOutput("Cloning Retro68 repository (this may take a while)...\n")
            let exitCode = try await shell.runStreaming(
                "git clone --recursive \(Paths.gitRepoURL) Retro68",
                at: Paths.retro68Root,
                onOutput: onOutput
            )
            if exitCode != 0 {
                throw ShellError.commandFailed(command: "git clone", exitCode: exitCode, stderr: "Failed to clone repository")
            }
        }
    }

    func buildToolchain(
        targets: [BuildTarget],
        skipThirdParty: Bool = false,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        try Paths.ensureDirectoryExists(Paths.buildDir)

        // Patch CMakeLists.txt files to fix Boost 1.69+ compatibility
        // boost::system became header-only, so we remove it from find_package calls
        // See: https://github.com/autc04/Retro68/issues/301
        onOutput("Applying Boost compatibility patches...\n")
        try applyBoostPatches()

        // Patch sample CMakeLists.txt files to add cmake_minimum_required
        // CMake 3.12+ requires this at the top of standalone CMakeLists.txt files
        onOutput("Applying sample CMakeLists.txt patches...\n")
        try applySamplePatches()
        onOutput("Patches applied.\n")

        // Create cmake initial cache to force correct bison path
        // macOS ships with bison 2.3 but Retro68 needs 3.0.2+
        onOutput("Configuring CMake for Homebrew bison...\n")
        try createCMakeInitialCache()
        onOutput("CMake configured.\n\n")

        var buildArgs: [String] = []

        let allTargets = Set(BuildTarget.allCases)
        let selectedTargets = Set(targets)
        let skippedTargets = allTargets.subtracting(selectedTargets)

        for target in skippedTargets {
            buildArgs.append(target.skipFlag)
        }

        if skipThirdParty {
            buildArgs.append("--skip-thirdparty")
        }

        let buildScript = Paths.sourceDir.appendingPathComponent("build-toolchain.bash").path
        let buildArgsStr = buildArgs.joined(separator: " ")

        // Set environment variables and PATH to fix various build issues on macOS/Homebrew:
        // 1. Boost 1.69+ made boost::system header-only - use legacy FindBoost module
        // 2. macOS bundles old bison 2.3, but we need 3.0.2+ from Homebrew
        //    CMake needs BISON_EXECUTABLE set explicitly since it doesn't use PATH
        // 3. Similarly for other Homebrew tools that may shadow system versions
        let homebrewBisonDir = "/opt/homebrew/opt/bison/bin"
        let homebrewBison = "\(homebrewBisonDir)/bison"
        let command = """
            export PATH="\(homebrewBisonDir):/opt/homebrew/bin:$PATH" && \
            export BISON_EXECUTABLE="\(homebrewBison)" && \
            export CMAKE_PROGRAM_PATH="\(homebrewBisonDir):/opt/homebrew/bin" && \
            export Boost_NO_BOOST_CMAKE=ON && \
            export BOOST_ROOT=/opt/homebrew && \
            export CMAKE_PREFIX_PATH=/opt/homebrew && \
            echo "DEBUG: Using bison at $BISON_EXECUTABLE" && \
            $BISON_EXECUTABLE --version | head -1 && \
            \(buildScript) \(buildArgsStr)
            """

        onOutput("Starting toolchain build...\n")
        onOutput("Build flags: \(buildArgsStr.isEmpty ? "(none)" : buildArgsStr)\n")
        onOutput("Boost workaround: Boost_NO_BOOST_CMAKE=ON\n\n")

        let exitCode = try await shell.runStreaming(
            command,
            at: Paths.buildDir,
            onOutput: onOutput
        )

        if exitCode != 0 {
            throw ShellError.commandFailed(command: "build-toolchain.bash", exitCode: exitCode, stderr: "Build failed")
        }
    }

    func rebuildRetro68Only(onOutput: @escaping @Sendable (String) -> Void) async throws {
        let config = Configuration.load()
        try await buildToolchain(targets: config.buildTargets, skipThirdParty: true, onOutput: onOutput)
    }

    nonisolated func isRepositoryCloned() -> Bool {
        Paths.exists(Paths.sourceDir.appendingPathComponent(".git"))
    }

    nonisolated func isToolchainBuilt() -> Bool {
        Paths.exists(Paths.toolchainDir.appendingPathComponent("bin"))
    }

    /// Patches the build-toolchain.bash script to use Homebrew's bison
    /// macOS ships with bison 2.3 but Retro68 needs 3.0.2+
    nonisolated private func createCMakeInitialCache() throws {
        let homebrewBison = "/opt/homebrew/opt/bison/bin/bison"

        // Verify Homebrew bison exists
        guard Paths.exists(URL(fileURLWithPath: homebrewBison)) else {
            return
        }

        // Patch the build-toolchain.bash to add -DBISON_EXECUTABLE to cmake calls
        let scriptPath = Paths.sourceDir.appendingPathComponent("build-toolchain.bash")
        guard Paths.exists(scriptPath) else { return }

        var content = try String(contentsOf: scriptPath, encoding: .utf8)
        let originalContent = content

        // Add BISON_EXECUTABLE to the cmake invocation for host tools (line ~326)
        // Original: cmake ${SRC} -DCMAKE_INSTALL_PREFIX=$PREFIX ...
        // Modified: cmake ${SRC} -DCMAKE_INSTALL_PREFIX=$PREFIX -DBISON_EXECUTABLE=... ...

        let bisonFlag = "-DBISON_EXECUTABLE=\(homebrewBison)"

        // Only patch if not already patched
        if !content.contains("BISON_EXECUTABLE") {
            // Find the cmake call for host tools and add the bison flag
            content = content.replacingOccurrences(
                of: "cmake ${SRC} -DCMAKE_INSTALL_PREFIX=$PREFIX",
                with: "cmake ${SRC} -DCMAKE_INSTALL_PREFIX=$PREFIX \(bisonFlag)"
            )
        }

        if content != originalContent {
            try content.write(to: scriptPath, atomically: true, encoding: .utf8)
        }
    }

    /// Patches sample CMakeLists.txt files to add cmake_minimum_required
    /// CMake 3.12+ requires this at the top of standalone CMakeLists.txt files
    nonisolated private func applySamplePatches() throws {
        let samplesDir = Paths.sourceDir.appendingPathComponent("Samples")
        let samples = [
            "Dialog",
            "HelloWorld",
            "Launcher",
            "MPWTool",
            "Raytracer",
            "SharedLibrary",
            "SystemExtension",
            "WDEF"
        ]

        let cmakeMinRequired = "cmake_minimum_required(VERSION 3.9)\n"

        for sample in samples {
            let filePath = samplesDir
                .appendingPathComponent(sample)
                .appendingPathComponent("CMakeLists.txt")

            guard Paths.exists(filePath) else {
                continue
            }

            var content = try String(contentsOf: filePath, encoding: .utf8)

            // Only add if not already present
            if !content.contains("cmake_minimum_required") {
                content = cmakeMinRequired + content
                try content.write(to: filePath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Patches CMakeLists.txt files to fix Boost 1.69+ compatibility
    /// boost::system became header-only, so we remove it from find_package calls
    nonisolated private func applyBoostPatches() throws {
        let filesToPatch = [
            "ResourceFiles/CMakeLists.txt",
            "PEFTools/CMakeLists.txt",
            "Rez/CMakeLists.txt",
            "ConvertObj/CMakeLists.txt",
            "LaunchAPPL/CMakeLists.txt"
        ]

        for relativePath in filesToPatch {
            let filePath = Paths.sourceDir.appendingPathComponent(relativePath)

            guard Paths.exists(filePath) else {
                continue
            }

            var content = try String(contentsOf: filePath, encoding: .utf8)
            let originalContent = content

            // Remove 'system' from Boost component lists
            // Handles patterns like: find_package(Boost COMPONENTS filesystem system)
            // Also handles: find_package(Boost ... COMPONENTS wave filesystem system thread ...)

            // Pattern 1: "filesystem system" -> "filesystem"
            content = content.replacingOccurrences(of: "filesystem system", with: "filesystem")

            // Pattern 2: "system filesystem" -> "filesystem"
            content = content.replacingOccurrences(of: "system filesystem", with: "filesystem")

            // Pattern 3: standalone " system " in component list -> " "
            content = content.replacingOccurrences(of: " system ", with: " ")

            // Pattern 4: "system)" at end of component list -> ")"
            content = content.replacingOccurrences(of: " system)", with: ")")

            // Pattern 5: Boost::system in target_link_libraries
            content = content.replacingOccurrences(of: "Boost::system", with: "")

            // Clean up any double spaces we might have created
            while content.contains("  ") {
                content = content.replacingOccurrences(of: "  ", with: " ")
            }

            // Only write if we made changes
            if content != originalContent {
                try content.write(to: filePath, atomically: true, encoding: .utf8)
            }
        }
    }
}
