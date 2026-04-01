import Foundation
import FFmpeg

/// Probes media files using FFmpeg's libavformat.
/// Works with any container FFmpeg supports (MKV, WebM, AVI, etc.)
public enum FFProber {

    /// Result of probing a media URL.
    public struct Result: Sendable {
        public let duration: TimeInterval?
        public let formatName: String
        public let title: String?
        public let coverArt: Data?      // JPEG/PNG data from embedded cover image
        public let videoTracks: [VideoTrack]
        public let audioTracks: [AudioTrack]
        public let subtitleTracks: [SubtitleTrack]
    }

    public struct VideoTrack: Sendable {
        public let index: Int
        public let codecName: String     // "hevc", "h264", "vp9", etc.
        public let width: Int
        public let height: Int
        public let frameRate: Double
        public let bitDepth: Int?
        public let colorPrimaries: String?
        public let transferCharacteristic: String?
        public let isDolbyVision: Bool
        public let bitRate: Int64?
        public let language: String?
    }

    public struct AudioTrack: Sendable {
        public let index: Int
        public let codecName: String     // "aac", "ac3", "eac3", "dts", "truehd", etc.
        public let channelCount: Int
        public let channelLayout: String?
        public let sampleRate: Int
        public let bitRate: Int64?
        public let language: String?
        public let title: String?
    }

    public struct SubtitleTrack: Sendable {
        public let index: Int
        public let codecName: String     // "subrip", "ass", "hdmv_pgs_subtitle", "webvtt", etc.
        public let language: String?
        public let title: String?
        public let isForced: Bool
        public let isDefault: Bool
    }

    public enum ProbeError: LocalizedError, Sendable {
        case openFailed(String)
        case streamInfoFailed(String)
        case noStreams

        public var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Failed to open: \(msg)"
            case .streamInfoFailed(let msg): return "Failed to read stream info: \(msg)"
            case .noStreams: return "No media streams found"
            }
        }
    }

    // MARK: - Public API

    /// Probe a URL and return detailed track information.
    public static func probe(url: URL) throws -> Result {
        // Register network protocols (call once, idempotent)
        Self.initializeOnce

        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        // Open input
        let urlString = url.absoluteString
        var ret = avformat_open_input(&fmtCtx, urlString, nil, nil)
        guard ret == 0, let ctx = fmtCtx else {
            throw ProbeError.openFailed(ffmpegError(ret))
        }

        defer { avformat_close_input(&fmtCtx) }

        // Read stream info
        ret = avformat_find_stream_info(ctx, nil)
        guard ret >= 0 else {
            throw ProbeError.streamInfoFailed(ffmpegError(ret))
        }

        let nbStreams = Int(ctx.pointee.nb_streams)
        guard nbStreams > 0 else {
            throw ProbeError.noStreams
        }

        // Duration
        // AV_NOPTS_VALUE = 0x8000000000000000 — can't use the C macro from Swift
        let nopts: Int64 = -0x7FFFFFFFFFFFFFFF - 1
        let duration: TimeInterval?
        if ctx.pointee.duration > 0 && ctx.pointee.duration != nopts {
            duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        } else {
            duration = nil
        }

        // Format name
        let formatName = String(cString: ctx.pointee.iformat.pointee.name)

        // Title from metadata
        let title = metadataString(ctx.pointee.metadata, key: "title")

        // Parse streams
        var videoTracks: [VideoTrack] = []
        var audioTracks: [AudioTrack] = []
        var subtitleTracks: [SubtitleTrack] = []
        var coverArt: Data?

        for i in 0..<nbStreams {
            guard let stream = ctx.pointee.streams[i] else { continue }
            guard let codecpar = stream.pointee.codecpar else { continue }

            let codecType = codecpar.pointee.codec_type

            if codecType == AVMEDIA_TYPE_VIDEO {
                // Extract attached pictures (album art, cover images)
                if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
                    if coverArt == nil {
                        let pkt = stream.pointee.attached_pic
                        if let data = pkt.data, pkt.size > 0 {
                            coverArt = Data(bytes: data, count: Int(pkt.size))
                        }
                    }
                    continue
                }
                if let track = parseVideoStream(stream, index: i) {
                    videoTracks.append(track)
                }
            } else if codecType == AVMEDIA_TYPE_AUDIO {
                if let track = parseAudioStream(stream, index: i) {
                    audioTracks.append(track)
                }
            } else if codecType == AVMEDIA_TYPE_SUBTITLE {
                if let track = parseSubtitleStream(stream, index: i) {
                    subtitleTracks.append(track)
                }
            }
        }

        return Result(
            duration: duration,
            formatName: formatName,
            title: title,
            coverArt: coverArt,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks
        )
    }

    // MARK: - Stream Parsers

    private static func parseVideoStream(_ stream: UnsafeMutablePointer<AVStream>, index: Int) -> VideoTrack? {
        let codecpar = stream.pointee.codecpar!.pointee

        let codecName = codecIDToName(codecpar.codec_id)
        let width = Int(codecpar.width)
        let height = Int(codecpar.height)

        // Frame rate
        let fps: Double
        let avgRate = stream.pointee.avg_frame_rate
        if avgRate.den > 0 && avgRate.num > 0 {
            fps = Double(avgRate.num) / Double(avgRate.den)
        } else {
            let rRate = stream.pointee.r_frame_rate
            if rRate.den > 0 && rRate.num > 0 {
                fps = Double(rRate.num) / Double(rRate.den)
            } else {
                fps = 0
            }
        }

        // Bit depth from pixel format
        let bitDepth = pixelFormatBitDepth(codecpar.format)

        // Color info
        let colorPrimaries = colorPrimariesName(codecpar.color_primaries)
        let transferCharacteristic = transferCharacteristicName(codecpar.color_trc)

        // Dolby Vision detection
        var isDolbyVision = false

        // Check codec tag for DV
        let tag = codecpar.codec_tag
        let tagStr = fourCCToString(tag)
        if tagStr.lowercased().hasPrefix("dvh") || tagStr.lowercased().hasPrefix("dva") {
            isDolbyVision = true
        }

        // Check side data for DOVI configuration
        if hasDOVISideData(stream) {
            isDolbyVision = true
        }

        let bitRate: Int64? = codecpar.bit_rate > 0 ? codecpar.bit_rate : nil
        let language = metadataString(stream.pointee.metadata, key: "language")

        return VideoTrack(
            index: index,
            codecName: codecName,
            width: width,
            height: height,
            frameRate: fps,
            bitDepth: bitDepth,
            colorPrimaries: colorPrimaries,
            transferCharacteristic: transferCharacteristic,
            isDolbyVision: isDolbyVision,
            bitRate: bitRate,
            language: language
        )
    }

    private static func parseAudioStream(_ stream: UnsafeMutablePointer<AVStream>, index: Int) -> AudioTrack? {
        let codecpar = stream.pointee.codecpar!.pointee

        let codecName = codecIDToName(codecpar.codec_id)
        let chLayout = codecpar.ch_layout
        let channelCount = Int(chLayout.nb_channels)
        let channelLayout = channelLayoutName(chLayout)

        let sampleRate = Int(codecpar.sample_rate)
        let bitRate: Int64? = codecpar.bit_rate > 0 ? codecpar.bit_rate : nil
        let language = metadataString(stream.pointee.metadata, key: "language")
        let title = metadataString(stream.pointee.metadata, key: "title")

        return AudioTrack(
            index: index,
            codecName: codecName,
            channelCount: channelCount,
            channelLayout: channelLayout,
            sampleRate: sampleRate,
            bitRate: bitRate,
            language: language,
            title: title
        )
    }

    private static func parseSubtitleStream(_ stream: UnsafeMutablePointer<AVStream>, index: Int) -> SubtitleTrack? {
        let codecpar = stream.pointee.codecpar!.pointee

        let codecName = codecIDToName(codecpar.codec_id)
        let language = metadataString(stream.pointee.metadata, key: "language")
        let title = metadataString(stream.pointee.metadata, key: "title")
        let isForced = stream.pointee.disposition & AV_DISPOSITION_FORCED != 0
        let isDefault = stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0

        return SubtitleTrack(
            index: index,
            codecName: codecName,
            language: language,
            title: title,
            isForced: isForced,
            isDefault: isDefault
        )
    }

    // MARK: - Helpers

    private static let initializeOnce: Void = {
        avformat_network_init()
    }()

    private static func ffmpegError(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buf, 128)
        return String(cString: buf)
    }

    private static func codecIDToName(_ id: AVCodecID) -> String {
        if let desc = avcodec_descriptor_get(id) {
            return String(cString: desc.pointee.name)
        }
        return "unknown"
    }

    private static func metadataString(_ metadata: OpaquePointer?, key: String) -> String? {
        guard let metadata else { return nil }
        var tag: UnsafeMutablePointer<AVDictionaryEntry>?
        tag = av_dict_get(metadata, key, nil, 0)
        guard let tag, let value = tag.pointee.value else { return nil }
        return String(cString: value)
    }

    private static func fourCCToString(_ tag: UInt32) -> String {
        guard tag != 0 else { return "" }
        let bytes: [UInt8] = [
            UInt8(tag & 0xFF),
            UInt8((tag >> 8) & 0xFF),
            UInt8((tag >> 16) & 0xFF),
            UInt8((tag >> 24) & 0xFF),
        ]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    private static func pixelFormatBitDepth(_ format: Int32) -> Int? {
        let fmt = AVPixelFormat(rawValue: format)
        guard fmt != AV_PIX_FMT_NONE else { return nil }
        guard let desc = av_pix_fmt_desc_get(fmt) else { return nil }
        // comp[0].depth gives the bit depth of the first component
        let depth = Int(desc.pointee.comp.0.depth)
        return depth > 0 ? depth : nil
    }

    private static func colorPrimariesName(_ primaries: AVColorPrimaries) -> String? {
        switch primaries {
        case AVCOL_PRI_BT709: return "BT.709"
        case AVCOL_PRI_BT2020: return "BT.2020"
        case AVCOL_PRI_SMPTE432: return "Display P3"
        default: return nil
        }
    }

    private static func transferCharacteristicName(_ trc: AVColorTransferCharacteristic) -> String? {
        switch trc {
        case AVCOL_TRC_BT709: return "BT.709"
        case AVCOL_TRC_SMPTE2084: return "SMPTE2084"  // PQ / HDR10
        case AVCOL_TRC_ARIB_STD_B67: return "HLG"
        default: return nil
        }
    }

    private static func hasDOVISideData(_ stream: UnsafeMutablePointer<AVStream>) -> Bool {
        // Check codecpar side data for DOVI configuration record
        guard let codecpar = stream.pointee.codecpar else { return false }
        let nbSideData = Int(codecpar.pointee.nb_coded_side_data)
        for i in 0..<nbSideData {
            let sd = codecpar.pointee.coded_side_data[i]
            if sd.type == AV_PKT_DATA_DOVI_CONF {
                return true
            }
        }
        return false
    }

    private static func channelLayoutName(_ layout: AVChannelLayout) -> String? {
        let count = Int(layout.nb_channels)
        // Use the standard layout names
        var buf = [CChar](repeating: 0, count: 64)
        var layoutCopy = layout
        av_channel_layout_describe(&layoutCopy, &buf, 64)
        let desc = String(cString: buf)
        if desc.isEmpty { return nil }

        // Map common FFmpeg layout names to friendly names
        switch desc {
        case "mono": return "Mono"
        case "stereo": return "Stereo"
        case "5.1", "5.1(side)": return "5.1"
        case "7.1": return "7.1"
        default:
            if count > 0 { return "\(count)ch" }
            return desc
        }
    }
}
