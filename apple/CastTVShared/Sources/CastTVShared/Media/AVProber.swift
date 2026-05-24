import AVFoundation
import Foundation

/// Shared AVFoundation-based media probing logic used by both iOS and tvOS.
public enum AVProber {

    /// Probe a URL using AVFoundation. Works for native containers (MP4, MOV, HLS).
    /// For non-native containers (MKV, WebM, AVI), callers should use FFmpeg instead.
    public static func probe(url: URL, container: ContainerType) async throws -> ProbeResult {
        let asset = AVURLAsset(url: url)

        let (tracks, duration, metadata) = try await asset.load(.tracks, .duration, .commonMetadata)
        let durationSeconds = duration.seconds.isFinite ? duration.seconds : nil

        var title: String?
        if let titleItem = metadata.first(where: { $0.commonKey == .commonKeyTitle }) {
            title = try? await titleItem.load(.stringValue)
        }

        var videoTracks: [VideoTrackInfo] = []
        var audioTracks: [AudioTrackInfo] = []
        var subtitleTracks: [SubtitleTrackInfo] = []

        for (index, track) in tracks.enumerated() {
            switch track.mediaType {
            case .video:
                if let info = await extractVideoTrack(track, index: index) {
                    videoTracks.append(info)
                }
            case .audio:
                if let info = await extractAudioTrack(track, index: index) {
                    audioTracks.append(info)
                }
            case .subtitle, .closedCaption:
                if let info = await extractSubtitleTrack(track, index: index) {
                    subtitleTracks.append(info)
                }
            default: break
            }
        }

        // HLS variants
        var hlsVariants: [HLSVariant] = []
        let isHLS = container == .hls || url.pathExtension.lowercased() == "m3u8"
        if isHLS {
            hlsVariants = await extractHLSVariants(asset: asset)
        }

        // For HLS, tracks are often empty — extract from media selection groups
        if videoTracks.isEmpty && audioTracks.isEmpty && isHLS {
            let (hlsVideo, hlsAudio, hlsSubs) = await extractFromMediaSelections(asset: asset)
            videoTracks = hlsVideo
            audioTracks = hlsAudio
            subtitleTracks = hlsSubs
        }

        // If still no tracks, check if asset is playable
        if videoTracks.isEmpty && audioTracks.isEmpty {
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            if isPlayable {
                videoTracks = [VideoTrackInfo(id: 0, codec: .unknown, resolution: .zero, frameRate: 0)]
            } else {
                throw AVProberError.noTracks
            }
        }

        return ProbeResult(
            url: url, duration: durationSeconds, container: container, title: title,
            videoTracks: videoTracks, audioTracks: audioTracks,
            subtitleTracks: subtitleTracks, hlsVariants: hlsVariants
        )
    }

    public enum AVProberError: LocalizedError {
        case noTracks

        public var errorDescription: String? {
            switch self {
            case .noTracks: return "No media tracks found"
            }
        }
    }

    // MARK: - Video

    private static func extractVideoTrack(_ track: AVAssetTrack, index: Int) async -> VideoTrackInfo? {
        guard let (formatDescriptions, naturalSize, nominalFrameRate, estimatedDataRate, languageCode) =
                try? await track.load(.formatDescriptions, .naturalSize, .nominalFrameRate, .estimatedDataRate, .languageCode) else {
            return nil
        }

        var codec: VideoCodec = .unknown
        var bitDepth: Int?
        var colorSpace: String?
        var transferFunction: String?
        var isDolbyVision = false

        if let desc = formatDescriptions.first {
            let fourCC = fourCCString(CMFormatDescriptionGetMediaSubType(desc))
            codec = VideoCodec.from(fourCC: fourCC)

            if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                bitDepth = extensions[kCMFormatDescriptionExtension_Depth as String] as? Int
                colorSpace = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                transferFunction = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String

                if extensions["DolbyVisionConfigurationRecord"] != nil { isDolbyVision = true }
                if fourCC.lowercased().hasPrefix("dvh") || fourCC.lowercased().hasPrefix("dva") { isDolbyVision = true }
            }
        }

        return VideoTrackInfo(
            id: index, codec: codec, resolution: naturalSize, frameRate: nominalFrameRate,
            bitDepth: bitDepth, colorSpace: colorSpace, transferFunction: transferFunction,
            isDolbyVision: isDolbyVision,
            estimatedDataRate: estimatedDataRate > 0 ? Double(estimatedDataRate) : nil,
            language: languageCode
        )
    }

    // MARK: - Audio

    private static func extractAudioTrack(_ track: AVAssetTrack, index: Int) async -> AudioTrackInfo? {
        guard let (formatDescriptions, estimatedDataRate, languageCode) =
                try? await track.load(.formatDescriptions, .estimatedDataRate, .languageCode) else {
            return nil
        }

        var codec: AudioCodec = .unknown
        var channelCount = 0
        var channelLayout: String?
        var sampleRate: Double?

        if let desc = formatDescriptions.first {
            codec = AudioCodec.from(fourCC: fourCCString(CMFormatDescriptionGetMediaSubType(desc)))

            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
                sampleRate = asbd.pointee.mSampleRate
            }

            var layoutSize: Int = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &layoutSize) {
                let count = Int(layout.pointee.mNumberChannelDescriptions)
                switch layout.pointee.mChannelLayoutTag {
                case kAudioChannelLayoutTag_Stereo: channelLayout = "Stereo"
                case kAudioChannelLayoutTag_MPEG_5_1_A, kAudioChannelLayoutTag_MPEG_5_1_B,
                     kAudioChannelLayoutTag_MPEG_5_1_C, kAudioChannelLayoutTag_MPEG_5_1_D:
                    channelLayout = "5.1"
                case kAudioChannelLayoutTag_MPEG_7_1_A, kAudioChannelLayoutTag_MPEG_7_1_B,
                     kAudioChannelLayoutTag_MPEG_7_1_C:
                    channelLayout = "7.1"
                default:
                    channelLayout = "\(count > 0 ? count : channelCount)ch"
                }
            }
        }

        return AudioTrackInfo(
            id: index, codec: codec, channelCount: channelCount, channelLayout: channelLayout,
            sampleRate: sampleRate,
            estimatedDataRate: estimatedDataRate > 0 ? Double(estimatedDataRate) : nil,
            language: languageCode
        )
    }

    // MARK: - Subtitles

    private static func extractSubtitleTrack(_ track: AVAssetTrack, index: Int) async -> SubtitleTrackInfo? {
        guard let (formatDescriptions, languageCode) =
                try? await track.load(.formatDescriptions, .languageCode) else {
            return nil
        }

        var format: SubtitleFormat = .unknown
        var isForced = false

        if let desc = formatDescriptions.first {
            format = SubtitleFormat.from(fourCC: fourCCString(CMFormatDescriptionGetMediaSubType(desc)))

            if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                if let forced = extensions["forced"] as? Bool {
                    isForced = forced
                }
            }
        }

        return SubtitleTrackInfo(id: index, format: format, language: languageCode, isForced: isForced)
    }

    // MARK: - HLS

    private static func extractHLSVariants(asset: AVURLAsset) async -> [HLSVariant] {
        guard let variants = try? await asset.load(.variants) else { return [] }

        return variants.map { variant in
            HLSVariant(
                resolution: variant.videoAttributes?.presentationSize,
                peakBitRate: variant.peakBitRate.flatMap { $0 > 0 ? $0 : nil },
                averageBitRate: variant.averageBitRate.flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    private static func extractFromMediaSelections(asset: AVURLAsset) async -> ([VideoTrackInfo], [AudioTrackInfo], [SubtitleTrackInfo]) {
        var videoTracks: [VideoTrackInfo] = []
        var audioTracks: [AudioTrackInfo] = []
        var subtitleTracks: [SubtitleTrackInfo] = []

        guard let characteristics = try? await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions) else {
            return (videoTracks, audioTracks, subtitleTracks)
        }

        var audioIndex = 0
        var subtitleIndex = 0

        for characteristic in characteristics {
            guard let group = try? await asset.loadMediaSelectionGroup(for: characteristic) else { continue }

            for option in group.options {
                let lang = option.locale?.languageCode

                if option.mediaType == .audio {
                    audioTracks.append(AudioTrackInfo(
                        id: audioIndex, codec: .aac, channelCount: 2,
                        channelLayout: nil, sampleRate: nil, language: lang
                    ))
                    audioIndex += 1
                } else if option.mediaType == .subtitle || option.mediaType == .closedCaption {
                    subtitleTracks.append(SubtitleTrackInfo(
                        id: subtitleIndex + 100, format: .webvtt, language: lang,
                        isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                    ))
                    subtitleIndex += 1
                }
            }
        }

        if let variants = try? await asset.load(.variants), let first = variants.first {
            let resolution = first.videoAttributes?.presentationSize ?? .zero
            videoTracks.append(VideoTrackInfo(id: 0, codec: .hevc, resolution: resolution, frameRate: 0))
        } else {
            videoTracks.append(VideoTrackInfo(id: 0, codec: .unknown, resolution: .zero, frameRate: 0))
        }

        return (videoTracks, audioTracks, subtitleTracks)
    }

    // MARK: - Helpers

    public static func fourCCString(_ code: FourCharCode) -> String {
        String([
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ].map { Character(UnicodeScalar($0)) })
    }
}
