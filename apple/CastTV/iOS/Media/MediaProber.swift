import Foundation
import AVFoundation
import CastTVShared
import FFmpegKit

enum ProbeError: LocalizedError {
    case invalidURL
    case loadFailed(Error)
    case noTracks
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .loadFailed(let error): return "Failed to load: \(error.localizedDescription)"
        case .noTracks: return "No media tracks found"
        case .timeout: return "Probe timed out"
        }
    }
}

enum MediaProber {

    /// File extensions that AVFoundation cannot open — go straight to FFmpeg.
    private static let nonNativeExtensions: Set<String> = ["mkv", "webm", "avi", "ts", "mts", "m2ts", "ogg", "ogm"]

    static func probe(url: URL) async throws -> ProbeResult {
        let ext = url.pathExtension.lowercased()
        let container = ContainerType.from(url: url)

        // For non-native containers, use FFmpeg directly
        if nonNativeExtensions.contains(ext) || !container.isNativelySupported {
            return try probeWithFFmpeg(url: url, container: container)
        }

        // For native containers, try AVFoundation first
        do {
            return try await AVProber.probe(url: url, container: container)
        } catch {
            // AVFoundation failed — fall back to FFmpeg
            return try probeWithFFmpeg(url: url, container: container)
        }
    }

    // MARK: - FFmpeg Probe Path

    private static func probeWithFFmpeg(url: URL, container: ContainerType) throws -> ProbeResult {
        let result = try FFProber.probe(url: url)

        let videoTracks = result.videoTracks.map { v in
            VideoTrackInfo(
                id: v.index,
                codec: VideoCodec.from(ffmpegName: v.codecName),
                resolution: CGSize(width: v.width, height: v.height),
                frameRate: Float(v.frameRate),
                bitDepth: v.bitDepth,
                colorSpace: v.colorPrimaries,
                transferFunction: v.transferCharacteristic,
                isDolbyVision: v.isDolbyVision,
                estimatedDataRate: v.bitRate.map { Double($0) },
                language: v.language
            )
        }

        let audioTracks = result.audioTracks.map { a in
            AudioTrackInfo(
                id: a.index,
                codec: AudioCodec.from(ffmpegName: a.codecName),
                channelCount: a.channelCount,
                channelLayout: a.channelLayout,
                sampleRate: Double(a.sampleRate),
                estimatedDataRate: a.bitRate.map { Double($0) },
                language: a.language
            )
        }

        let subtitleTracks = result.subtitleTracks.map { s in
            SubtitleTrackInfo(
                id: s.index,
                format: SubtitleFormat.from(ffmpegName: s.codecName),
                language: s.language,
                isForced: s.isForced
            )
        }

        return ProbeResult(
            url: url,
            duration: result.duration,
            container: container,
            title: result.title,
            coverArt: result.coverArt,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks
        )
    }

}
