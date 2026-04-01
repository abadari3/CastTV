import Foundation

/// Describes a set of extracted PGS bitmap subtitles, used to synchronize
/// image overlay display with AVPlayer playback.
struct PGSManifest: Sendable {

    struct Entry: Sendable {
        let index: Int
        let start: Double
        let end: Double
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let filename: String
    }

    let entries: [Entry]

    /// Find the entry that should be displayed at the given playback time.
    /// Returns nil if no subtitle should be visible.
    func entry(at time: Double) -> Entry? {
        // Binary search for efficiency (entries are sorted by start time)
        var lo = 0
        var hi = entries.count - 1
        var best: Entry?

        while lo <= hi {
            let mid = (lo + hi) / 2
            let entry = entries[mid]
            if entry.start <= time {
                if time < entry.end {
                    best = entry
                }
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}
