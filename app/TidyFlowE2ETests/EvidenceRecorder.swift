import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif

enum EvidenceArtifactType: String, Codable {
    case log
    case screenshot
}

struct EvidenceItem: Codable {
    let id: String
    let deviceType: String
    let type: EvidenceArtifactType
    let order: Int
    let path: String
    let title: String
    let description: String
    let scenario: String?
    let subsystem: String?
    let createdAt: String?
    /// 多工作区边界上下文：格式 "<scenario>:<device>:project=<p>:workspace=<w>"
    /// 供回归失败时直接定位 project/workspace 串台问题，所有三端场景保持相同键结构
    let workspaceContext: String?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceType = "device_type"
        case type
        case order
        case path
        case title
        case description
        case scenario
        case subsystem
        case createdAt = "created_at"
        case workspaceContext = "workspace_context"
    }
}

struct EvidenceIndexDocument: Codable {
    var schemaVersion: String
    var updatedAt: String
    var items: [EvidenceItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "$schema_version"
        case updatedAt = "updated_at"
        case items
    }
}

private struct EvidenceRunContext: Decodable {
    let evidenceRoot: String?
    let runID: String?
    let deviceType: String?

    enum CodingKeys: String, CodingKey {
        case evidenceRoot = "evidence_root"
        case runID = "run_id"
        case deviceType = "device_type"
    }
}

enum EvidenceRecorderError: LocalizedError {
    case unsupportedDeviceType(String)
    case invalidRelativePath(String)
    case artifactNotFound(String)
    case evidenceRootNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDeviceType(let value):
            return "不支持的 device_type: \(value)"
        case .invalidRelativePath(let value):
            return "证据路径不合法: \(value)"
        case .artifactNotFound(let value):
            return "证据文件不存在: \(value)"
        case .evidenceRootNotFound(let value):
            return "证据目录不存在: \(value)"
        }
    }
}

/// 在 UI 测试执行期间实时落盘证据并增量更新 evidence.index.json。
final class EvidenceRecorder {
    static let shared = EvidenceRecorder()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let nowFormatter = ISO8601DateFormatter()

    let evidenceRootURL: URL
    let deviceType: String
    let runID: String

    private let indexURL: URL
    private var nextOrder: Int

    private init() {
        let env = ProcessInfo.processInfo.environment
        let repositoryRootURL = Self.repositoryRootURL()
        let contextFileURL = Self.resolveContextFileURL(env: env, repositoryRootURL: repositoryRootURL)
        let runContext = Self.loadRunContext(at: contextFileURL)

        let rootPath = Self.resolveEvidenceRootPath(
            env: env,
            runContext: runContext,
            repositoryRootURL: repositoryRootURL
        )
        let rootURL: URL
        if rootPath.hasPrefix("/") {
            rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        } else {
            rootURL = repositoryRootURL.appendingPathComponent(rootPath, isDirectory: true)
        }

        let normalizedDevice = Self.resolveDeviceType(env: env, runContext: runContext)
        let resolvedRunID = Self.resolveRunID(env: env, runContext: runContext)

        evidenceRootURL = rootURL.standardizedFileURL
        deviceType = normalizedDevice
        runID = resolvedRunID
        indexURL = evidenceRootURL.appendingPathComponent("evidence.index.json")
        nextOrder = 10

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        nowFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        nowFormatter.formatOptions = [.withInternetDateTime]

        do {
            try prepareDirectories()
            nextOrder = nextOrderSeed()
        } catch {
            XCTFail("初始化 EvidenceRecorder 失败: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func recordScreenshot(
        scenario: String,
        subsystem: String,
        title: String,
        description: String,
        screenshot: XCUIScreenshot,
        workspaceContext: String? = nil
    ) throws -> EvidenceItem {
        try lock.withLock {
            try validateDeviceType()
            let order = allocateOrder()
            let scenarioSlug = sanitizeScenario(scenario)
            let targetDir = evidenceRootURL
                .appendingPathComponent(deviceType, isDirectory: true)
                .appendingPathComponent("e2e", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent(scenarioSlug, isDirectory: true)
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let fileName = "\(scenarioSlug)-\(String(format: "%03d", order)).png"
            let fileURL = targetDir.appendingPathComponent(fileName)
            try screenshot.pngRepresentation.write(to: fileURL, options: .atomic)

            let relativePath = try makeRelativePath(for: fileURL)
            let item = EvidenceItem(
                id: makeEvidenceID(scenarioSlug: scenarioSlug, order: order),
                deviceType: deviceType,
                type: .screenshot,
                order: order,
                path: relativePath,
                title: title,
                description: description,
                scenario: scenario,
                subsystem: subsystem,
                createdAt: nowUTC(),
                workspaceContext: workspaceContext
            )
            try append(item: item)
            return item
        }
    }

    @discardableResult
    func recordLog(
        scenario: String,
        subsystem: String,
        title: String,
        description: String,
        body: String,
        workspaceContext: String? = nil
    ) throws -> EvidenceItem {
        try lock.withLock {
            try validateDeviceType()
            let order = allocateOrder()
            let scenarioSlug = sanitizeScenario(scenario)
            let targetDir = evidenceRootURL
                .appendingPathComponent(deviceType, isDirectory: true)
                .appendingPathComponent("e2e", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent(scenarioSlug, isDirectory: true)
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let fileName = "\(scenarioSlug)-\(String(format: "%03d", order)).log"
            let fileURL = targetDir.appendingPathComponent(fileName)
            var logContent = """
            [time] \(nowUTC())
            [device_type] \(deviceType)
            [scenario] \(scenario)
            [title] \(title)
            [description] \(description)
            """
            if let ctx = workspaceContext {
                logContent += "\n[workspace_context] \(ctx)"
            }
            logContent += "\n[detail]\n\(body)"
            try logContent.write(to: fileURL, atomically: true, encoding: .utf8)

            let relativePath = try makeRelativePath(for: fileURL)
            let item = EvidenceItem(
                id: makeEvidenceID(scenarioSlug: scenarioSlug, order: order),
                deviceType: deviceType,
                type: .log,
                order: order,
                path: relativePath,
                title: title,
                description: description,
                scenario: scenario,
                subsystem: subsystem,
                createdAt: nowUTC(),
                workspaceContext: workspaceContext
            )
            try append(item: item)
            return item
        }
    }

    private func append(item: EvidenceItem) throws {
        guard fileManager.fileExists(atPath: evidenceRootURL.path) else {
            throw EvidenceRecorderError.evidenceRootNotFound(evidenceRootURL.path)
        }
        guard artifactExists(at: item.path) else {
            throw EvidenceRecorderError.artifactNotFound(item.path)
        }
        try validate(path: item.path, deviceType: item.deviceType)

        var index = try loadCurrentIndex()
        index.items = index.items.filter { artifactExists(at: $0.path) }

        if let existingIndex = index.items.firstIndex(where: { $0.id == item.id }) {
            index.items[existingIndex] = item
        } else {
            index.items.append(item)
        }

        index.items.sort { lhs, rhs in
            if lhs.deviceType != rhs.deviceType {
                return lhs.deviceType < rhs.deviceType
            }
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.id < rhs.id
        }
        index.updatedAt = nowUTC()

        try fileManager.createDirectory(at: evidenceRootURL, withIntermediateDirectories: true)
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func loadCurrentIndex() throws -> EvidenceIndexDocument {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return EvidenceIndexDocument(schemaVersion: "1.0", updatedAt: nowUTC(), items: [])
        }
        let data = try Data(contentsOf: indexURL)
        do {
            return try decoder.decode(EvidenceIndexDocument.self, from: data)
        } catch {
            return EvidenceIndexDocument(schemaVersion: "1.0", updatedAt: nowUTC(), items: [])
        }
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: evidenceRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: evidenceRootURL.appendingPathComponent(deviceType, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: evidenceRootURL
                .appendingPathComponent(deviceType, isDirectory: true)
                .appendingPathComponent("e2e", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func makeEvidenceID(scenarioSlug: String, order: Int) -> String {
        "ev-\(deviceType)-\(runID)-\(scenarioSlug)-\(order)"
    }

    /// 构建或补全 workspace_context 字段，确保 run_id 和 device_type 可追溯
    ///
    /// 格式: "<scenario>:<device>:run_id=<r>:project=<p>:workspace=<w>"
    /// 如果调用方已提供 workspaceContext 则原样返回（信任调用方契约）。
    func enrichWorkspaceContext(
        scenario: String,
        workspaceContext: String?
    ) -> String? {
        if let provided = workspaceContext, !provided.isEmpty {
            return provided
        }
        // 默认补全 run_id 和 device_type 以便回归校验时可定位
        return "\(scenario):\(deviceType):run_id=\(runID)"
    }

    private func sanitizeScenario(_ scenario: String) -> String {
        let lowered = scenario.lowercased()
        let replaced = lowered.replacingOccurrences(of: "_", with: "-")
        let sanitized = replaced.replacingOccurrences(
            of: "[^a-z0-9-]",
            with: "-",
            options: .regularExpression
        )
        let merged = sanitized.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return merged.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func nowUTC() -> String {
        nowFormatter.string(from: Date())
    }

    private func allocateOrder() -> Int {
        let value = nextOrder
        nextOrder += 10
        return value
    }

    private func nextOrderSeed() -> Int {
        guard let index = try? loadCurrentIndex() else {
            return 10
        }
        let maxOrder = index.items
            .filter { $0.deviceType == deviceType && $0.id.contains("-\(runID)-") }
            .map(\.order)
            .max() ?? 0
        return maxOrder + 10
    }

    private func makeRelativePath(for absoluteURL: URL) throws -> String {
        let rootPath = evidenceRootURL.standardizedFileURL.path
        let artifactPath = absoluteURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard artifactPath.hasPrefix(prefix) else {
            throw EvidenceRecorderError.invalidRelativePath(artifactPath)
        }
        let relative = String(artifactPath.dropFirst(prefix.count))
        try validate(path: relative, deviceType: deviceType)
        return relative
    }

    private func validate(path: String, deviceType: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
            throw EvidenceRecorderError.invalidRelativePath(path)
        }
        let parts = path.split(separator: "/")
        guard let first = parts.first, String(first) == deviceType else {
            throw EvidenceRecorderError.invalidRelativePath(path)
        }
    }

    private func artifactExists(at relativePath: String) -> Bool {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            return false
        }
        let url = evidenceRootURL.appendingPathComponent(relativePath, isDirectory: false)
        return fileManager.fileExists(atPath: url.path)
    }

    private func validateDeviceType() throws {
        let supported = Set(["iphone", "ipad", "mac"])
        guard supported.contains(deviceType) else {
            throw EvidenceRecorderError.unsupportedDeviceType(deviceType)
        }
    }

    private static func resolveDeviceType(env: [String: String], runContext: EvidenceRunContext?) -> String {
        if let fromEnv = normalizeValue(env["TF_DEVICE_TYPE"]) {
            return fromEnv
        }
        if let fromContext = normalizeValue(runContext?.deviceType) {
            return fromContext
        }
        if let simulatorName = env["SIMULATOR_DEVICE_NAME"]?.lowercased() {
            if simulatorName.contains("ipad") {
                return "ipad"
            }
            if simulatorName.contains("iphone") {
                return "iphone"
            }
        }
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #elseif os(tvOS)
        return "iphone"
        #elseif os(macOS)
        if Self.isAppleSimulatorRuntime(env: env) {
            return Self.resolveSimulatorDeviceFallback(env: env)
        }
        return "mac"
        #else
        return "iphone"
        #endif
    }

    private static func resolveSimulatorDeviceFallback(env: [String: String]) -> String {
        if let simulatorModel = env["SIMULATOR_MODEL_IDENTIFIER"]?.lowercased(),
           simulatorModel.contains("ipad") {
            return "ipad"
        }
        return "iphone"
    }

    private static func isAppleSimulatorRuntime(env: [String: String]) -> Bool {
        if normalizeValue(env["SIMULATOR_DEVICE_NAME"]) != nil {
            return true
        }
        #if os(macOS)
        #if targetEnvironment(simulator)
        return true
        #else
        if let simulatorRoot = env["SIMULATOR_ROOT"], !simulatorRoot.isEmpty {
            return true
        }
        if let simulatorUDID = env["SIMULATOR_UDID"], !simulatorUDID.isEmpty {
            return true
        }
        #endif
        #endif
        return false
    }

    private static func resolveRunID(env: [String: String], runContext: EvidenceRunContext?) -> String {
        if let fromEnv = normalizeValue(env["TF_E2E_RUN_ID"]) {
            return fromEnv
        }
        if let fromContext = normalizeValue(runContext?.runID) {
            return fromContext
        }
        return defaultRunID()
    }

    private static func resolveEvidenceRootPath(
        env: [String: String],
        runContext: EvidenceRunContext?,
        repositoryRootURL: URL
    ) -> String {
        if let fromEnv = normalizeValue(env["TF_EVIDENCE_ROOT"]) {
            return fromEnv
        }
        if let fromContext = normalizeValue(runContext?.evidenceRoot) {
            return fromContext
        }
        return repositoryRootURL
            .appendingPathComponent(".tidyflow", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .path
    }

    private static func resolveContextFileURL(env: [String: String], repositoryRootURL: URL) -> URL {
        if let raw = normalizeValue(env["TF_EVIDENCE_CONTEXT_FILE"]) {
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw)
            }
            return repositoryRootURL.appendingPathComponent(raw)
        }
        return repositoryRootURL
            .appendingPathComponent(".tidyflow", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent(".run-context.json", isDirectory: false)
    }

    private static func loadRunContext(at url: URL) -> EvidenceRunContext? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(EvidenceRunContext.self, from: data)
    }

    private static func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private static func normalizeValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private static func defaultRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}

private extension NSLock {
    func withLock<T>(_ action: () throws -> T) throws -> T {
        lock()
        defer { unlock() }
        return try action()
    }
}
