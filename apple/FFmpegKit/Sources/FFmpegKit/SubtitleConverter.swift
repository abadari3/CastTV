import Foundation
import FFmpeg

/// Extracts and converts text-based subtitles to WebVTT format.
///
/// Supported conversions:
/// - SRT (SubRip) → WebVTT
/// - ASS/SSA → WebVTT (styling stripped, text preserved)
///
/// For PGS (bitmap) subtitles, use ``PGSExtractor`` instead.
public enum SubtitleConverter {

    public enum ConvertError: LocalizedError, Sendable {
        case openFailed(String)
        case noSubtitleStream(Int)
        case unsupportedFormat(String)
        case decodeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Failed to open source: \(msg)"
            case .noSubtitleStream(let idx): return "Subtitle stream \(idx) not found"
            case .unsupportedFormat(let fmt): return "Unsupported subtitle format: \(fmt)"
            case .decodeFailed(let msg): return "Decode failed: \(msg)"
            }
        }
    }

    /// Extract subtitles from a media file and convert to WebVTT.
    /// Returns the WebVTT content as a string.
    public static func convert(sourceURL: String, streamIndex: Int) throws -> String {
        avformat_network_init()

        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&fmtCtx, sourceURL, nil, nil)
        guard ret == 0, let ctx = fmtCtx else {
            throw ConvertError.openFailed(ffmpegError(ret))
        }
        defer { avformat_close_input(&fmtCtx) }

        ret = avformat_find_stream_info(ctx, nil)
        guard ret >= 0 else {
            throw ConvertError.openFailed(ffmpegError(ret))
        }

        // Validate stream index
        guard streamIndex < Int(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[streamIndex],
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else {
            throw ConvertError.noSubtitleStream(streamIndex)
        }

        let codecID = codecpar.pointee.codec_id
        let codecName = codecIDToName(codecID)

        // Check if format is convertible
        guard codecID == AV_CODEC_ID_SUBRIP ||
              codecID == AV_CODEC_ID_ASS ||
              codecID == AV_CODEC_ID_SSA ||
              codecID == AV_CODEC_ID_WEBVTT else {
            throw ConvertError.unsupportedFormat(codecName)
        }

        // If already WebVTT, just extract
        if codecID == AV_CODEC_ID_WEBVTT {
            return try extractWebVTT(ctx: ctx, streamIndex: streamIndex)
        }

        // Set up decoder
        guard let decoder = avcodec_find_decoder(codecID) else {
            throw ConvertError.decodeFailed("No decoder for \(codecName)")
        }
        var decCtx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(decoder)
        guard let dec = decCtx else {
            throw ConvertError.decodeFailed("Failed to allocate decoder context")
        }
        defer { avcodec_free_context(&decCtx) }

        ret = avcodec_parameters_to_context(dec, codecpar)
        guard ret >= 0 else {
            throw ConvertError.decodeFailed("Failed to copy params: \(ffmpegError(ret))")
        }
        ret = avcodec_open2(dec, decoder, nil)
        guard ret >= 0 else {
            throw ConvertError.decodeFailed("Failed to open decoder: \(ffmpegError(ret))")
        }

        // Read all subtitle packets and decode
        var cues: [VTTCue] = []
        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let p = pkt else {
            throw ConvertError.decodeFailed("Failed to allocate packet")
        }

        let sub = UnsafeMutablePointer<AVSubtitle>.allocate(capacity: 1)
        defer { sub.deallocate() }

        let timeBase = stream.pointee.time_base

        while av_read_frame(ctx, p) >= 0 {
            if Int(p.pointee.stream_index) != streamIndex {
                av_packet_unref(p)
                continue
            }

            var gotSub: Int32 = 0
            sub.pointee = AVSubtitle()
            ret = avcodec_decode_subtitle2(dec, sub, &gotSub, p)

            if ret >= 0 && gotSub != 0 {
                // Calculate timestamps
                let ptsSec: Double
                if p.pointee.pts != Int64.min && p.pointee.pts >= 0 {
                    ptsSec = Double(p.pointee.pts) * av_q2d(timeBase)
                } else {
                    ptsSec = Double(sub.pointee.start_display_time) / 1000.0
                }

                let durationMs = sub.pointee.end_display_time - sub.pointee.start_display_time
                let durationSec = Double(durationMs) / 1000.0
                let endSec: Double
                if p.pointee.duration > 0 {
                    endSec = ptsSec + Double(p.pointee.duration) * av_q2d(timeBase)
                } else if durationSec > 0 {
                    endSec = ptsSec + durationSec
                } else {
                    endSec = ptsSec + 5.0 // fallback 5s duration
                }

                // Extract text from subtitle rects
                for i in 0..<Int(sub.pointee.num_rects) {
                    guard let rectPtr = sub.pointee.rects?[i] else { continue }
                    let rect = rectPtr.pointee

                    if rect.type == SUBTITLE_ASS, let ass = rect.ass {
                        let assText = String(cString: ass)
                        let cleanText = stripASSFormatting(assText)
                        if !cleanText.isEmpty {
                            cues.append(VTTCue(start: ptsSec, end: endSec, text: cleanText))
                        }
                    } else if rect.type == SUBTITLE_TEXT, let text = rect.text {
                        let textStr = String(cString: text)
                        if !textStr.isEmpty {
                            cues.append(VTTCue(start: ptsSec, end: endSec, text: textStr))
                        }
                    }
                }

                avsubtitle_free(sub)
            }

            av_packet_unref(p)
        }

        // Sort cues by start time
        cues.sort { $0.start < $1.start }

        return generateWebVTT(cues: cues)
    }

    // MARK: - Types

    private struct VTTCue {
        let start: Double
        let end: Double
        let text: String
    }

    // MARK: - WebVTT Generation

    private static func generateWebVTT(cues: [VTTCue]) -> String {
        var lines: [String] = ["WEBVTT", ""]

        for (i, cue) in cues.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(formatTimestamp(cue.start)) --> \(formatTimestamp(cue.end))")
            lines.append(cue.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let totalSecs = totalMs / 1000
        let s = totalSecs % 60
        let m = (totalSecs / 60) % 60
        let h = totalSecs / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    // MARK: - ASS/SSA Formatting Stripping

    /// Strip ASS formatting from a dialogue line.
    /// ASS format: "Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
    /// We want just the Text part with override tags removed.
    private static func stripASSFormatting(_ ass: String) -> String {
        // ASS dialogue lines have comma-separated fields; text is after the 9th comma
        let parts = ass.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
        let text: String
        if parts.count > 9 {
            text = String(parts[9])
        } else {
            text = ass
        }

        // Remove override tags: {\...}
        var result = text
        while let range = result.range(of: #"\{\\[^}]*\}"#, options: .regularExpression) {
            result.removeSubrange(range)
        }

        // Replace \N and \n with newlines
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\n", with: "\n")

        // Strip HTML-like tags that SRT sometimes uses
        while let range = result.range(of: "<[^>]+>", options: .regularExpression) {
            result.removeSubrange(range)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Direct WebVTT Extraction

    private static func extractWebVTT(ctx: UnsafeMutablePointer<AVFormatContext>, streamIndex: Int) throws -> String {
        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let p = pkt else {
            throw ConvertError.decodeFailed("Failed to allocate packet")
        }

        let stream = ctx.pointee.streams[streamIndex]!
        let timeBase = stream.pointee.time_base
        var cues: [VTTCue] = []

        while av_read_frame(ctx, p) >= 0 {
            if Int(p.pointee.stream_index) != streamIndex {
                av_packet_unref(p)
                continue
            }

            if let data = p.pointee.data, p.pointee.size > 0 {
                let text = String(bytes: UnsafeBufferPointer(start: data, count: Int(p.pointee.size)), encoding: .utf8) ?? ""
                let start = Double(p.pointee.pts) * av_q2d(timeBase)
                let end = start + Double(p.pointee.duration) * av_q2d(timeBase)
                if !text.isEmpty {
                    cues.append(VTTCue(start: start, end: end, text: text))
                }
            }

            av_packet_unref(p)
        }

        cues.sort { $0.start < $1.start }
        return generateWebVTT(cues: cues)
    }

    // MARK: - Helpers

    private static func codecIDToName(_ id: AVCodecID) -> String {
        if let desc = avcodec_descriptor_get(id) {
            return String(cString: desc.pointee.name)
        }
        return "unknown"
    }

    private static func ffmpegError(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buf, 128)
        return String(cString: buf)
    }
}
