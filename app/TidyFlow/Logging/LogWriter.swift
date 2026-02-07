import Foundation
import os

/// Handles file-based logging with rotation for Core process output
/// Thread-safe via serial DispatchQueue
final class LogWriter {
    // MARK: - Configuration

    /// Maximum log file size before rotation (1 MB)
    static let maxBytes: UInt64 = 1_000_000

    /// Maximum number of rotated files to keep
    static let maxFiles: Int = 5

    /// Log directory: ~/Library/Logs/TidyFlow/
    static var logDirectory: URL {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return libraryURL.appendingPathComponent("Logs/TidyFlow", isDirectory: true)
    }

    /// Main log file path: ~/Library/Logs/TidyFlow/core.log
    static var logFilePath: URL {
        logDirectory.appendingPathComponent("core.log")
    }

    /// Human-readable log path for UI display
    static var logPathDisplay: String {
        "~/Library/Logs/TidyFlow/core.log"
    }

    // MARK: - Singleton

    static let shared = LogWriter()

    // MARK: - Private Properties

    private let queue = DispatchQueue(label: "cn.tidyflow.logwriter", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentFileSize: UInt64 = 0
    private var isInitialized = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Initialize log directory and file handle
    /// Call once at app startup
    func initialize() {
        queue.async { [weak self] in
            self?.initializeSync()
        }
    }

    /// Append data to log file (thread-safe)
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            self?.appendSync(data)
        }
    }

    /// Append string to log file (thread-safe)
    func append(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        append(data)
    }

    /// Close file handle (call on app termination or process stop)
    func close() {
        queue.async { [weak self] in
            self?.closeSync()
        }
    }

    // MARK: - Private: Synchronous Operations (called on queue)

    private func initializeSync() {
        guard !isInitialized else { return }

        // Ensure log directory exists
        do {
            try FileManager.default.createDirectory(
                at: Self.logDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            TFLog.logWriter.error("Failed to create log directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Open or create log file
        openLogFile()
        isInitialized = true

        // Write startup marker
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let marker = "\n=== TidyFlow Core Log Started: \(timestamp) ===\n"
        if let data = marker.data(using: .utf8) {
            writeData(data)
        }
    }

    private func appendSync(_ data: Data) {
        // Lazy initialization if needed
        if !isInitialized {
            initializeSync()
        }

        // Check if rotation needed before writing
        rotateIfNeeded()

        // Write data
        writeData(data)
    }

    private func closeSync() {
        guard let handle = fileHandle else { return }

        // Write shutdown marker
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let marker = "\n=== TidyFlow Core Log Ended: \(timestamp) ===\n"
        if let data = marker.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }

        try? handle.synchronize()
        try? handle.close()
        fileHandle = nil
        isInitialized = false
    }

    // MARK: - Private: File Operations

    private func openLogFile() {
        let path = Self.logFilePath
        let fm = FileManager.default

        // Create file if it doesn't exist
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil, attributes: nil)
        }

        // Open for appending
        do {
            fileHandle = try FileHandle(forWritingTo: path)
            try fileHandle?.seekToEnd()

            // Get current file size
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? UInt64 {
                currentFileSize = size
            }
        } catch {
            TFLog.logWriter.error("Failed to open log file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeData(_ data: Data) {
        guard let handle = fileHandle else { return }

        do {
            try handle.write(contentsOf: data)
            currentFileSize += UInt64(data.count)
        } catch {
            TFLog.logWriter.error("Failed to write log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateIfNeeded() {
        guard currentFileSize >= Self.maxBytes else { return }

        // Close current file
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        let basePath = Self.logFilePath.path

        // Delete oldest file if it exists (core.4.log)
        let oldestPath = basePath.replacingOccurrences(of: ".log", with: ".\(Self.maxFiles - 1).log")
        try? fm.removeItem(atPath: oldestPath)

        // Rotate existing files: core.3.log -> core.4.log, etc.
        for i in stride(from: Self.maxFiles - 2, through: 1, by: -1) {
            let srcPath = basePath.replacingOccurrences(of: ".log", with: ".\(i).log")
            let dstPath = basePath.replacingOccurrences(of: ".log", with: ".\(i + 1).log")
            if fm.fileExists(atPath: srcPath) {
                try? fm.moveItem(atPath: srcPath, toPath: dstPath)
            }
        }

        // Rotate current file: core.log -> core.1.log
        let firstRotatedPath = basePath.replacingOccurrences(of: ".log", with: ".1.log")
        try? fm.moveItem(atPath: basePath, toPath: firstRotatedPath)

        // Create new empty log file and reopen
        currentFileSize = 0
        openLogFile()
    }
}
