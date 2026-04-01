import Foundation
import os

private let logger = Logger(subsystem: "com.casttv.tvos", category: "SegmentStorage")

/// Manages temporary .ts segment files and subtitle files on disk.
///
/// Handles writing new segments, reading them for serving, and cleaning up
/// old segments outside the sliding window.
final class SegmentStorage: @unchecked Sendable {

    let directory: URL
    private let lock = NSLock()
    private var segmentFiles: Set<String> = []

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("casttv-hls", isDirectory: true)
        // Clean any stale files from previous sessions
        if FileManager.default.fileExists(atPath: tmp.path) {
            try? FileManager.default.removeItem(at: tmp)
        }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.directory = tmp
        logger.notice("Segment storage (clean): \(tmp.path)")
    }

    /// Write a segment file. Returns the filename.
    @discardableResult
    func writeSegment(index: Int, data: Data) throws -> String {
        let filename = "segment_\(index).ts"
        let path = directory.appendingPathComponent(filename)
        try data.write(to: path)

        lock.lock()
        segmentFiles.insert(filename)
        lock.unlock()

        logger.debug("Wrote \(filename) (\(data.count) bytes)")
        return filename
    }

    /// Read a segment or other file by filename.
    /// Uses memory mapping to avoid copying large segment files into heap memory.
    func readFile(named filename: String) -> Data? {
        let path = directory.appendingPathComponent(filename)
        return try? Data(contentsOf: path, options: .mappedIfSafe)
    }

    /// Write a subtitle file (WebVTT).
    func writeSubtitle(filename: String, content: String) throws {
        let path = directory.appendingPathComponent(filename)
        try content.write(to: path, atomically: true, encoding: .utf8)
        logger.debug("Wrote subtitle \(filename)")
    }

    /// Write a binary file (e.g. PGS subtitle PNG image).
    func writeBinaryFile(filename: String, data: Data) throws {
        let path = directory.appendingPathComponent(filename)
        try data.write(to: path)
        logger.debug("Wrote \(filename) (\(data.count) bytes)")
    }

    /// Remove segments not in the given set of current indices.
    func cleanupExcept(currentIndices: Set<Int>) {
        lock.lock()
        let allFiles = segmentFiles
        lock.unlock()

        let currentFilenames = Set(currentIndices.map { "segment_\($0).ts" })
        let toRemove = allFiles.subtracting(currentFilenames)

        for filename in toRemove {
            let path = directory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: path)
        }

        lock.lock()
        segmentFiles.subtract(toRemove)
        lock.unlock()

        if !toRemove.isEmpty {
            logger.debug("Cleaned up \(toRemove.count) old segments")
        }
    }

    /// Remove HLS segment and playlist files, preserving PGS subtitle images.
    /// Used during seek to let FFmpeg start fresh without losing extracted subtitles.
    func removeHLSFiles() {
        lock.lock()
        let allFiles = segmentFiles
        segmentFiles.removeAll()
        lock.unlock()

        for filename in allFiles {
            let path = directory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: path)
        }

        // Remove playlist files
        let playlistPath = directory.appendingPathComponent("stream.m3u8")
        try? FileManager.default.removeItem(at: playlistPath)

        logger.notice("Removed HLS segments and playlists")
    }

    /// Remove all files (segments, subtitles, PGS images) and reset.
    func removeAll() {
        lock.lock()
        segmentFiles.removeAll()
        lock.unlock()

        if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }

        logger.notice("Removed all files")
    }
}
