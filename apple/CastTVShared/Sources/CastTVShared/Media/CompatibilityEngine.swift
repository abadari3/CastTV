import Foundation

// MARK: - Compatibility Status

public enum TrackCompatibility: Sendable {
    /// Fully supported, direct playback
    case native
    /// Fixable on-device (remux, audio transcode, subtitle conversion) — V2
    case needsProcessing(String)
    /// Cannot play
    case unsupported(String)

    public var isGreen: Bool { if case .native = self { return true } else { return false } }
    public var isYellow: Bool { if case .needsProcessing = self { return true } else { return false } }
    public var isRed: Bool { if case .unsupported = self { return true } else { return false } }

    public var label: String {
        switch self {
        case .native: return "Supported"
        case .needsProcessing(let reason): return reason
        case .unsupported(let reason): return reason
        }
    }
}

public enum CastReadiness: Sendable {
    case ready
    case needsProcessing
    case unsupported
}

// MARK: - Compatibility Engine

public enum CompatibilityEngine {

    /// Check a video track against device capabilities.
    public static func check(video: VideoTrackInfo, container: ContainerType, capabilities: CapabilitiesMessage?) -> TrackCompatibility {
        // Android TV: ExoPlayer handles all containers and codecs natively
        if capabilities?.isAndroidTV == true { return .native }

        // Check video codec
        switch video.codec {
        case .h264:
            break // Always supported
        case .hevc:
            if video.isDolbyVision {
                if let caps = capabilities, !caps.display.hdrModes.contains("dolbyVision") {
                    return .needsProcessing("Dolby Vision not supported — will be tone-mapped")
                }
            }
        case .vp9:
            // VP9 only in MP4 container on Apple TV 4K
            if container != .mp4 {
                return .unsupported("VP9 only supported in MP4 container")
            }
        case .vp8, .av1:
            return .unsupported("Unsupported video codec: \(video.codec.rawValue)")
        case .unknown:
            return .unsupported("Unknown video codec")
        }

        // Check container
        if !container.isNativelySupported {
            return .needsProcessing("Container \(container.rawValue) needs remux")
        }

        return .native
    }

    /// Check an audio track against device capabilities.
    public static func check(audio: AudioTrackInfo, container: ContainerType, capabilities: CapabilitiesMessage? = nil) -> TrackCompatibility {
        // Android TV: ExoPlayer handles all audio codecs natively
        if capabilities?.isAndroidTV == true { return .native }

        switch audio.codec {
        case .aac, .mp3, .ac3, .eac3, .pcm:
            if !container.isNativelySupported {
                return .needsProcessing("Container \(container.rawValue) needs remux")
            }
            return .native
        case .truehd:
            return .needsProcessing("TrueHD audio needs transcoding to AAC")
        case .dts, .dtsHD:
            return .needsProcessing("DTS audio needs transcoding to AAC")
        case .flac:
            return .needsProcessing("FLAC audio needs transcoding to AAC")
        case .opus:
            return .needsProcessing("Opus audio needs transcoding to AAC")
        case .vorbis:
            return .needsProcessing("Vorbis audio needs transcoding to AAC")
        case .unknown:
            return .unsupported("Unknown audio codec")
        }
    }

    /// Check a subtitle track against device capabilities.
    public static func check(subtitle: SubtitleTrackInfo, capabilities: CapabilitiesMessage? = nil) -> TrackCompatibility {
        // Android TV: ExoPlayer handles SRT, ASS, PGS natively
        if capabilities?.isAndroidTV == true {
            if subtitle.format == .unknown { return .unsupported("Unknown subtitle format") }
            return .native
        }

        switch subtitle.format {
        case .webvtt, .cea608, .cea708, .movText:
            return .native
        case .srt:
            return .needsProcessing("SRT needs conversion to WebVTT")
        case .ass:
            return .needsProcessing("ASS needs conversion to WebVTT (styling will be lost)")
        case .pgs:
            return .unsupported("PGS bitmap subtitles not supported (requires OCR)")
        case .unknown:
            return .unsupported("Unknown subtitle format")
        }
    }

    /// Compute overall cast readiness from selected track compatibilities.
    public static func overallStatus(_ compatibilities: [TrackCompatibility]) -> CastReadiness {
        if compatibilities.contains(where: { $0.isRed }) {
            return .unsupported
        }
        if compatibilities.contains(where: { $0.isYellow }) {
            return .needsProcessing
        }
        return .ready
    }

    /// Compute compatibilities for the currently selected tracks.
    public static func selectedCompatibilities(
        result: ProbeResult,
        selectedVideoID: Int?,
        selectedAudioID: Int?,
        selectedSubtitleID: Int?,
        capabilities: CapabilitiesMessage?
    ) -> [TrackCompatibility] {
        var compats: [TrackCompatibility] = []
        if let vid = result.videoTracks.first(where: { $0.id == selectedVideoID }) {
            compats.append(check(video: vid, container: result.container, capabilities: capabilities))
        }
        if let aud = result.audioTracks.first(where: { $0.id == selectedAudioID }) {
            compats.append(check(audio: aud, container: result.container, capabilities: capabilities))
        }
        if let sub = result.subtitleTracks.first(where: { $0.id == selectedSubtitleID }) {
            compats.append(check(subtitle: sub, capabilities: capabilities))
        }
        return compats
    }

    /// Compute processing requirements for the selected tracks. Returns nil if no processing needed.
    public static func computeProcessing(
        result: ProbeResult,
        selectedVideoID: Int?,
        selectedAudioID: Int?,
        selectedSubtitleID: Int?,
        capabilities: CapabilitiesMessage?
    ) -> ProcessingRequirements? {
        let compats = selectedCompatibilities(
            result: result,
            selectedVideoID: selectedVideoID,
            selectedAudioID: selectedAudioID,
            selectedSubtitleID: selectedSubtitleID,
            capabilities: capabilities
        )
        let status = overallStatus(compats)

        guard status == .needsProcessing else { return nil }

        let needsRemux = !result.container.isNativelySupported

        var audioTranscode: ProcessingRequirements.AudioTranscodeReq?
        if let audioID = selectedAudioID,
           let audio = result.audioTracks.first(where: { $0.id == audioID }) {
            let audioCompat = check(audio: audio, container: result.container, capabilities: capabilities)
            if audioCompat.isYellow {
                switch audio.codec {
                case .dts, .dtsHD, .truehd, .flac, .opus, .vorbis:
                    audioTranscode = .init(trackId: audioID)
                default:
                    break
                }
            }
        }

        var subtitleConvert: ProcessingRequirements.SubtitleConvertReq?
        if let subID = selectedSubtitleID,
           let sub = result.subtitleTracks.first(where: { $0.id == subID }) {
            let subCompat = check(subtitle: sub, capabilities: capabilities)
            if subCompat.isYellow {
                subtitleConvert = .init(trackId: subID)
            }
        }

        // If nothing actually needs processing (e.g. only DV tone-mapping), skip
        if !needsRemux && audioTranscode == nil && subtitleConvert == nil {
            return nil
        }

        return ProcessingRequirements(
            remux: needsRemux,
            audioTranscode: audioTranscode,
            subtitleConvert: subtitleConvert
        )
    }
}
