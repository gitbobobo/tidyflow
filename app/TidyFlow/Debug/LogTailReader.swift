import Foundation

/// Efficient log file tail reader
/// Reads only the last N bytes of a file to extract recent lines
final class LogTailReader {
    /// Default max bytes to read from end of file (128KB)
    static let defaultMaxBytes: Int = 128 * 1024

    /// Default number of lines to return
    static let defaultMaxLines: Int = 300

    /// Read the tail of a log file efficiently
    /// - Parameters:
    ///   - url: File URL to read
    ///   - maxBytes: Maximum bytes to read from end (default 128KB)
    ///   - maxLines: Maximum lines to return (default 300)
    /// - Returns: String containing the last N lines, or error message
    static func readTail(
        url: URL,
        maxBytes: Int = defaultMaxBytes,
        maxLines: Int = defaultMaxLines
    ) -> String {
        let fm = FileManager.default

        // Check file exists
        guard fm.fileExists(atPath: url.path) else {
            return "[Log file not found: \(url.path)]"
        }

        // Get file size
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64 else {
            return "[Cannot read file attributes]"
        }

        // If file is empty
        if fileSize == 0 {
            return "[Log file is empty]"
        }

        // Open file handle
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return "[Cannot open log file]"
        }
        defer { try? handle.close() }

        // Calculate read position
        let bytesToRead = min(Int(fileSize), maxBytes)
        let startOffset = UInt64(max(0, Int(fileSize) - bytesToRead))

        do {
            // Seek to position
            try handle.seek(toOffset: startOffset)

            // Read data
            guard let data = try handle.read(upToCount: bytesToRead) else {
                return "[Failed to read log data]"
            }

            // Decode with replacement for invalid UTF-8
            let text = decodeWithReplacement(data)

            // Split into lines and take last N
            var lines = text.components(separatedBy: .newlines)

            // If we started mid-file, first line may be partial - remove it
            if startOffset > 0 && !lines.isEmpty {
                lines.removeFirst()
            }

            // Remove empty trailing lines
            while lines.last?.isEmpty == true {
                lines.removeLast()
            }

            // Take last maxLines
            if lines.count > maxLines {
                lines = Array(lines.suffix(maxLines))
            }

            return lines.joined(separator: "\n")
        } catch {
            return "[Error reading log: \(error.localizedDescription)]"
        }
    }

    /// Decode data to string with replacement character for invalid UTF-8
    private static func decodeWithReplacement(_ data: Data) -> String {
        // Try direct UTF-8 first
        if let str = String(data: data, encoding: .utf8) {
            return str
        }

        // Fallback: decode byte by byte with replacement
        var result = ""
        var index = data.startIndex

        while index < data.endIndex {
            // Try to decode a valid UTF-8 sequence
            var length = 1
            if data[index] & 0x80 == 0 {
                length = 1
            } else if data[index] & 0xE0 == 0xC0 {
                length = 2
            } else if data[index] & 0xF0 == 0xE0 {
                length = 3
            } else if data[index] & 0xF8 == 0xF0 {
                length = 4
            }

            let endIndex = data.index(index, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
            let subdata = data[index..<endIndex]

            if let char = String(data: subdata, encoding: .utf8) {
                result += char
            } else {
                result += "\u{FFFD}" // Replacement character
            }

            index = endIndex
        }

        return result
    }
}
