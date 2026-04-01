import Foundation
import FFmpegKit
import CastTVShared
import os

private let logger = Logger(subsystem: "com.casttv.tvos", category: "RemuxService")

/// Coordinates the full remux pipeline: FFmpeg demux -> segment files -> HTTP server -> AVPlayer.
///
/// FFmpeg's HLS muxer produces stream.m3u8 + segment_N.ts files in a temp directory.
/// The local HTTP server serves those files directly to AVPlayer.
@MainActor
final class RemuxService: ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case running
        case finished
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progressSeconds: Double = 0
    @Published private(set) var totalSeconds: Double?

    private var server: LocalServer?
    private var storage: SegmentStorage?
    private var remuxer: FFRemuxer?
    private var remuxTask: Task<Void, Never>?
    private var currentSourceURL: String?
    private var currentVideoIndex: Int = 0
    private var currentAudioIndex: Int = 0
    private var currentSubtitleIndex: Int?
    private var currentTranscodeAudio: Bool = false
    private var currentSubtitleFormat: String = "webvtt"
    private var nextSegmentIndex: Int = 0

    /// The URL that AVPlayer should play from.
    var playbackURL: URL? {
        guard let server else { return nil }
        return URL(string: "\(server.baseURL)/stream.m3u8")
    }

    /// Direct access to the storage directory for reading files without going through HTTP.
    var storageDirectory: URL? {
        storage?.directory
    }

    /// Whether PGS bitmap subtitles were extracted and are available for overlay rendering.
    @Published private(set) var pgsManifest: PGSManifest?

    /// Start the remux pipeline for a source URL.
    func start(
        sourceURL: String,
        videoStreamIndex: Int,
        audioStreamIndex: Int,
        subtitleStreamIndex: Int? = nil,
        transcodeAudio: Bool = false,
        subtitleFormat: String = "webvtt"
    ) {
        stop()

        state = .starting
        currentSourceURL = sourceURL
        currentVideoIndex = videoStreamIndex
        currentAudioIndex = audioStreamIndex
        currentSubtitleIndex = subtitleStreamIndex
        currentTranscodeAudio = transcodeAudio
        currentSubtitleFormat = subtitleFormat
        nextSegmentIndex = 0
        logger.notice("Starting remux: \(sourceURL) (video=\(videoStreamIndex), audio=\(audioStreamIndex), transcode=\(transcodeAudio))")

        do {
            let storage = try SegmentStorage()
            self.storage = storage

            let server = try LocalServer()
            self.server = server

            server.requestHandler = { [storage] path in
                RemuxService.handleRequest(path: path, storage: storage)
            }
            server.start()

            let remuxConfig = FFRemuxer.Configuration(
                sourceURL: sourceURL,
                outputDirectory: storage.directory.path,
                videoStreamIndex: videoStreamIndex,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                transcodeAudio: transcodeAudio,
                segmentDuration: 6
            )

            let remuxer = FFRemuxer(configuration: remuxConfig, callbacks: makeCallbacks())
            self.remuxer = remuxer

            state = .running
            CastTVLogger.shared.info("Remux starting: \(sourceURL)")

            // Convert subtitles if requested
            if let subIndex = subtitleStreamIndex {
                let srcURL = sourceURL
                let stor = storage
                let subFmt = subtitleFormat
                Task.detached { [weak self] in
                    do {
                        if subFmt == "pgs_images" {
                            let events = try PGSExtractor.extract(sourceURL: srcURL, streamIndex: subIndex)
                            var manifestEntries: [PGSManifest.Entry] = []

                            for (i, event) in events.enumerated() {
                                let filename = "pgs_\(i).png"
                                try stor.writeBinaryFile(filename: filename, data: event.pngData)
                                manifestEntries.append(PGSManifest.Entry(
                                    index: i,
                                    start: event.start,
                                    end: event.end,
                                    x: event.x,
                                    y: event.y,
                                    width: event.width,
                                    height: event.height,
                                    filename: filename
                                ))
                            }

                            let manifest = PGSManifest(entries: manifestEntries)
                            logger.notice("PGS subtitles extracted: \(events.count) bitmaps")
                            await MainActor.run { [weak self] in
                                self?.pgsManifest = manifest
                            }
                        } else {
                            let vtt = try SubtitleConverter.convert(sourceURL: srcURL, streamIndex: subIndex)
                            try stor.writeSubtitle(filename: "subtitles.vtt", content: vtt)
                            logger.notice("Subtitles converted (\(vtt.count) chars)")
                        }
                    } catch {
                        logger.error("Subtitle conversion failed: \(error)")
                    }
                }
            }

            // Run remux on background thread
            remuxTask = Task.detached { [weak remuxer] in
                remuxer?.start()
            }

            logger.notice("Pipeline running, URL: \(server.baseURL)/stream.m3u8")

        } catch {
            state = .error("Failed to start: \(error.localizedDescription)")
            logger.error("Pipeline start failed: \(error)")
        }
    }

    /// Seek to a new position during remuxed playback.
    func seekTo(timeSeconds: Double) {
        guard let sourceURL = currentSourceURL, state == .running || state == .finished else { return }

        logger.notice("Seeking to \(String(format: "%.1f", timeSeconds))s")

        // Stop current remuxer but keep server and storage alive
        remuxer?.cancel()
        remuxTask?.cancel()
        remuxTask = nil
        remuxer = nil

        // Clean segment files so FFmpeg starts fresh
        storage?.removeAll()

        guard let storage else { return }

        let remuxConfig = FFRemuxer.Configuration(
            sourceURL: sourceURL,
            outputDirectory: storage.directory.path,
            videoStreamIndex: currentVideoIndex,
            audioStreamIndex: currentAudioIndex,
            subtitleStreamIndex: currentSubtitleIndex,
            transcodeAudio: currentTranscodeAudio,
            segmentDuration: 6,
            startTimeSeconds: timeSeconds,
            segmentStartIndex: nextSegmentIndex
        )

        let remuxer = FFRemuxer(configuration: remuxConfig, callbacks: makeCallbacks())
        self.remuxer = remuxer

        state = .running

        remuxTask = Task.detached { [weak remuxer] in
            remuxer?.start()
        }
    }

    func stop() {
        remuxer?.cancel()
        remuxTask?.cancel()
        remuxTask = nil
        remuxer = nil
        server?.stop()
        server = nil
        storage?.removeAll()
        storage = nil
        state = .idle
        progressSeconds = 0
        totalSeconds = nil
        pgsManifest = nil
        currentSourceURL = nil
        nextSegmentIndex = 0
    }

    // MARK: - Callbacks

    private func makeCallbacks() -> FFRemuxer.Callbacks {
        var cb = FFRemuxer.Callbacks()
        cb.onSegment = { [weak self] index, _, duration in
            Task { @MainActor [weak self] in
                self?.nextSegmentIndex = index + 1
                CastTVLogger.shared.info("Segment \(index) ready (\(String(format: "%.1f", duration))s)")
            }
        }

        cb.onProgress = { [weak self] time, total in
            Task { @MainActor [weak self] in
                self?.progressSeconds = time
                self?.totalSeconds = total
            }
        }

        cb.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.state = .finished
                logger.notice("Remux finished")
                CastTVLogger.shared.info("Remux finished")
            }
        }

        cb.onError = { [weak self] error in
            if case .cancelled = error { return }
            Task { @MainActor [weak self] in
                let msg = error.localizedDescription ?? "Unknown error"
                self?.state = .error(msg)
                logger.error("Remux error: \(msg)")
                CastTVLogger.shared.error("Remux error: \(msg)")
            }
        }

        cb.onLog = { message in
            CastTVLogger.shared.info("[FFmpeg] \(message)")
        }

        return cb
    }

    // MARK: - HTTP Request Handler

    /// Serves files directly from the temp directory.
    /// FFmpeg's HLS muxer produces stream.m3u8 + segment_N.ts files.
    private static nonisolated func handleRequest(path: String, storage: SegmentStorage) -> (Int, String, Data) {
        let cleanPath = path.components(separatedBy: "?").first ?? path
        let filename = String(cleanPath.dropFirst()) // remove leading /

        guard let data = storage.readFile(named: filename) else {
            return (404, "text/plain", Data("Not Found".utf8))
        }

        let contentType: String
        if filename.hasSuffix(".m3u8") {
            contentType = "application/vnd.apple.mpegurl"
        } else if filename.hasSuffix(".ts") {
            contentType = "video/mp2t"
        } else if filename.hasSuffix(".vtt") {
            contentType = "text/vtt"
        } else {
            contentType = "application/octet-stream"
        }
        return (200, contentType, data)
    }
}
