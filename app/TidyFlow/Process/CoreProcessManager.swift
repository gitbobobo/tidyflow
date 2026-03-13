import Foundation
import Combine
import os

/// Status of the Core process with detailed state
enum CoreStatus: Equatable {
    case stopped
    case starting(attempt: Int, port: Int?)
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

private struct CoreBootstrapInfo: Decodable {
    let port: Int
    let bindAddr: String
    let fixedPort: Int
    let remoteAccessEnabled: Bool
    let protocolVersion: Int
    let coreVersion: String

    enum CodingKeys: String, CodingKey {
        case port
        case bindAddr = "bind_addr"
        case fixedPort = "fixed_port"
        case remoteAccessEnabled = "remote_access_enabled"
        case protocolVersion = "protocol_version"
        case coreVersion = "core_version"
    }
}

/// Manages the lifecycle of the tidyflow-core subprocess
/// Responsibilities:
/// - Locate Core binary in app bundle
/// - Start/stop Core process
/// - Monitor process status with retry
/// - Auto-restart on crash with exponential backoff
/// - 解析 Core 启动 bootstrap 信息并驱动 WS 建连
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
    /// 当前启动链路的进程世代；用于丢弃旧进程的延迟回调。
    private var activeProcessGeneration: UInt64 = 0
    private var nextProcessGeneration: UInt64 = 0
    private var lastTerminationReason: String?
    private var lastTerminationCode: Int32?
    /// 当前正在运行（或最近一次启动）的 Core 绑定地址
    private var launchedBindAddress: String?
    /// 当前 Core 进程对应的 WebSocket 鉴权 token
    private var currentWSToken: String?
    /// 当前进程 stdout 剩余缓冲（按行解析 bootstrap）
    private var stdoutBuffer: String = ""
    /// 当前启动进程是否已收到 bootstrap
    private var pendingBootstrap: CoreBootstrapInfo?
    /// 启动阶段致命错误（例如协议不匹配/缺失 bootstrap），用于终止后直接进入 failed
    private var startupFatalErrorMessage: String?

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
        startupFatalErrorMessage = nil
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

        DispatchQueue.main.async {
            self.status = .starting(attempt: self.currentAttempt, port: nil)
        }

        startProcess()
    }

    private func startProcess() {
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
        proc.arguments = ["serve"]

        // 按当前 App bundle 归一化 Core 环境，避免继承父进程的开发变量污染生产版。
        var env = ProcessInfo.processInfo.environment
        if let token = currentWSToken, !token.isEmpty {
            env["TIDYFLOW_WS_TOKEN"] = token
        }
        if Self.isRunAppDebugBundle {
            env["TIDYFLOW_LOG_SUFFIX"] = "dev"
            env["TIDYFLOW_DEV"] = "1"
            env["TIDYFLOW_HOME"] = Self.debugTidyFlowHomePath
        } else {
            env.removeValue(forKey: "TIDYFLOW_LOG_SUFFIX")
            env.removeValue(forKey: "TIDYFLOW_DEV")
            env.removeValue(forKey: "TIDYFLOW_HOME")
        }
        proc.environment = env

        // Setup pipes for stdout/stderr
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.pendingBootstrap = nil
        self.stdoutBuffer = ""
        let generation = allocateProcessGeneration()
        activeProcessGeneration = generation

        // Handle stdout - 写日志 + 解析 bootstrap 行
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self, let proc else { return }
            self.handleStdoutChunk(data, process: proc, generation: generation)
        }

        // Handle stderr - write to memory buffer for UI
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                self?.appendLog("[stderr] \(str)")
            }
        }

        // Handle termination
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 忽略旧进程（已被新进程替代）的终止回调，避免覆盖当前状态。
                if self.process !== proc || self.activeProcessGeneration != generation {
                    return
                }

                let code = proc.terminationStatus
                let reason = proc.terminationReason

                // Store termination info
                self.lastTerminationCode = code
                self.lastTerminationReason = reason == .exit ? "exit(\(code))" : "signal(\(code))"

                if let fatalMessage = self.startupFatalErrorMessage {
                    self.startupFatalErrorMessage = nil
                    self.cleanup()
                    self.isStarting = false
                    self.currentWSToken = nil
                    self.status = .failed(message: fatalMessage)
                    self.onCoreFailed?(fatalMessage)
                    return
                }

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
            self.launchedBindAddress = nil
            let pid = proc.processIdentifier
            TFLog.core.info("Process started with PID: \(pid, privacy: .public), waiting for bootstrap")
            waitForBootstrap(proc: proc, pid: pid, launchedAt: Date(), generation: generation)
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

    /// Debug App 使用独立的数据根目录，避免与 /Applications 中的正式版互相覆盖状态。
    private static var debugTidyFlowHomePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tidyflow-dev", isDirectory: true)
            .path
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
        stdoutBuffer = ""
        pendingBootstrap = nil
        process = nil
        launchedBindAddress = nil
        activeProcessGeneration = 0
    }

    /// deinit 阶段不能再走 stop() 的异步链路，否则会在析构期间重新强持有 self。
    /// 这里同步拆除观察与回调，并尽力终止进程，避免留下悬空引用或孤儿 Core。
    private func cleanupForDeinit() {
        let proc = process
        let pid = proc?.processIdentifier

        proc?.terminationHandler = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer = ""
        pendingBootstrap = nil
        process = nil
        launchedBindAddress = nil
        currentWSToken = nil
        startupFatalErrorMessage = nil
        activeProcessGeneration = 0
        isStarting = false
        isStopping = true

        guard let proc, proc.isRunning else { return }

        proc.terminate()
        let deadline = Date().addingTimeInterval(AppConfig.shutdownTimeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if proc.isRunning, let pid {
            TFLog.core.warning("CoreProcessManager deinit 强制结束残留进程 PID: \(pid, privacy: .public)")
            kill(pid, SIGKILL)
        }
    }

    private func handleStdoutChunk(_ data: Data, process: Process, generation: UInt64) {
        guard self.process === process, self.activeProcessGeneration == generation else { return }
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }

        appendLog("[stdout] \(chunk)")
        stdoutBuffer.append(chunk)

        while let lineBreak = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<lineBreak])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(...lineBreak)
            guard !line.isEmpty else { continue }
            handleStdoutLine(line, generation: generation)
        }
    }

    private func handleStdoutLine(_ line: String, generation: UInt64) {
        guard activeProcessGeneration == generation else { return }
        let prefix = "TIDYFLOW_BOOTSTRAP "
        if line.hasPrefix(prefix) {
            let payload = String(line.dropFirst(prefix.count))
            guard let data = payload.data(using: .utf8) else { return }
            guard let bootstrap = try? JSONDecoder().decode(CoreBootstrapInfo.self, from: data) else {
                TFLog.core.warning("Failed to decode bootstrap payload: \(payload, privacy: .public)")
                return
            }

            guard bootstrap.protocolVersion == AppConfig.protocolVersion else {
                triggerFatalStartupFailure(
                    "Core 协议版本不匹配：App 期望 v\(AppConfig.protocolVersion)，Core 返回 v\(bootstrap.protocolVersion)。请使用同版本重新构建应用。"
                )
                return
            }

            pendingBootstrap = bootstrap
            launchedBindAddress = bootstrap.bindAddr
            if case .starting(let attempt, _) = status {
                status = .starting(attempt: attempt, port: bootstrap.port)
            }

            TFLog.core.info(
                "Received bootstrap: port=\(bootstrap.port, privacy: .public), bind=\(bootstrap.bindAddr, privacy: .public), fixed_port=\(bootstrap.fixedPort, privacy: .public), remote_access=\(bootstrap.remoteAccessEnabled, privacy: .public), protocol=\(bootstrap.protocolVersion, privacy: .public), core=\(bootstrap.coreVersion, privacy: .public)"
            )
            return
        }

        // 老 Core（无 bootstrap）也会打印 “protocol vX” 监听日志；若版本不匹配，立刻失败，避免长时间卡在启动页。
        if pendingBootstrap == nil,
           let observedVersion = parseProtocolVersionHint(fromLogLine: line),
           observedVersion != AppConfig.protocolVersion {
            triggerFatalStartupFailure(
                "Core 协议版本不匹配：App 期望 v\(AppConfig.protocolVersion)，日志检测到 Core 为 v\(observedVersion)。请使用同版本重新构建应用。"
            )
        }
    }

    private func waitForBootstrap(proc: Process, pid: Int32, launchedAt: Date, generation: UInt64) {
        guard process === proc, proc.isRunning, activeProcessGeneration == generation else { return }
        if let bootstrap = pendingBootstrap {
            waitForCoreReady(
                proc: proc,
                port: bootstrap.port,
                pid: pid,
                launchedAt: launchedAt,
                generation: generation
            )
            return
        }

        let elapsed = Date().timeIntervalSince(launchedAt)
        if elapsed >= AppConfig.coreReadyTimeout {
            triggerFatalStartupFailure(
                "Core 启动握手失败：\(AppConfig.coreReadyTimeout)s 内未收到 TIDYFLOW_BOOTSTRAP。请确认 App 与 Core 为同一协议版本并重新构建。"
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForBootstrap(proc: proc, pid: pid, launchedAt: launchedAt, generation: generation)
        }
    }

    private func parseProtocolVersionHint(fromLogLine line: String) -> Int? {
        let pattern = #"protocol v([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: nsRange),
              match.numberOfRanges == 2,
              let captureRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[captureRange])
    }

    private func triggerFatalStartupFailure(_ message: String) {
        guard startupFatalErrorMessage == nil else { return }
        startupFatalErrorMessage = message
        TFLog.core.error("\(message, privacy: .public)")

        guard let proc = process, proc.isRunning else {
            DispatchQueue.main.async {
                self.cleanup()
                self.isStarting = false
                self.currentWSToken = nil
                self.status = .failed(message: message)
                self.onCoreFailed?(message)
                self.startupFatalErrorMessage = nil
            }
            return
        }

        proc.terminate()
    }

    /// 等待 Core 端口可连接后再回调 ready，避免“进程已启动但 WS 尚未监听”导致首连失败。
    private func waitForCoreReady(
        proc: Process,
        port: Int,
        pid: Int32,
        launchedAt: Date,
        generation: UInt64
    ) {
        guard process === proc, proc.isRunning, activeProcessGeneration == generation else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reachable = PortAllocator.isPortReachable(port, timeout: 0.25)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.process === proc,
                      proc.isRunning,
                      self.activeProcessGeneration == generation else { return }

                if reachable {
                    self.status = .running(port: port, pid: pid)
                    self.isStarting = false
                    self.onCoreReady?(port)
                    return
                }

                let elapsed = Date().timeIntervalSince(launchedAt)
                if elapsed >= AppConfig.coreReadyTimeout {
                    TFLog.core.error(
                        "Core port not reachable within \(AppConfig.coreReadyTimeout, privacy: .public)s: \(port, privacy: .public)"
                    )
                    // 触发 terminationHandler 走启动重试路径，避免卡在启动页。
                    proc.terminate()
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.waitForCoreReady(
                        proc: proc,
                        port: port,
                        pid: pid,
                        launchedAt: launchedAt,
                        generation: generation
                    )
                }
            }
        }
    }

    private func allocateProcessGeneration() -> UInt64 {
        nextProcessGeneration &+= 1
        return nextProcessGeneration
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
        cleanupForDeinit()
    }
}
