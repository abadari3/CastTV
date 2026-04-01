import Foundation

/// Structured logging with file persistence and real-time streaming.
public final class CastTVLogger: @unchecked Sendable {
    public static let shared = CastTVLogger()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var fileHandle: FileHandle?
    private let logFileURL: URL
    private let maxFileSize = 1_000_000 // 1 MB
    private let maxEntries = 5000
    private var _cachedPreviousEntries: [LogEntry]?

    /// Called when a new log entry is created. Set this to stream logs via WebSocket.
    public var onNewEntry: ((LogMessage) -> Void)? {
        get { lock.withLock { _onNewEntry } }
        set { lock.withLock { _onNewEntry = newValue } }
    }
    private var _onNewEntry: ((LogMessage) -> Void)?

    /// Session start time for log history.
    public let sessionStart = Date()

    public struct LogEntry: Codable, Sendable {
        public let timestamp: Date
        public let level: LogLevel
        public let message: String
    }

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        logFileURL = cacheDir.appendingPathComponent("casttv.log")
        openLogFile()
    }

    public func info(_ message: String) {
        log(level: .info, message: message)
    }

    public func warning(_ message: String) {
        log(level: .warning, message: message)
    }

    public func error(_ message: String) {
        log(level: .error, message: message)
    }

    public func log(level: LogLevel, message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)

        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        let callback = _onNewEntry
        lock.unlock()

        // Write to file
        writeToFile(entry)

        // Notify listener (for WebSocket streaming)
        let logMsg = LogMessage(timestamp: entry.timestamp, level: level, message: message)
        callback?(logMsg)
    }

    /// Get all entries from the current session.
    public func currentSessionEntries() -> [LogMessage] {
        lock.lock()
        let current = entries
        lock.unlock()
        return current.map { LogMessage(timestamp: $0.timestamp, level: $0.level, message: $0.message) }
    }

    /// Get entries from the previous session (parsed once at first access, then cached).
    public func previousSessionEntries() -> [LogEntry] {
        lock.lock()
        if let cached = _cachedPreviousEntries {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let data = try? Data(contentsOf: logFileURL),
              let content = String(data: data, encoding: .utf8) else {
            lock.lock()
            _cachedPreviousEntries = []
            lock.unlock()
            return []
        }

        // Parse log lines: each line is JSON
        let entries = content.components(separatedBy: "\n").compactMap { line -> LogEntry? in
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(LogEntry.self, from: lineData) else { return nil }
            return entry
        }
        lock.lock()
        _cachedPreviousEntries = entries
        lock.unlock()
        return entries
    }

    /// Clear all in-memory entries and the log file.
    public func clearAll() {
        lock.lock()
        entries.removeAll()
        _cachedPreviousEntries = nil
        lock.unlock()

        // Truncate the log file
        fileHandle?.closeFile()
        fileHandle = nil
        try? FileManager.default.removeItem(at: logFileURL)
        let oldURL = logFileURL.deletingPathExtension().appendingPathExtension("log.old")
        try? FileManager.default.removeItem(at: oldURL)
        openLogFile()
    }

    // MARK: - File Management

    private func openLogFile() {
        // Rotate if too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            // Rotate: move to .log.old, start fresh
            let oldURL = logFileURL.deletingPathExtension().appendingPathExtension("log.old")
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.moveItem(at: logFileURL, to: oldURL)
        }

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ entry: LogEntry) {
        guard let data = try? JSONEncoder().encode(entry),
              let newline = "\n".data(using: .utf8) else { return }
        lock.lock()
        fileHandle?.write(data)
        fileHandle?.write(newline)
        lock.unlock()
    }
}
