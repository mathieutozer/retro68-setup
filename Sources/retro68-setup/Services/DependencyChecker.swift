import Foundation

struct Dependency {
    let name: String
    let brewPackage: String
    let checkCommand: String?
    let requiredVersion: String?  // Minimum version required, nil means any version
    let required: Bool

    static let all: [Dependency] = [
        Dependency(name: "Homebrew", brewPackage: "", checkCommand: "brew --version", requiredVersion: nil, required: true),
        Dependency(name: "CMake", brewPackage: "cmake", checkCommand: "cmake --version", requiredVersion: nil, required: true),
        Dependency(name: "Boost", brewPackage: "boost", checkCommand: nil, requiredVersion: nil, required: true),
        Dependency(name: "GMP", brewPackage: "gmp", checkCommand: nil, requiredVersion: nil, required: true),
        Dependency(name: "MPFR", brewPackage: "mpfr", checkCommand: nil, requiredVersion: nil, required: true),
        Dependency(name: "MPC", brewPackage: "libmpc", checkCommand: nil, requiredVersion: nil, required: true),
        // Bison: macOS ships with 2.3, but Retro68 needs 3.0.2+. Homebrew's is keg-only.
        Dependency(name: "Bison", brewPackage: "bison", checkCommand: "/opt/homebrew/opt/bison/bin/bison --version", requiredVersion: "3.0.2", required: true),
        Dependency(name: "Texinfo", brewPackage: "texinfo", checkCommand: nil, requiredVersion: nil, required: true),
        Dependency(name: "Git", brewPackage: "git", checkCommand: "git --version", requiredVersion: nil, required: true),
    ]

    static var brewPackages: [String] {
        all.filter { !$0.brewPackage.isEmpty }.map(\.brewPackage)
    }
}

struct DependencyStatus {
    let dependency: Dependency
    let isInstalled: Bool
}

actor DependencyChecker {
    private let shell = ShellRunner.shared

    func checkHomebrew() async -> Bool {
        await shell.commandExists("brew")
    }

    func checkAllDependencies() async -> [DependencyStatus] {
        var statuses: [DependencyStatus] = []

        for dep in Dependency.all {
            let isInstalled: Bool
            if let checkCommand = dep.checkCommand {
                let result = try? await shell.run(checkCommand)
                isInstalled = result?.succeeded ?? false
            } else if !dep.brewPackage.isEmpty {
                isInstalled = await isBrewPackageInstalled(dep.brewPackage)
            } else {
                isInstalled = true
            }
            statuses.append(DependencyStatus(dependency: dep, isInstalled: isInstalled))
        }

        return statuses
    }

    func isBrewPackageInstalled(_ package: String) async -> Bool {
        let result = try? await shell.run("brew list \(package) 2>/dev/null")
        return result?.succeeded ?? false
    }

    func installMissingDependencies(_ missing: [Dependency]) async throws {
        let packages = missing.filter { !$0.brewPackage.isEmpty }.map(\.brewPackage)
        guard !packages.isEmpty else { return }

        let command = "brew install \(packages.joined(separator: " "))"
        let result = try await shell.run(command)

        if !result.succeeded {
            throw ShellError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    func getMissingDependencies() async -> [Dependency] {
        let statuses = await checkAllDependencies()
        return statuses.filter { !$0.isInstalled }.map(\.dependency)
    }
}
