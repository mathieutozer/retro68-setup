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
        let command = "\(buildScript) \(buildArgs.joined(separator: " "))"

        onOutput("Starting toolchain build...\n")
        onOutput("Command: \(command)\n\n")

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
}
