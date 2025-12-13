import ArgumentParser
import Foundation
import Noora

struct SampleProject: CustomStringConvertible, Equatable {
    let name: String
    let path: URL

    var description: String { name }
}

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build sample applications"
    )

    @Argument(help: "Sample project name (optional, will prompt if not provided)")
    var project: String?

    @Option(name: .shortAndLong, help: "Target platform (68k, powerpc, carbon)")
    var target: String?

    @Flag(name: .long, help: "Clean build directory before building")
    var clean: Bool = false

    func run() async throws {
        let noora = Noora()
        let shell = ShellRunner.shared
        let config = Configuration.load()

        // Check installation
        guard config.isInstalled else {
            noora.error("Retro68 is not installed. Run 'retro68-setup install' first.")
            return
        }

        print("")
        print("Build Sample Application")
        print("========================")
        print("")

        // Find available samples
        let samplesDir = Paths.sourceDir.appendingPathComponent("Samples")
        let samples = try findSamples(in: samplesDir)

        if samples.isEmpty {
            noora.error("No sample projects found in \(samplesDir.path)")
            return
        }

        // Select project
        let selectedProject: SampleProject
        if let projectName = project {
            guard let found = samples.first(where: { $0.name.lowercased() == projectName.lowercased() }) else {
                noora.error("Sample project '\(projectName)' not found.")
                print("")
                print("Available samples:")
                for sample in samples {
                    print("  - \(sample.name)")
                }
                return
            }
            selectedProject = found
        } else {
            selectedProject = noora.singleChoicePrompt(
                title: "Sample Project",
                question: "Which sample would you like to build?",
                options: samples,
                description: "Select a sample project to build."
            )
        }

        // Select target
        let buildTarget: BuildTarget
        if let targetStr = target {
            guard let parsed = parseTarget(targetStr) else {
                noora.error("Invalid target '\(targetStr)'. Use: 68k, powerpc, or carbon")
                return
            }

            guard config.buildTargets.contains(parsed) else {
                noora.error("Target '\(parsed.displayName)' was not built. Available: \(config.buildTargets.map(\.rawValue).joined(separator: ", "))")
                return
            }

            buildTarget = parsed
        } else {
            if config.buildTargets.count == 1 {
                buildTarget = config.buildTargets[0]
            } else {
                struct TargetOption: CustomStringConvertible, Equatable {
                    let target: BuildTarget
                    var description: String { target.displayName }
                }

                let options = config.buildTargets.map { TargetOption(target: $0) }
                let choice = noora.singleChoicePrompt(
                    title: "Target",
                    question: "Which target platform?",
                    options: options,
                    description: "Select the target platform for the build."
                )
                buildTarget = choice.target
            }
        }

        print("")
        print("Building \(selectedProject.name) for \(buildTarget.displayName)...")
        print("")

        // Create build directory
        let buildDir = selectedProject.path.appendingPathComponent("build-\(buildTarget.rawValue.lowercased())")

        if clean && Paths.exists(buildDir) {
            print("Cleaning build directory...")
            try Paths.remove(buildDir)
        }

        try Paths.ensureDirectoryExists(buildDir)

        // Run cmake
        let toolchainFile = Paths.toolchainFile(for: buildTarget)

        print("Running CMake...")
        print("")

        let cmakeCommand = "cmake .. -DCMAKE_TOOLCHAIN_FILE=\(toolchainFile.path)"
        let cmakeResult = try await shell.runStreaming(cmakeCommand, at: buildDir) { output in
            print(output, terminator: "")
        }

        if cmakeResult != 0 {
            noora.error("CMake configuration failed with exit code \(cmakeResult)")
            return
        }

        print("")
        print("Running Make...")
        print("")

        let makeResult = try await shell.runStreaming("make", at: buildDir) { output in
            print(output, terminator: "")
        }

        if makeResult != 0 {
            noora.error("Make failed with exit code \(makeResult)")
            return
        }

        print("")
        noora.success("\(selectedProject.name) built successfully for \(buildTarget.displayName)!")

        // Find and list output files
        print("")
        print("Output files:")
        print("-------------")

        let outputs = try findOutputFiles(in: buildDir)
        for output in outputs {
            print("  \(output.path)")
        }

        // Check if there's a shared folder configured for the appropriate emulator
        let emuConfig = config.emulators
        let sharedFolder: String?

        switch buildTarget {
        case .m68k:
            sharedFolder = emuConfig?.basiliskSharedFolder
        case .powerpc, .carbon:
            sharedFolder = emuConfig?.sheepshaverSharedFolder
        }

        if let shared = sharedFolder, !outputs.isEmpty {
            print("")
            let copyToShared = noora.yesOrNoChoicePrompt(
                title: "Copy",
                question: "Copy build artifacts to shared folder?",
                defaultAnswer: true,
                description: "Files will be copied to: \(shared)"
            )

            if copyToShared {
                let sharedURL = URL(fileURLWithPath: shared)
                var copiedCount = 0

                for output in outputs {
                    let destURL = sharedURL.appendingPathComponent(output.lastPathComponent)

                    // Remove existing file if present
                    try? FileManager.default.removeItem(at: destURL)

                    do {
                        try FileManager.default.copyItem(at: output, to: destURL)
                        copiedCount += 1
                    } catch {
                        noora.warning("Could not copy \(output.lastPathComponent): \(error.localizedDescription)")
                    }
                }

                if copiedCount > 0 {
                    print("")
                    noora.success("Copied \(copiedCount) file(s) to shared folder!")
                    print("")
                    print("The files are now accessible from the emulator's 'Unix' disk.")

                    let emulatorName = buildTarget == .m68k ? "BasiliskII" : "SheepShaver"
                    print("Launch \(emulatorName) to run your application.")
                }
            }
        } else if sharedFolder == nil {
            print("")
            print("Tip: Set up an emulator shared folder to easily transfer builds:")
            print("  retro68-setup emulator guide")
        }

        print("")
    }

    private func findSamples(in directory: URL) throws -> [SampleProject] {
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        return contents.compactMap { url -> SampleProject? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }

            // Check if it has a CMakeLists.txt
            let cmakeLists = url.appendingPathComponent("CMakeLists.txt")
            guard fm.fileExists(atPath: cmakeLists.path) else {
                return nil
            }

            return SampleProject(name: url.lastPathComponent, path: url)
        }.sorted { $0.name < $1.name }
    }

    private func findOutputFiles(in buildDir: URL) throws -> [URL] {
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: buildDir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        var outputs: [URL] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            let name = fileURL.lastPathComponent

            // Look for classic Mac output formats
            if ext == "bin" || ext == "dsk" || ext == "appl" ||
               name.hasSuffix(".APPL") || name.contains(".rsrc") {
                outputs.append(fileURL)
            }
        }

        return outputs
    }

    private func parseTarget(_ str: String) -> BuildTarget? {
        switch str.lowercased() {
        case "68k", "m68k":
            return .m68k
        case "ppc", "powerpc":
            return .powerpc
        case "carbon":
            return .carbon
        default:
            return nil
        }
    }
}
