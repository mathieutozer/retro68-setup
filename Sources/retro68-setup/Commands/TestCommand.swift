import ArgumentParser
import Foundation
import Noora

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run automated tests for classic Mac applications",
        subcommands: [
            TestRunCommand.self,
            TestListCommand.self,
        ],
        defaultSubcommand: TestRunCommand.self
    )
}

// Known test targets for Notion
enum NotionTestTarget: String, CaseIterable {
    case parsing = "TestParsing"
    case reducer1 = "TestReducer1"
    case reducer2 = "TestReducer2"
    case reducer3 = "TestReducer3"

    var displayName: String {
        switch self {
        case .parsing: return "Block Parsing Tests"
        case .reducer1: return "Reducer Tests (Part 1)"
        case .reducer2: return "Reducer Tests (Part 2)"
        case .reducer3: return "Reducer Tests (Part 3)"
        }
    }

    var buildTarget: String {
        return "\(rawValue)_APPL"
    }

    var binaryName: String {
        return "\(rawValue).bin"
    }

    var appName: String {
        return rawValue
    }

    var logFileName: String {
        switch self {
        case .parsing: return "test_parsing.log"
        case .reducer1: return "test_reducer1.log"
        case .reducer2: return "test_reducer2.log"
        case .reducer3: return "test_reducer3.log"
        }
    }
}

// MARK: - Test Run Command

struct TestRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run tests in the emulator"
    )

    @Option(name: .shortAndLong, help: "Path to the app to test (default: Notion)")
    var app: String?

    @Option(name: .long, help: "Shared folder path for file exchange")
    var sharedFolder: String?

    @Option(name: .long, help: "Specific test to run (parsing, reducer1, reducer2, reducer3, or all)")
    var test: String = "all"

    @Flag(name: .long, help: "Skip building the test app")
    var skipBuild: Bool = false

    @Flag(name: .long, help: "Keep emulator running after tests")
    var keepRunning: Bool = false

    @Option(name: .long, help: "Timeout in seconds per test (default: 60)")
    var timeout: Int = 60

    @Flag(name: .long, help: "Take a screenshot after each test")
    var screenshot: Bool = false

    @Flag(name: .long, help: "Use already-running emulator instead of launching new one")
    var useExisting: Bool = false

    func run() async throws {
        // Force line-buffered output for non-TTY
        setlinebuf(stdout)
        setlinebuf(stderr)

        // Ignore SIGPIPE to prevent process termination on broken pipe
        signal(SIGPIPE, SIG_IGN)

        let noora = Noora()
        let runner = TestRunner()

        print("")
        print("Notion Test Runner")
        print("==================")
        print("")

        // Determine which tests to run
        let testsToRun: [NotionTestTarget]
        if test == "all" {
            testsToRun = NotionTestTarget.allCases
        } else if let specific = NotionTestTarget.allCases.first(where: {
            $0.rawValue.lowercased().contains(test.lowercased())
        }) {
            testsToRun = [specific]
        } else {
            noora.error("Unknown test: \(test)")
            print("Available tests: parsing, reducer1, reducer2, reducer3, all")
            throw ExitCode.failure
        }

        // Determine paths
        let notionPath = app ?? "/Users/tozer/code/aiclassic/Apps/Notion"
        let sharedPath = sharedFolder ?? findSharedFolder()

        guard let sharedPath = sharedPath else {
            noora.error("Could not determine shared folder path.")
            print("Please specify with --shared-folder or configure in emulator settings.")
            throw ExitCode.failure
        }

        print("App path:       \(notionPath)")
        print("Shared folder:  \(sharedPath)")
        print("Tests to run:   \(testsToRun.map { $0.rawValue }.joined(separator: ", "))")
        print("")

        // Step 1: Build tests if needed
        if !skipBuild {
            print("Building tests...")
            for testTarget in testsToRun {
                print("  Building \(testTarget.displayName)...")
                do {
                    try await runner.buildTest(appPath: notionPath, target: testTarget)
                } catch {
                    noora.error("Build failed for \(testTarget.rawValue): \(error.localizedDescription)")
                    throw ExitCode.failure
                }
            }
            noora.success("All tests built successfully")
        }

        // Step 2: Copy test apps to shared folder
        print("Copying test apps to shared folder...")
        for testTarget in testsToRun {
            do {
                try await runner.copyTestApp(from: notionPath, to: sharedPath, target: testTarget)
            } catch {
                noora.error("Failed to copy \(testTarget.rawValue): \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
        noora.success("Test apps copied")

        // Step 3: Launch or connect to emulator
        var emulatorProcess: Process? = nil
        var client: AutomationClient? = nil

        if useExisting {
            // Connect to existing emulator
            print("Connecting to existing emulator...")
            do {
                client = try await runner.connectToExistingEmulator()
                noora.success("Connected to emulator")
            } catch {
                noora.error("Failed to connect to emulator: \(error.localizedDescription)")
                print("Make sure BasiliskII is running with --automation flag")
                throw ExitCode.failure
            }
        } else {
            // Launch new emulator with retry logic for hung boots
            let maxRetries = 3
            var lastError: Error?

            for attempt in 1...maxRetries {
                if attempt > 1 {
                    print("Retry attempt \(attempt)/\(maxRetries)...")
                }

                // Kill any existing emulator
                await runner.killExistingEmulator()

                print("Launching emulator with automation...")
                do {
                    emulatorProcess = try await runner.launchEmulatorWithAutomation()
                    print("Emulator process started, waiting for boot...")
                } catch {
                    lastError = error
                    print("Failed to launch: \(error.localizedDescription)")
                    continue
                }

                // Wait for emulator to boot and connect with shorter timeout per attempt
                print("Waiting for emulator to boot (timeout: 30s)...")
                do {
                    let connectedClient = try await runner.waitForEmulator(timeout: 30)

                    // Verify emulator is responsive with a screenshot check
                    print("Verifying emulator is responsive...")
                    let screenSize = try await connectedClient.getScreenSize()
                    if screenSize.width > 0 && screenSize.height > 0 {
                        noora.success("Emulator launched and responsive (\(screenSize.width)x\(screenSize.height))")
                        client = connectedClient

                        // Wait for Mac OS to fully boot
                        print("Waiting for Mac OS to initialize...")
                        try await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds
                        break
                    } else {
                        throw TestError.timeout("Screen size invalid")
                    }
                } catch {
                    lastError = error
                    print("Boot failed: \(error.localizedDescription)")
                    if let proc = emulatorProcess {
                        proc.terminate()
                    }
                    emulatorProcess = nil
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds before retry
                    continue
                }
            }

            guard emulatorProcess != nil, client != nil else {
                noora.error("Failed to start emulator after \(maxRetries) attempts")
                if let error = lastError {
                    print("Last error: \(error.localizedDescription)")
                }
                throw ExitCode.failure
            }
        }

        guard let automationClient = client else {
            noora.error("No automation client available")
            throw ExitCode.failure
        }

        defer {
            if !keepRunning, let process = emulatorProcess {
                print("Shutting down emulator...")
                process.terminate()
            }
        }

        // Step 6: Run each test
        var allResults: [TestResults] = []
        var totalPassed = 0
        var totalFailed = 0

        for (index, testTarget) in testsToRun.enumerated() {
            print("")
            print("[\(index + 1)/\(testsToRun.count)] Running \(testTarget.displayName)...")

            // Clear previous results - use the target-specific log file name
            let resultsPath = (sharedPath as NSString).appendingPathComponent(testTarget.logFileName)
            try? FileManager.default.removeItem(atPath: resultsPath)

            // Launch the test app using keyboard navigation
            do {
                try await runner.launchTestAppByName(client: automationClient, appName: testTarget.appName)
            } catch {
                noora.error("Failed to launch \(testTarget.rawValue): \(error.localizedDescription)")
                if screenshot {
                    try? await runner.takeScreenshot(client: automationClient, path: sharedPath, name: "error_\(testTarget.rawValue)")
                }
                continue
            }

            // Wait for test to complete
            do {
                let results = try await runner.waitForTestResults(
                    resultsPath: resultsPath,
                    timeout: timeout
                )
                allResults.append(results)
                totalPassed += results.passed
                totalFailed += results.failed

                if results.failed > 0 {
                    noora.warning("\(testTarget.displayName): \(results.passed) passed, \(results.failed) failed")
                } else {
                    noora.success("\(testTarget.displayName): \(results.passed) passed")
                }
            } catch {
                noora.error("\(testTarget.displayName) failed: \(error.localizedDescription)")
                totalFailed += 1
            }

            // Take screenshot if requested
            if screenshot {
                try? await runner.takeScreenshot(client: automationClient, path: sharedPath, name: "after_\(testTarget.rawValue)")
            }

            // Wait a bit before next test
            if index < testsToRun.count - 1 {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
        }

        // Report final results
        print("")
        print(String(repeating: "=", count: 50))
        print("FINAL TEST RESULTS")
        print(String(repeating: "=", count: 50))
        print("")

        for (index, results) in allResults.enumerated() {
            let target = testsToRun[index]
            print("\(target.displayName):")
            for result in results.tests {
                let icon = result.passed ? "  [PASS]" : "  [FAIL]"
                print("\(icon) \(result.name)")
                if !result.passed, let details = result.details {
                    print("         \(details)")
                }
            }
            print("")
        }

        print(String(repeating: "-", count: 50))
        print("Total: \(totalPassed) passed, \(totalFailed) failed")
        print(String(repeating: "-", count: 50))
        print("")

        if totalFailed > 0 {
            noora.error("Some tests failed!")
            throw ExitCode.failure
        } else {
            noora.success("All tests passed!")
        }
    }

    private func findSharedFolder() -> String? {
        // Try to find from emulator configuration
        let config = Configuration.load()
        if let emulators = config.emulators,
           let shared = emulators.basiliskSharedFolder {
            return shared
        }

        // Try to read from BasiliskII prefs file
        let prefsPath = NSHomeDirectory() + "/.basilisk_ii_prefs"
        if let prefs = try? String(contentsOfFile: prefsPath, encoding: .utf8) {
            for line in prefs.components(separatedBy: .newlines) {
                if line.hasPrefix("extfs ") {
                    let path = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if FileManager.default.fileExists(atPath: path) {
                        return path
                    }
                }
            }
        }

        // Default location
        let defaultPath = Paths.emulatorsDir.appendingPathComponent("shared").path
        if FileManager.default.fileExists(atPath: defaultPath) {
            return defaultPath
        }

        return nil
    }
}

// MARK: - Test List Command

struct TestListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available test suites"
    )

    func run() async throws {
        print("")
        print("Available Test Suites")
        print("=====================")
        print("")
        print("  notion    - Notion app tests (block parsing, reducer)")
        print("")
        print("Run tests with: retro68-setup test run")
    }
}

// MARK: - Test Runner

actor TestRunner {
    private let shell = ShellRunner.shared
    private let socketPath = "/tmp/basilisk_automation.sock"

    func killExistingEmulator() {
        // Kill any existing BasiliskII process
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "BasiliskII"]
        try? killTask.run()
        killTask.waitUntilExit()

        // Remove old socket
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // Mac keycodes for common keys
    private let KEY_RETURN: Int32 = 0x24
    private let KEY_TAB: Int32 = 0x30
    private let KEY_COMMAND: Int32 = 0x37
    private let KEY_SHIFT: Int32 = 0x38
    private let KEY_OPTION: Int32 = 0x3A
    private let KEY_O: Int32 = 0x1F  // For Cmd+O (Open)
    private let KEY_W: Int32 = 0x0D  // For Cmd+W (Close Window)

    func buildTest(appPath: String, target: NotionTestTarget) async throws {
        let buildDir = (appPath as NSString).appendingPathComponent("build")

        // Ensure build directory exists
        try FileManager.default.createDirectory(
            atPath: buildDir,
            withIntermediateDirectories: true
        )

        // Run cmake if needed
        let cmakeCachePath = (buildDir as NSString).appendingPathComponent("CMakeCache.txt")
        if !FileManager.default.fileExists(atPath: cmakeCachePath) {
            let toolchainFile = Paths.toolchainFile(for: .m68k).path
            let cmakeResult = try await shell.run(
                "cd \"\(buildDir)\" && cmake .. -DCMAKE_TOOLCHAIN_FILE=\"\(toolchainFile)\"",
                timeout: 120
            )
            guard cmakeResult.succeeded else {
                throw TestError.buildFailed(cmakeResult.stderr)
            }
        }

        // Build the specific test target
        let makeResult = try await shell.run(
            "cd \"\(buildDir)\" && make \(target.buildTarget) -j4",
            timeout: 300
        )
        guard makeResult.succeeded else {
            throw TestError.buildFailed(makeResult.stderr)
        }
    }

    func copyTestApp(from appPath: String, to sharedFolder: String, target: NotionTestTarget) async throws {
        let buildDir = (appPath as NSString).appendingPathComponent("build")
        // Copy the .APPL file (not .bin) - this is what cmake creates
        let testAppPath = (buildDir as NSString).appendingPathComponent("\(target.appName).APPL")

        guard FileManager.default.fileExists(atPath: testAppPath) else {
            throw TestError.appNotFound(testAppPath)
        }

        // Copy WITHOUT the .APPL extension - BasiliskII uses .APPL as a type marker
        // The file should be named "TestParsing" not "TestParsing.APPL"
        let destPath = (sharedFolder as NSString).appendingPathComponent(target.appName)
        try? FileManager.default.removeItem(atPath: destPath)
        try FileManager.default.copyItem(atPath: testAppPath, toPath: destPath)
    }

    func launchEmulatorWithAutomation() async throws -> Process {
        // Remove old socket
        try? FileManager.default.removeItem(atPath: socketPath)

        // Try our custom build first (has automation support)
        let customPath = "/Users/tozer/code/macemu/BasiliskII/src/Unix/BasiliskII"
        if FileManager.default.fileExists(atPath: customPath) {
            return try launchProcess(customPath)
        }

        // Try system BasiliskII
        let basiliskPath = "/Applications/BasiliskII.app/Contents/MacOS/BasiliskII"
        guard FileManager.default.fileExists(atPath: basiliskPath) else {
            throw TestError.emulatorNotFound
        }

        return try launchProcess(basiliskPath)
    }

    private func launchProcess(_ path: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--automation", "basilisk_automation.sock"]

        // Set working directory to where BasiliskII expects prefs
        process.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()

        // Redirect output to suppress it
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        return process
    }

    func waitForEmulator(timeout: Int) async throws -> AutomationClient {
        let client = AutomationClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        while Date() < deadline {
            do {
                try await client.connect()
                // Test connection
                if try await client.ping() {
                    return client
                }
            } catch {
                // Not ready yet, wait and retry
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
        }

        throw TestError.timeout("Emulator did not respond within \(timeout) seconds")
    }

    func connectToExistingEmulator() async throws -> AutomationClient {
        let client = AutomationClient(socketPath: socketPath)
        try await client.connect()
        guard try await client.ping() else {
            throw TestError.timeout("Emulator ping failed")
        }
        return client
    }

    /// Launch a test app by name using keyboard navigation in Finder
    /// This approach:
    /// 1. Clicks on desktop to focus Finder
    /// 2. Types "Unix" to select the Unix volume
    /// 3. Opens it with Cmd+O
    /// 4. Types the app name to select it
    /// 5. Opens it with Cmd+O
    func launchTestAppByName(client: AutomationClient, appName: String) async throws {
        print("[launch] Starting to launch \(appName)")
        fflush(stdout)

        // First, close all Finder windows to get clean state (Cmd+Option+W)
        print("[launch] Closing all windows")
        fflush(stdout)
        try await client.keyDown(keycode: KEY_COMMAND)
        try await client.keyDown(keycode: KEY_OPTION)
        try await client.keyDown(keycode: KEY_W)
        try await client.keyUp(keycode: KEY_W)
        try await client.keyUp(keycode: KEY_OPTION)
        try await client.keyUp(keycode: KEY_COMMAND)
        try await client.waitMs(500)

        // Click on desktop to ensure Finder is focused
        print("[launch] Clicking desktop at 320,300")
        fflush(stdout)
        try await client.click(x: 320, y: 300)
        print("[launch] Waiting 500ms")
        fflush(stdout)
        try await client.waitMs(500)

        // Type "Unix" to select the Unix volume on desktop
        print("[launch] Typing 'Unix'")
        fflush(stdout)
        try await client.typeText("Unix")
        print("[launch] Waiting 300ms")
        fflush(stdout)
        try await client.waitMs(300)

        // Press Cmd+O to open it
        print("[launch] Pressing Cmd+O")
        fflush(stdout)
        try await client.keyDown(keycode: KEY_COMMAND)
        try await client.keyDown(keycode: KEY_O)
        try await client.keyUp(keycode: KEY_O)
        try await client.keyUp(keycode: KEY_COMMAND)
        try await client.waitMs(1500)

        // Now in the Unix folder window, type the app name to select it
        try await client.typeText(appName)
        try await client.waitMs(300)

        // Press Cmd+O to open/run the app
        try await client.keyDown(keycode: KEY_COMMAND)
        try await client.keyDown(keycode: KEY_O)
        try await client.keyUp(keycode: KEY_O)
        try await client.keyUp(keycode: KEY_COMMAND)
        try await client.waitMs(1000)

        // Close the Unix folder window with Cmd+W to clean up
        try await client.keyDown(keycode: KEY_COMMAND)
        try await client.keyDown(keycode: KEY_W)
        try await client.keyUp(keycode: KEY_W)
        try await client.keyUp(keycode: KEY_COMMAND)
        try await client.waitMs(500)
    }

    func waitForTestResults(resultsPath: String, timeout: Int) async throws -> TestResults {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: resultsPath) {
                // Check if file contains the summary (tests are done)
                if let contents = try? String(contentsOfFile: resultsPath, encoding: .utf8) {
                    if contents.contains("Summary:") {
                        return try parseTestResults(contents)
                    }
                }
            }

            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        throw TestError.timeout("Tests did not complete within \(timeout) seconds")
    }

    private func parseTestResults(_ contents: String) throws -> TestResults {
        var tests: [TestResult] = []
        var passed = 0
        var failed = 0

        let lines = contents.components(separatedBy: .newlines)

        for line in lines {
            if line.hasPrefix("[PASS]") {
                let name = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                tests.append(TestResult(name: name, passed: true, details: nil))
                passed += 1
            } else if line.hasPrefix("[FAIL]") {
                let name = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                tests.append(TestResult(name: name, passed: false, details: nil))
                failed += 1
            } else if line.trimmingCharacters(in: .whitespaces).contains(":") &&
                      line.trimmingCharacters(in: .whitespaces).first?.isNumber == true &&
                      !tests.isEmpty {
                // This looks like failure details (file:line: message)
                if var lastTest = tests.last, !lastTest.passed {
                    lastTest.details = line.trimmingCharacters(in: .whitespaces)
                    tests[tests.count - 1] = lastTest
                }
            }
        }

        return TestResults(tests: tests, passed: passed, failed: failed, total: passed + failed)
    }

    func takeScreenshot(client: AutomationClient, path: String, name: String = "test_screenshot") async throws {
        let screenshot = try await client.screenshot()

        // Save as raw data
        let screenshotPath = (path as NSString).appendingPathComponent("\(name).raw")
        try screenshot.data.write(to: URL(fileURLWithPath: screenshotPath))

        print("Screenshot saved to: \(screenshotPath)")
    }
}

// MARK: - Models

struct TestResult {
    let name: String
    let passed: Bool
    var details: String?
}

struct TestResults {
    let tests: [TestResult]
    let passed: Int
    let failed: Int
    let total: Int
}

enum TestError: Error, LocalizedError {
    case buildFailed(String)
    case appNotFound(String)
    case emulatorNotFound
    case timeout(String)
    case testsFailed(Int)

    var errorDescription: String? {
        switch self {
        case .buildFailed(let msg): return "Build failed: \(msg)"
        case .appNotFound(let path): return "Test app not found: \(path)"
        case .emulatorNotFound: return "BasiliskII not found"
        case .timeout(let msg): return "Timeout: \(msg)"
        case .testsFailed(let count): return "\(count) tests failed"
        }
    }
}
