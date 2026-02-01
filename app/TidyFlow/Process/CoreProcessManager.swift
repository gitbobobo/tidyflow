import Foundation
import Combine

/// Status of the Core process
enum CoreStatus: Equatable {
    case stopped
    case starting
    case running
    case failed(message: String)

    var displayText: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Manages the lifecycle of the tidyflow-core subprocess
/// Responsibilities:
/// - Locate Core binary in app bundle
/// - Start/stop Core process
/// - Monitor process status
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

    // MARK: - Public API

    /// Start the Core process if not already running
    func start() {
        guard !isStarting && !status.isRunning else {
            print("[CoreProcessManager] Already running or starting, skipping")
            return
        }

        isStarting = true
        DispatchQueue.main.async {
            self.status = .starting
        }

        // Locate binary in bundle
        guard let binaryURL = locateCoreBinary() else {
            let msg = "Core binary not found in bundle"
            print("[CoreProcessManager] \(msg)")
            DispatchQueue.main.async {
                self.status = .failed(message: msg)
                self.isStarting = false
            }
            return
        }

        print("[CoreProcessManager] Found binary at: \(binaryURL.path)")

        // Create process
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["serve", "--port", "\(AppConfig.corePort)"]

        // Also set environment variable as backup
        var env = ProcessInfo.processInfo.environment
        env["TIDYFLOW_PORT"] = "\(AppConfig.corePort)"
        proc.environment = env

        // Setup pipes for stdout/stderr
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Handle stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                self?.appendLog("[stdout] \(str)")
            }
        }

        // Handle stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                self?.appendLog("[stderr] \(str)")
            }
        }

        // Handle termination
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                let code = proc.terminationStatus
                if code == 0 {
                    self?.status = .stopped
                } else {
                    self?.status = .failed(message: "Exit code \(code)")
                }
                self?.cleanup()
            }
        }

        // Start process
        do {
            try proc.run()
            self.process = proc
            print("[CoreProcessManager] Process started with PID: \(proc.processIdentifier)")

            // Give it a moment to start, then mark as running
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                if self.process?.isRunning == true {
                    self.status = .running
                }
                self.isStarting = false
            }
        } catch {
            let msg = "Failed to start: \(error.localizedDescription)"
            print("[CoreProcessManager] \(msg)")
            DispatchQueue.main.async {
                self.status = .failed(message: msg)
                self.isStarting = false
            }
        }
    }

    /// Stop the Core process
    func stop() {
        guard let proc = process, proc.isRunning else {
            print("[CoreProcessManager] No running process to stop")
            return
        }

        print("[CoreProcessManager] Stopping process PID: \(proc.processIdentifier)")

        // Send SIGTERM first
        proc.terminate()

        // Give it 2 seconds to terminate gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if proc.isRunning {
                print("[CoreProcessManager] Process didn't terminate, sending SIGKILL")
                kill(proc.processIdentifier, SIGKILL)
            }
            self?.cleanup()
        }
    }

    /// Check if process is currently running
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Get recent log lines for debugging
    func getRecentLogs() -> [String] {
        return recentLogs
    }

    /// Manual run instructions for when auto-start fails
    static var manualRunInstructions: String {
        """
        To run Core manually:
        1. Open Terminal
        2. cd to project directory
        3. Run: ./scripts/run-core.sh
        Or: cargo run --release -- serve --port \(AppConfig.corePort)
        """
    }

    // MARK: - Private

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
    }

    deinit {
        stop()
    }
}
