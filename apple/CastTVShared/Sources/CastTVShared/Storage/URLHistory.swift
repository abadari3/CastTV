import CryptoKit
import Foundation

/// A history entry with optional metadata from probing.
/// Cover art is stored on disk, not in UserDefaults.
public struct URLHistoryEntry: Codable, Identifiable, Sendable {
    public var id: String { url }
    public let url: String
    public let title: String?
    public let hasCoverArt: Bool
    public let addedAt: Date

    public init(url: String, title: String? = nil, hasCoverArt: Bool = false, addedAt: Date = Date()) {
        self.url = url
        self.title = title
        self.hasCoverArt = hasCoverArt
        self.addedAt = addedAt
    }

    /// Load cover art from the file cache. Returns nil if not available.
    public var coverArt: Data? {
        guard hasCoverArt else { return nil }
        return CoverArtCache.load(for: url)
    }
}

/// File-based cache for cover art images, keyed by URL hash.
enum CoverArtCache {
    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("casttv-cover-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func save(_ data: Data, for url: String) {
        let path = filePath(for: url)
        try? data.write(to: path)
    }

    static func load(for url: String) -> Data? {
        let path = filePath(for: url)
        return try? Data(contentsOf: path)
    }

    static func remove(for url: String) {
        let path = filePath(for: url)
        try? FileManager.default.removeItem(at: path)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func filePath(for url: String) -> URL {
        let hash = SHA256.hash(data: Data(url.utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hex)
    }
}

/// Persists recently cast URLs on the iPhone.
public final class URLHistory: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.casttv.url_history_v3"
    private let legacyKey = "com.casttv.url_history"
    private let legacyV2Key = "com.casttv.url_history_v2"
    private let maxEntries = 50

    public static let shared = URLHistory()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacy()
        migrateV2()
    }

    /// Add or update a URL in history (moves to top).
    public func add(_ url: String, title: String? = nil, coverArt: Data? = nil) {
        var entries = loadEntries()

        // Remove old cover art if replacing
        if let existing = entries.first(where: { $0.url == url }), existing.hasCoverArt {
            CoverArtCache.remove(for: url)
        }
        entries.removeAll { $0.url == url }

        // Save cover art to file cache
        let hasCover = coverArt != nil
        if let coverArt { CoverArtCache.save(coverArt, for: url) }

        let entry = URLHistoryEntry(url: url, title: title, hasCoverArt: hasCover)
        entries.insert(entry, at: 0)

        // Evict old entries and their cover art
        if entries.count > maxEntries {
            let evicted = entries.suffix(from: maxEntries)
            for entry in evicted where entry.hasCoverArt {
                CoverArtCache.remove(for: entry.url)
            }
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
    }

    /// Load all history entries, most recent first.
    public func loadEntries() -> [URLHistoryEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([URLHistoryEntry].self, from: data)) ?? []
    }

    /// Load just the URLs (backward compat).
    public func load() -> [String] {
        loadEntries().map(\.url)
    }

    /// Remove a single entry.
    public func remove(_ url: String) {
        var entries = loadEntries()
        if let entry = entries.first(where: { $0.url == url }), entry.hasCoverArt {
            CoverArtCache.remove(for: url)
        }
        entries.removeAll { $0.url == url }
        save(entries)
    }

    /// Clear all history.
    public func clearAll() {
        defaults.removeObject(forKey: key)
        CoverArtCache.removeAll()
    }

    private func save(_ entries: [URLHistoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    /// Migrate from old string-array format (v1).
    private func migrateLegacy() {
        guard let old = defaults.stringArray(forKey: legacyKey), !old.isEmpty else { return }
        if loadEntries().isEmpty {
            let entries = old.map { URLHistoryEntry(url: $0) }
            save(entries)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    /// Migrate from v2 format (cover art inline in UserDefaults).
    private func migrateV2() {
        guard let data = defaults.data(forKey: legacyV2Key) else { return }

        // V2 entries had coverArt as inline Data
        struct V2Entry: Codable {
            let url: String
            let title: String?
            let coverArt: Data?
            let addedAt: Date
        }

        guard let oldEntries = try? JSONDecoder().decode([V2Entry].self, from: data) else { return }
        if loadEntries().isEmpty {
            let newEntries = oldEntries.map { old -> URLHistoryEntry in
                if let art = old.coverArt {
                    CoverArtCache.save(art, for: old.url)
                }
                return URLHistoryEntry(url: old.url, title: old.title, hasCoverArt: old.coverArt != nil, addedAt: old.addedAt)
            }
            save(newEntries)
        }
        defaults.removeObject(forKey: legacyV2Key)
    }
}
