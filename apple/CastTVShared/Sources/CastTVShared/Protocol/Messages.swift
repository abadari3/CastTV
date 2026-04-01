import Foundation

// MARK: - iPhone → TV

/// Play command sent from iPhone to TV.
public struct PlayMessage: Codable, Equatable, Sendable {
    public let action: String // always "play"
    public let url: String
    public let subtitleUrl: String?
    public let tracks: TrackSelection?
    public let processing: ProcessingRequirements?  // V2: nil = direct playback

    public init(url: String, subtitleUrl: String? = nil, tracks: TrackSelection? = nil, processing: ProcessingRequirements? = nil) {
        self.action = "play"
        self.url = url
        self.subtitleUrl = subtitleUrl
        self.tracks = tracks
        self.processing = processing
    }

    /// Whether this play command requires on-device processing (remux/transcode).
    public var needsProcessing: Bool {
        processing != nil
    }
}

public struct TrackSelection: Codable, Equatable, Sendable {
    public let video: Int?
    public let audio: Int?
    public let subtitle: Int?

    public init(video: Int? = nil, audio: Int? = nil, subtitle: Int? = nil) {
        self.video = video
        self.audio = audio
        self.subtitle = subtitle
    }
}

/// V2: Describes what processing the TV needs to do.
public struct ProcessingRequirements: Codable, Equatable, Sendable {
    public let remux: Bool
    public let audioTranscode: AudioTranscodeReq?
    public let subtitleConvert: SubtitleConvertReq?

    public init(remux: Bool, audioTranscode: AudioTranscodeReq? = nil, subtitleConvert: SubtitleConvertReq? = nil) {
        self.remux = remux
        self.audioTranscode = audioTranscode
        self.subtitleConvert = subtitleConvert
    }

    public struct AudioTranscodeReq: Codable, Equatable, Sendable {
        public let trackId: Int
        public let targetCodec: String  // "aac"

        public init(trackId: Int, targetCodec: String = "aac") {
            self.trackId = trackId
            self.targetCodec = targetCodec
        }
    }

    public struct SubtitleConvertReq: Codable, Equatable, Sendable {
        public let trackId: Int
        public let targetFormat: String  // "webvtt"

        public init(trackId: Int, targetFormat: String = "webvtt") {
            self.trackId = trackId
            self.targetFormat = targetFormat
        }
    }
}

// MARK: - TV → iPhone

public struct CapabilitiesMessage: Codable, Hashable, Sendable {
    public let type: String // always "capabilities"
    public let model: String
    public let tvOS: String
    public let name: String
    public let display: DisplayCapabilities
    public let audio: AudioCapabilities

    public init(model: String, tvOS: String, name: String, display: DisplayCapabilities, audio: AudioCapabilities) {
        self.type = "capabilities"
        self.model = model
        self.tvOS = tvOS
        self.name = name
        self.display = display
        self.audio = audio
    }
}

public struct DisplayCapabilities: Codable, Hashable, Sendable {
    public let resolution: String
    public let availableModes: [String]
    public let maxRefreshRate: Int
    public let displayGamut: String
    public let hdrModes: [String]

    public init(resolution: String, availableModes: [String], maxRefreshRate: Int, displayGamut: String, hdrModes: [String]) {
        self.resolution = resolution
        self.availableModes = availableModes
        self.maxRefreshRate = maxRefreshRate
        self.displayGamut = displayGamut
        self.hdrModes = hdrModes
    }

    /// Short display label for an HDR mode string.
    public static func hdrLabel(_ mode: String) -> String {
        switch mode {
        case "hdr10": return "HDR10"
        case "dolbyVision": return "DV"
        case "hlg": return "HLG"
        default: return mode
        }
    }
}

public struct AudioCapabilities: Codable, Hashable, Sendable {
    public let maxChannels: Int
    public let outputType: String
    public let atmosSupported: Bool
    public let spatialAudioEnabled: Bool

    public init(maxChannels: Int, outputType: String, atmosSupported: Bool, spatialAudioEnabled: Bool) {
        self.maxChannels = maxChannels
        self.outputType = outputType
        self.atmosSupported = atmosSupported
        self.spatialAudioEnabled = spatialAudioEnabled
    }
}

extension CapabilitiesMessage {
    /// True when the connected device is an Android TV (tvOS field starts with "Android").
    public var isAndroidTV: Bool { tvOS.lowercased().hasPrefix("android") }
}

public struct ErrorMessage: Codable, Sendable {
    public let type: String // always "error"
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.type = "error"
        self.code = code
        self.message = message
    }
}

public struct LogMessage: Codable, Sendable {
    public let type: String // always "log"
    public let timestamp: String
    public let level: LogLevel
    public let message: String

    public init(timestamp: Date = Date(), level: LogLevel, message: String) {
        self.type = "log"
        self.timestamp = ISO8601DateFormatter().string(from: timestamp)
        self.level = level
        self.message = message
    }
}

public enum LogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct LogsHistoryMessage: Codable, Sendable {
    public let type: String // always "logs_history"
    public let session: String
    public let entries: [LogMessage]

    public init(session: Date, entries: [LogMessage]) {
        self.type = "logs_history"
        self.session = ISO8601DateFormatter().string(from: session)
        self.entries = entries
    }
}

