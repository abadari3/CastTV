import Foundation

// MARK: - Probe Result

public struct ProbeResult: Sendable {
    public let url: URL
    public let duration: TimeInterval?
    public let container: ContainerType
    public let title: String?
    public let coverArt: Data?         // JPEG/PNG embedded cover image
    public let videoTracks: [VideoTrackInfo]
    public let audioTracks: [AudioTrackInfo]
    public let subtitleTracks: [SubtitleTrackInfo]
    public let hlsVariants: [HLSVariant]

    public init(url: URL, duration: TimeInterval?, container: ContainerType, title: String?,
                coverArt: Data? = nil,
                videoTracks: [VideoTrackInfo], audioTracks: [AudioTrackInfo],
                subtitleTracks: [SubtitleTrackInfo], hlsVariants: [HLSVariant] = []) {
        self.url = url
        self.duration = duration
        self.container = container
        self.title = title
        self.coverArt = coverArt
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.hlsVariants = hlsVariants
    }
}

// MARK: - Container

public enum ContainerType: String, Sendable {
    case mp4 = "MP4"
    case mov = "MOV"
    case m4v = "M4V"
    case hls = "HLS"
    case mkv = "MKV"
    case webm = "WebM"
    case avi = "AVI"
    case unknown = "Unknown"

    public var isNativelySupported: Bool {
        switch self {
        case .mp4, .mov, .m4v, .hls: return true
        default: return false
        }
    }

    public static func from(url: URL) -> ContainerType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4": return .mp4
        case "mov": return .mov
        case "m4v": return .m4v
        case "m3u8": return .hls
        case "mkv": return .mkv
        case "webm": return .webm
        case "avi": return .avi
        default: return .unknown
        }
    }
}

// MARK: - Video Track

public struct VideoTrackInfo: Identifiable, Sendable {
    public let id: Int
    public let codec: VideoCodec
    public let resolution: CGSize
    public let frameRate: Float
    public let bitDepth: Int?
    public let colorSpace: String?
    public let transferFunction: String?
    public let isDolbyVision: Bool
    public let estimatedDataRate: Double?
    public let language: String?

    public init(id: Int, codec: VideoCodec, resolution: CGSize, frameRate: Float,
                bitDepth: Int? = nil, colorSpace: String? = nil, transferFunction: String? = nil,
                isDolbyVision: Bool = false, estimatedDataRate: Double? = nil, language: String? = nil) {
        self.id = id
        self.codec = codec
        self.resolution = resolution
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
        self.transferFunction = transferFunction
        self.isDolbyVision = isDolbyVision
        self.estimatedDataRate = estimatedDataRate
        self.language = language
    }

    public var resolutionLabel: String {
        let w = Int(resolution.width)
        let h = Int(resolution.height)
        if h >= 2160 || w >= 3840 { return "4K" }
        if h >= 1080 || w >= 1920 { return "1080p" }
        if h >= 720 || w >= 1280 { return "720p" }
        return "\(w)x\(h)"
    }

    public var isHDR: Bool {
        if let tf = transferFunction {
            return tf.contains("HLG") || tf.contains("PQ") || tf.contains("SMPTE2084")
        }
        return false
    }
}

public enum VideoCodec: String, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"
    case vp9 = "VP9"
    case vp8 = "VP8"
    case av1 = "AV1"
    case unknown = "Unknown"

    public static func from(fourCC: String) -> VideoCodec {
        let lower = fourCC.lowercased()
        if lower.contains("avc") || lower.contains("h264") || lower == "avc1" { return .h264 }
        if lower.contains("hvc") || lower.contains("hevc") || lower == "hvc1" || lower == "hev1" { return .hevc }
        if lower.contains("vp09") || lower.contains("vp9") { return .vp9 }
        if lower.contains("vp08") || lower.contains("vp8") { return .vp8 }
        if lower.contains("av01") || lower.contains("av1") { return .av1 }
        return .unknown
    }

    /// Map from FFmpeg codec name (e.g. "h264", "hevc").
    public static func from(ffmpegName name: String) -> VideoCodec {
        switch name {
        case "h264": return .h264
        case "hevc": return .hevc
        case "vp9": return .vp9
        case "vp8": return .vp8
        case "av1": return .av1
        default: return .unknown
        }
    }
}

// MARK: - Audio Track

public struct AudioTrackInfo: Identifiable, Sendable {
    public let id: Int
    public let codec: AudioCodec
    public let channelCount: Int
    public let channelLayout: String?
    public let sampleRate: Double?
    public let estimatedDataRate: Double?
    public let language: String?

    public init(id: Int, codec: AudioCodec, channelCount: Int, channelLayout: String? = nil,
                sampleRate: Double? = nil, estimatedDataRate: Double? = nil, language: String? = nil) {
        self.id = id
        self.codec = codec
        self.channelCount = channelCount
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.estimatedDataRate = estimatedDataRate
        self.language = language
    }

    public var channelLabel: String {
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channelCount)ch"
        }
    }
}

public enum AudioCodec: String, Sendable {
    case aac = "AAC"
    case mp3 = "MP3"
    case ac3 = "AC-3"
    case eac3 = "E-AC-3"
    case dts = "DTS"
    case dtsHD = "DTS-HD"
    case truehd = "TrueHD"
    case flac = "FLAC"
    case opus = "Opus"
    case vorbis = "Vorbis"
    case pcm = "PCM"
    case unknown = "Unknown"

    public static func from(fourCC: String) -> AudioCodec {
        let lower = fourCC.lowercased()
        if lower.contains("aac") || lower == "mp4a" { return .aac }
        if lower.contains("mp3") || lower == ".mp3" || lower == "mp3 " { return .mp3 }
        if lower == "ac-3" || lower == "ac3 " { return .ac3 }
        if lower == "ec-3" || lower == "ec+3" || lower == "eac3" { return .eac3 }
        if lower.contains("truehd") || lower.contains("mlp") { return .truehd }
        if lower.contains("dts") {
            if lower.contains("hd") || lower.contains("xll") { return .dtsHD }
            return .dts
        }
        if lower.contains("flac") || lower == "flac" { return .flac }
        if lower.contains("opus") { return .opus }
        if lower.contains("vorb") { return .vorbis }
        if lower.contains("lpcm") || lower.contains("pcm") { return .pcm }
        return .unknown
    }

    /// Map from FFmpeg codec name (e.g. "aac", "dts", "dca").
    public static func from(ffmpegName name: String) -> AudioCodec {
        switch name {
        case "aac": return .aac
        case "mp3", "mp2": return .mp3
        case "ac3": return .ac3
        case "eac3": return .eac3
        case "dts", "dca": return .dts
        case "truehd": return .truehd
        case "flac": return .flac
        case "opus": return .opus
        case "vorbis": return .vorbis
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le": return .pcm
        default: return .unknown
        }
    }
}

// MARK: - Subtitle Track

public struct SubtitleTrackInfo: Identifiable, Sendable {
    public let id: Int
    public let format: SubtitleFormat
    public let language: String?
    public let isForced: Bool

    public init(id: Int, format: SubtitleFormat, language: String? = nil, isForced: Bool = false) {
        self.id = id
        self.format = format
        self.language = language
        self.isForced = isForced
    }
}

public enum SubtitleFormat: String, Sendable {
    case webvtt = "WebVTT"
    case cea608 = "CEA-608"
    case cea708 = "CEA-708"
    case srt = "SRT"
    case ass = "ASS"
    case pgs = "PGS"
    case movText = "mov_text"   // Apple tx3g — native on Apple TV
    case unknown = "Unknown"

    public static func from(fourCC: String) -> SubtitleFormat {
        let lower = fourCC.lowercased()
        if lower.contains("wvtt") || lower.contains("webvtt") { return .webvtt }
        if lower.contains("c608") { return .cea608 }
        if lower.contains("c708") { return .cea708 }
        if lower == "tx3g" { return .movText }
        if lower.contains("text") || lower.contains("srt") { return .srt }
        if lower.contains("ssa") || lower.contains("ass") { return .ass }
        if lower.contains("pgs") || lower.contains("hdmv") { return .pgs }
        return .unknown
    }

    /// Map from FFmpeg codec name (e.g. "subrip", "ass", "hdmv_pgs_subtitle").
    public static func from(ffmpegName name: String) -> SubtitleFormat {
        switch name {
        case "subrip", "srt": return .srt
        case "ass", "ssa": return .ass
        case "webvtt": return .webvtt
        case "hdmv_pgs_subtitle", "pgssub": return .pgs
        case "eia_608", "cc_dec": return .cea608
        case "eia_708": return .cea708
        case "mov_text": return .movText
        default: return .unknown
        }
    }
}

// MARK: - HLS Variant

public struct HLSVariant: Sendable {
    public let resolution: CGSize?
    public let peakBitRate: Double?
    public let averageBitRate: Double?
    public let audioRenditions: [String] // languages
    public let subtitleRenditions: [String] // languages

    public init(resolution: CGSize? = nil, peakBitRate: Double? = nil, averageBitRate: Double? = nil,
                audioRenditions: [String] = [], subtitleRenditions: [String] = []) {
        self.resolution = resolution
        self.peakBitRate = peakBitRate
        self.averageBitRate = averageBitRate
        self.audioRenditions = audioRenditions
        self.subtitleRenditions = subtitleRenditions
    }
}
