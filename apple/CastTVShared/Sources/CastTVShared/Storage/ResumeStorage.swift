import Foundation

/// Persists playback positions keyed by URL for resume functionality.
public final class ResumeStorage: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.casttv.resume_positions"
    private let orderKey = "com.casttv.resume_order"
    private let maxEntries = 100

    public static let shared = ResumeStorage()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Save playback position for a URL.
    public func save(position: TimeInterval, for url: String) {
        var positions = loadAll()
        var order = defaults.stringArray(forKey: orderKey) ?? []

        positions[url] = position

        // Move to end (most recent)
        order.removeAll { $0 == url }
        order.append(url)

        // Evict oldest entries beyond the cap
        while order.count > maxEntries {
            let oldest = order.removeFirst()
            positions.removeValue(forKey: oldest)
        }

        defaults.set(positions, forKey: key)
        defaults.set(order, forKey: orderKey)
    }

    /// Load saved playback position for a URL. Returns nil if none saved.
    public func load(for url: String) -> TimeInterval? {
        let positions = loadAll()
        return positions[url]
    }

    /// Clear saved position (e.g., when playback reaches the end).
    public func clear(for url: String) {
        var positions = loadAll()
        positions.removeValue(forKey: url)
        defaults.set(positions, forKey: key)

        var order = defaults.stringArray(forKey: orderKey) ?? []
        order.removeAll { $0 == url }
        defaults.set(order, forKey: orderKey)
    }

    private func loadAll() -> [String: TimeInterval] {
        (defaults.dictionary(forKey: key) as? [String: TimeInterval]) ?? [:]
    }
}
