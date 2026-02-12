import Foundation
import Combine
import os

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
    /// 当前正在运行（或最近一次启动）的 Core 绑定地址
    private var launchedBindAddress: String?
    /// 当前 Core 进程对应的 WebSocket 鉴权 token
    private var currentWSToken: String?

    /// Callback when Core is ready (WS connection succeeded)
    var onCoreReady: ((Int) -> Void)?

    /// Callback when Core fails after all retries
    var onCoreFailed: ((String) -> Void)?

    /// Callback when Core crashes and will auto-restart
    var onCoreRestarting: ((Int, Int) -> Void)?

    /// Callback when Core crashes and auto-restart limit reached
    var onCoreRestartLimitReached: ((String) -> Void)?

    /// 当前 WebSocket 鉴权 token（供 WSClient 连接时携带）
    var wsAuthToken: String? {
        currentWSToken
    }

    /// 当前 Core 进程实际绑定地址（仅运行/启动态有效）
    var activeBindAddress: String? {
        switch status {
        case .running, .starting:
            return launchedBindAddress
        default:
            return nil
        }
    }

    // MARK: - Public API

    /// Start the Core process with dynamic port allocation
    /// Retries up to maxPortRetries times on failure
    func start() {
        guard !isStarting && !status.isRunning else {
            return
        }

        // 每次启动 Core 生成新的会话 token，避免跨会话复用
        currentWSToken = UUID().uuidString
        isStopping = false
        isStarting = true
        currentAttempt = 0
        // 清理孤儿进程可能阻塞，放到后台执行，避免启动阶段卡住主线程。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.cleanupOrphanedProcesses()
            DispatchQueue.main.async {
                guard let self = self, self.isStarting else {
                    return
                }
                self.startWithRetry()
            }
        }
    }

    /// Kill any orphaned tidyflow-core processes from previous runs
    /// This handles the case where Xcode force-stops the app without calling termination handlers
    /// Only kills processes whose parent is launchd (PPID=1), meaning they are true orphans
    static func cleanupOrphanedProcesses() {
        // 使用 ps 获取 tidyflow-core 进程的 PID 和 PPID
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -x: 只匹配完整进程名
        // -o pid=,ppid=: 输出 PID 和 PPID，不带表头
        task.arguments = ["-xo", "pid=,ppid=,comm="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            // 保护：避免 ps 异常阻塞导致启动路径被卡住。
            let deadline = Date().addingTimeInterval(2.0)
            while task.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if task.isRunning {
                TFLog.core.warning("Timed out while checking orphaned tidyflow-core processes")
                task.terminate()
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                return
            }

            // 解析输出，查找 tidyflow-core 进程
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3 else { continue }

                // 检查进程名是否为 tidyflow-core
                let comm = String(parts[2...].joined(separator: " "))
                guard comm.hasSuffix(AppConfig.coreBinaryName) else { continue }

                guard let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]) else { continue }

                // 只杀掉真正的孤儿进程（父进程是 launchd，PPID=1）
                // 如果 PPID 不是 1，说明父进程（另一个 TidyFlow 实例）还在运行
                if ppid == 1 {
                    TFLog.core.info("Killing orphaned tidyflow-core process: PID=\(pid, privacy: .public)")
                    kill(pid, SIGTERM)

                    // Give it a moment to terminate gracefully
                    usleep(100_000) // 100ms

                    // Force kill if still running
                    if kill(pid, 0) == 0 {
                        kill(pid, SIGKILL)
                    }
                } else {
                    // Skip: has active parent (PPID != 1)
                }
            }
        } catch {
            TFLog.core.error("Failed to check for orphaned processes: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stop the Core process gracefully
    /// Sends SIGTERM first, waits up to 1s, then SIGKILL
    func stop() {
        // Mark as stopping to prevent auto-restart
        isStopping = true
        // 可能还在启动前清理阶段，先标记取消启动。
        isStarting = false

        guard let proc = process, proc.isRunning else {
            DispatchQueue.main.async {
                self.status = .stopped
                self.isStopping = false
                self.currentWSToken = nil
                self.launchedBindAddress = nil
            }
            return
        }

        let pid = proc.processIdentifier
        TFLog.core.info("Stopping process PID: \(pid, privacy: .public)")

        // Send SIGTERM first
        proc.terminate()

        // Wait up to 1 second for graceful termination
        DispatchQueue.global().async { [weak self] in
            let deadline = Date().addingTimeInterval(AppConfig.shutdownTimeout)

            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if proc.isRunning {
                TFLog.core.warning("Process didn't terminate gracefully, sending SIGKILL")
                kill(pid, SIGKILL)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                // 仅当仍是同一个被 stop 的进程时，才允许把状态写回 stopped。
                if self.process === proc {
                    self.cleanup()
                    self.status = .stopped
                    self.currentWSToken = nil
                    self.launchedBindAddress = nil
                }
                self.isStopping = false
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
        // 等待 stop 完成后再启动，避免被 status.isRunning 守卫拦截导致重启丢失。
        waitForStopAndStart(maxChecks: 12, interval: 0.2)
    }

    /// Check if process is currently running
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Get the current port (if running or starting)
    var currentPort: Int? {
        status.port
    }

    /// 仅在 Core 已运行时返回端口（避免把启动中的端口暴露给业务 UI）
    var runningPort: Int? {
        if case .running(let port, _) = status {
            return port
        }
        return nil
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
            TFLog.core.error("\(msg, privacy: .public)")
            DispatchQueue.main.async {
                self.status = .failed(message: msg)
                self.isStarting = false
                self.currentWSToken = nil
                self.onCoreFailed?(msg)
            }
            return
        }

        // 固定端口优先
        let fixedPort = AppConfig.configuredFixedPort
        let port: Int
        if fixedPort > 0 && fixedPort <= 65535 {
            if PortAllocator.isPortAvailable(fixedPort) {
                port = fixedPort
            } else {
                let msg = "Fixed port \(fixedPort) is unavailable"
                TFLog.core.error("\(msg, privacy: .public)")
                DispatchQueue.main.async {
                    self.status = .failed(message: msg)
                    self.isStarting = false
                    self.currentWSToken = nil
                    self.onCoreFailed?(msg)
                }
                return
            }
        } else {
            // 优先尝试默认端口，不可用时动态分配
            let preferred = AppConfig.defaultPort
            if PortAllocator.isPortAvailable(preferred) {
                port = preferred
            } else {
                guard let dynamicPort = PortAllocator.findAvailablePort() else {
                    let msg = "Failed to allocate port"
                    TFLog.core.error("\(msg, privacy: .public)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.startWithRetry()
                    }
                    return
                }
                port = dynamicPort
            }
        }

        DispatchQueue.main.async {
            self.status = .starting(attempt: self.currentAttempt, port: port)
        }

        startProcess(port: port)
    }

    private func startProcess(port: Int) {
        // Locate binary in bundle
        guard let binaryURL = locateCoreBinary() else {
            let msg = "Core binary not found in bundle"
            TFLog.core.error("\(msg, privacy: .public)")
            DispatchQueue.main.async {
                self.status = .failed(message: msg)
                self.isStarting = false
                self.onCoreFailed?(msg)
            }
            return
        }

        // Create process
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["serve", "--port", "\(port)"]

        // Set environment variable
        var env = ProcessInfo.processInfo.environment
        let bindAddress = AppConfig.coreBindAddress
        env["TIDYFLOW_PORT"] = "\(port)"
        env["TIDYFLOW_BIND_ADDR"] = bindAddress
        if let token = currentWSToken, !token.isEmpty {
            env["TIDYFLOW_WS_TOKEN"] = token
        }
        if Self.isRunAppDebugBundle {
            env["TIDYFLOW_LOG_SUFFIX"] = "dev"
            env["TIDYFLOW_DEV"] = "1"
        }
        proc.environment = env

        // Setup pipes for stdout/stderr
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Handle stdout - write to memory buffer for UI
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let str = String(data: data, encoding: .utf8) {
                    self?.appendLog("[stdout] \(str)")
                }
            }
        }

        // Handle stderr - write to memory buffer for UI
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let str = String(data: data, encoding: .utf8) {
                    self?.appendLog("[stderr] \(str)")
                }
            }
        }

        // Handle termination
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 忽略旧进程（已被新进程替代）的终止回调，避免覆盖当前状态。
                if self.process !== proc {
                    return
                }

                let code = proc.terminationStatus
                let reason = proc.terminationReason

                // Store termination info
                self.lastTerminationCode = code
                self.lastTerminationReason = reason == .exit ? "exit(\(code))" : "signal(\(code))"

                // If we're intentionally stopping, don't auto-restart
                if self.isStopping {
                    return
                }

                // If we're still in starting phase and process died, retry (port conflict handling)
                if self.isStarting {
                    self.cleanup()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.startWithRetry()
                    }
                    return
                }

                // Unexpected termination - attempt auto-restart
                let isUnexpected = code != 0 || reason == .uncaughtSignal
                if isUnexpected {
                    TFLog.core.warning("Unexpected termination: code=\(code, privacy: .public), reason=\(reason.rawValue, privacy: .public)")
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
            self.launchedBindAddress = bindAddress
            let pid = proc.processIdentifier
            TFLog.core.info("Process started with PID: \(pid, privacy: .public) on port \(port, privacy: .public)")

            // Mark as running after a short delay to let it initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                // 仅当该 proc 仍是当前进程时，才更新 running 状态与回调。
                if self.process === proc, proc.isRunning {
                    self.status = .running(port: port, pid: pid)
                    self.isStarting = false
                    self.onCoreReady?(port)
                }
            }
        } catch {
            let msg = "Failed to start: \(error.localizedDescription)"
            TFLog.core.error("\(msg, privacy: .public)")

            // Retry on launch failure
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startWithRetry()
            }
        }
    }

    // MARK: - Private: Helpers

    /// run-app.sh 当前启动的是 `TidyFlow-Debug.app`
    private static var isRunAppDebugBundle: Bool {
        Bundle.main.bundleURL.lastPathComponent == "TidyFlow-Debug.app"
    }

    /// Handle unexpected process termination with auto-restart
    private func handleUnexpectedTermination(code: Int32, reason: Process.TerminationReason) {
        cleanup()

        let errorDesc = reason == .uncaughtSignal ? "Signal \(code)" : "Exit code \(code)"

        // Check if we can auto-restart
        if autoRestartCount < AppConfig.autoRestartLimit {
            autoRestartCount += 1
            let attempt = autoRestartCount
            let maxAttempts = AppConfig.autoRestartLimit

            TFLog.core.warning("Auto-restart attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")

            // Update status to restarting
            status = .restarting(attempt: attempt, maxAttempts: maxAttempts, lastError: errorDesc)
            onCoreRestarting?(attempt, maxAttempts)

            // Calculate backoff delay
            let backoffIndex = min(attempt - 1, AppConfig.autoRestartBackoffs.count - 1)
            let delay = AppConfig.autoRestartBackoffs[backoffIndex]

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
            TFLog.core.error("\(msg, privacy: .public)")
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
        launchedBindAddress = nil
    }

    /// 轮询等待 stop 完成，再触发 start。
    private func waitForStopAndStart(maxChecks: Int, interval: TimeInterval) {
        let shouldWait = isStopping || status.isRunning || status.isStarting
        if !shouldWait {
            start()
            return
        }

        guard maxChecks > 0 else {
            TFLog.core.warning("Restart wait timed out; forcing start attempt")
            start()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.waitForStopAndStart(maxChecks: maxChecks - 1, interval: interval)
        }
    }

    deinit {
        stop()
    }
}
