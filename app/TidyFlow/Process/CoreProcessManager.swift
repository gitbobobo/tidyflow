import Foundation
import Combine

/// Status of the Core process with detailed state
enum CoreStatus: Equatable {
    case stopped
    case starting(attempt: Int, port: Int)
    case running(port: Int, pid: Int32)
    case restarting(attempt: Int, maxAttempts: Int, lastError: String?)
    case failed(message: String)

    var displayText: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting(let attempt, _):
            return attempt > 1 ? "Starting (try \(attempt)/\(AppConfig.maxPortRetries))" : "Starting"
        case .running(let port, _): return "Running :\(port)"
        case .restarting(let attempt, let max, _):
            return "Restarting (\(attempt)/\(max))"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    var isRestarting: Bool {
        if case .restarting = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Get the port if running or starting
    var port: Int? {
        switch self {
        case .running(let port, _): return port
        case .starting(_, let port): return port
        default: return nil
        }
    }
}

/// Manages the lifecycle of the tidyflow-core subprocess
/// Responsibilities:
/// - Locate Core binary in app bundle
/// - Start/stop Core process with dynamic port allocation
/// - Monitor process status with retry on port conflict
/// - Auto-restart on crash with exponential backoff
/// - Inject port configuration via environment variable
class CoreProcessManager: ObservableObject {
    @Published private(set) var status: CoreStatus = .stopped

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Recent log lines for debugging (circular buffer)
    private var recentLogs: [String] = []
    private let maxLogLines = 50

    /// Prevent duplicate starts
    private var isStarting = false

    /// Current attempt number (1-based) for port retry
    private var currentAttempt = 0

    /// Auto-restart tracking
    private var autoRestartCount = 0
    private var isStopping = false
    private var lastTerminationReason: String?
    private var lastTerminationCode: Int32?

    /// Callback when Core is ready (WS connection succeeded)
    var onCoreReady: ((Int) -> Void)?

    /// Callback when Core fails after all retries
    var onCoreFailed: ((String) -> Void)?

    /// Callback when Core crashes and will auto-restart
    var onCoreRestarting: ((Int, Int) -> Void)?

    /// Callback when Core crashes and auto-restart limit reached
    var onCoreRestartLimitReached: ((String) -> Void)?

    // MARK: - Public API

    /// Start the Core process with dynamic port allocation
    /// Retries up to maxPortRetries times on failure
    func start() {
        guard !isStarting && !status.isRunning else {
            print("[CoreProcessManager] Already running or starting, skipping")
            return
        }

        // Clean up any orphaned processes from previous runs (e.g., Xcode force stop)
        Self.cleanupOrphanedProcesses()

        // Initialize log writer for file logging
        LogWriter.shared.initialize()

        isStarting = true
        currentAttempt = 0
        startWithRetry()
    }

    /// Kill any orphaned tidyflow-core processes from previous runs
    /// This handles the case where Xcode force-stops the app without calling termination handlers
    static func cleanupOrphanedProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", AppConfig.coreBinaryName]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                return
            }

            // Get current process's child PID (if any) to avoid killing our own child
            let currentChildPID = ProcessInfo.processInfo.processIdentifier

            let pids = output.split(separator: "\n").compactMap { Int32($0) }
            for pid in pids {
                // Don't kill if it's somehow our own process
                if pid == currentChildPID { continue }

                print("[CoreProcessManager] Killing orphaned tidyflow-core process: \(pid)")
                kill(pid, SIGTERM)

                // Give it a moment to terminate gracefully
                usleep(100_000) // 100ms

                // Force kill if still running
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        } catch {
            print("[CoreProcessManager] Failed to check for orphaned processes: \(error)")
        }
    }

    /// Stop the Core process gracefully
    /// Sends SIGTERM first, waits up to 1s, then SIGKILL
    func stop() {
        // Mark as stopping to prevent auto-restart
        isStopping = true

        guard let proc = process, proc.isRunning else {
            print("[CoreProcessManager] No running process to stop")
            DispatchQueue.main.async {
                self.status = .stopped
                self.isStopping = false
            }
            return
        }

        let pid = proc.processIdentifier
        print("[CoreProcessManager] Stopping process PID: \(pid)")

        // Send SIGTERM first
        proc.terminate()

        // Wait up to 1 second for graceful termination
        DispatchQueue.global().async { [weak self] in
            let deadline = Date().addingTimeInterval(AppConfig.shutdownTimeout)

            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if proc.isRunning {
                print("[CoreProcessManager] Process didn't terminate gracefully, sending SIGKILL")
                kill(pid, SIGKILL)
            }

            DispatchQueue.main.async {
                self?.cleanup()
                self?.status = .stopped
                self?.isStopping = false
            }
        }
    }

    /// Restart the Core process (stop then start)
    /// - Parameter resetCounter: If true, resets auto-restart counter (for manual restart)
    func restart(resetCounter: Bool = false) {
        if resetCounter {
            autoRestartCount = 0
        }
        stop()
        // Wait a bit for cleanup, then start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    /// Check if process is currently running
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Get the current port (if running or starting)
    var currentPort: Int? {
        status.port
    }

    /// Get auto-restart count (for UI display)
    var restartAttempts: Int {
        autoRestartCount
    }

    /// Get recent log lines for debugging
    func getRecentLogs() -> [String] {
        return recentLogs
    }

    /// Get last exit info for debug panel (combines reason and code)
    var lastExitInfo: String? {
        guard let reason = lastTerminationReason else { return nil }
        return reason
    }

    /// Manual run instructions for when auto-start fails
    static var manualRunInstructions: String {
        """
        To run Core manually:
        1. Open Terminal
        2. cd to project directory
        3. Run: ./scripts/run-core.sh
        Or: cargo run --release -- serve --port <port>
        """
    }

    /// Failure message with recovery hint
    static var failureRecoveryHint: String {
        "Press Cmd+R to retry"
    }

    // MARK: - Private: Retry Logic

    private func startWithRetry() {
        currentAttempt += 1

        guard currentAttempt <= AppConfig.maxPortRetries else {
            let msg = "Failed after \(AppConfig.maxPortRetries) attempts"
            print("[CoreProcessManager] \(msg)")
            DispatchQueue.main.async {
                self.status = .failed(message: msg)
                self.isStarting = false
                self.onCoreFailed?(msg)
            }
            return
        }

        // Allocate a new port
        guard let port = PortAllocator.findAvailablePort() else {
            let msg = "Failed to allocate port"
            print("[CoreProcessManager] \(msg)")
            // Retry with next attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startWithRetry()
            }
            return
        }

        print("[CoreProcessManager] Attempt \(currentAttempt): trying port \(port)")

        DispatchQueue.main.async {
            self.status = .starting(attempt: self.currentAttempt, port: port)
        }

        startProcess(port: port)
    }

    private func startProcess(port: Int) {
        // Locate binary in bundle
        guard let binaryURL = locateCoreBinary() else {
            let msg = "Core binary not found in bundle"
            print("[CoreProcessManager] \(msg)")
            DispatchQueue.main.async {
                self.status = .failed(message: msg)
                self.isStarting = false
                self.onCoreFailed?(msg)
            }
            return
        }

        print("[CoreProcessManager] Found binary at: \(binaryURL.path)")

        // Create process
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["serve", "--port", "\(port)"]

        // Set environment variable
        var env = ProcessInfo.processInfo.environment
        env["TIDYFLOW_PORT"] = "\(port)"
        proc.environment = env

        // Setup pipes for stdout/stderr
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Handle stdout - write to both memory buffer and file
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                // Write to file log
                LogWriter.shared.append(data)
                // Write to memory buffer for UI
                if let str = String(data: data, encoding: .utf8) {
                    self?.appendLog("[stdout] \(str)")
                }
            }
        }

        // Handle stderr - write to both memory buffer and file
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                // Write to file log
                LogWriter.shared.append(data)
                // Write to memory buffer for UI
                if let str = String(data: data, encoding: .utf8) {
                    self?.appendLog("[stderr] \(str)")
                }
            }
        }

        // Handle termination
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }

                let code = proc.terminationStatus
                let reason = proc.terminationReason

                // Store termination info
                self.lastTerminationCode = code
                self.lastTerminationReason = reason == .exit ? "exit(\(code))" : "signal(\(code))"

                // If we're intentionally stopping, don't auto-restart
                if self.isStopping {
                    print("[CoreProcessManager] Process stopped intentionally, not auto-restarting")
                    return
                }

                // If we're still in starting phase and process died, retry (port conflict handling)
                if self.isStarting {
                    print("[CoreProcessManager] Process exited during startup with code \(code), retrying...")
                    self.cleanup()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.startWithRetry()
                    }
                    return
                }

                // Unexpected termination - attempt auto-restart
                let isUnexpected = code != 0 || reason == .uncaughtSignal
                if isUnexpected {
                    print("[CoreProcessManager] Unexpected termination: code=\(code), reason=\(reason.rawValue)")
                    self.handleUnexpectedTermination(code: code, reason: reason)
                    return
                }

                // Normal termination (code == 0)
                self.status = .stopped
                self.cleanup()
            }
        }

        // Start process
        do {
            try proc.run()
            self.process = proc
            let pid = proc.processIdentifier
            print("[CoreProcessManager] Process started with PID: \(pid) on port \(port)")

            // Mark as running after a short delay to let it initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                if self.process?.isRunning == true {
                    self.status = .running(port: port, pid: pid)
                    self.isStarting = false
                    self.onCoreReady?(port)
                }
            }
        } catch {
            let msg = "Failed to start: \(error.localizedDescription)"
            print("[CoreProcessManager] \(msg)")

            // Retry on launch failure
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startWithRetry()
            }
        }
    }

    // MARK: - Private: Helpers

    /// Handle unexpected process termination with auto-restart
    private func handleUnexpectedTermination(code: Int32, reason: Process.TerminationReason) {
        cleanup()

        let errorDesc = reason == .uncaughtSignal ? "Signal \(code)" : "Exit code \(code)"

        // Check if we can auto-restart
        if autoRestartCount < AppConfig.autoRestartLimit {
            autoRestartCount += 1
            let attempt = autoRestartCount
            let maxAttempts = AppConfig.autoRestartLimit

            print("[CoreProcessManager] Auto-restart attempt \(attempt)/\(maxAttempts)")

            // Update status to restarting
            status = .restarting(attempt: attempt, maxAttempts: maxAttempts, lastError: errorDesc)
            onCoreRestarting?(attempt, maxAttempts)

            // Calculate backoff delay
            let backoffIndex = min(attempt - 1, AppConfig.autoRestartBackoffs.count - 1)
            let delay = AppConfig.autoRestartBackoffs[backoffIndex]

            print("[CoreProcessManager] Waiting \(delay)s before restart...")

            // Schedule restart with backoff
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                // Double-check we're still in restarting state (user might have manually stopped)
                if case .restarting = self.status {
                    self.start()
                }
            }
        } else {
            // Auto-restart limit reached
            let msg = "Core crashed repeatedly (\(AppConfig.autoRestartLimit) times). \(Self.failureRecoveryHint)"
            print("[CoreProcessManager] \(msg)")
            status = .failed(message: msg)
            onCoreRestartLimitReached?(msg)
            onCoreFailed?(msg)
        }
    }

    private func locateCoreBinary() -> URL? {
        // Try Contents/Resources/Core/tidyflow-core first
        if let resourceURL = Bundle.main.resourceURL {
            let coreURL = resourceURL
                .appendingPathComponent(AppConfig.coreBundleSubdir)
                .appendingPathComponent(AppConfig.coreBinaryName)
            if FileManager.default.isExecutableFile(atPath: coreURL.path) {
                return coreURL
            }
        }

        // Try Contents/MacOS/tidyflow-core as fallback
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            let coreURL = execURL.appendingPathComponent(AppConfig.coreBinaryName)
            if FileManager.default.isExecutableFile(atPath: coreURL.path) {
                return coreURL
            }
        }

        return nil
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.main.async {
            self.recentLogs.append(trimmed)
            if self.recentLogs.count > self.maxLogLines {
                self.recentLogs.removeFirst()
            }
        }
    }

    private func cleanup() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        // Close log file when process stops
        LogWriter.shared.close()
    }

    deinit {
        stop()
    }
}
