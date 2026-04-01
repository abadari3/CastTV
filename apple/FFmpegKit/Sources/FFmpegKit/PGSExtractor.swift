import Foundation
import CoreGraphics
import ImageIO
import FFmpeg

/// Extracts PGS (Presentation Graphic Stream) bitmap subtitles as timed image events.
///
/// Each PGS subtitle is a pre-rendered bitmap with position and timing info.
/// The output can be overlaid on top of video without any transcoding or OCR.
public enum PGSExtractor {

    public enum ExtractError: LocalizedError, Sendable {
        case openFailed(String)
        case noSubtitleStream(Int)
        case notPGS(String)
        case decodeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Failed to open source: \(msg)"
            case .noSubtitleStream(let idx): return "Subtitle stream \(idx) not found"
            case .notPGS(let fmt): return "Not a PGS stream: \(fmt)"
            case .decodeFailed(let msg): return "Decode failed: \(msg)"
            }
        }
    }

    /// A single PGS subtitle event: a timed bitmap to display over the video.
    public struct PGSEvent: Sendable {
        /// Display start time in seconds.
        public let start: Double
        /// Display end time in seconds.
        public let end: Double
        /// Bitmap image data encoded as PNG.
        public let pngData: Data
        /// Horizontal position (pixels from left edge of video frame).
        public let x: Int
        /// Vertical position (pixels from top edge of video frame).
        public let y: Int
        /// Bitmap width in pixels.
        public let width: Int
        /// Bitmap height in pixels.
        public let height: Int
    }

    /// Extract all PGS subtitle events from a media file.
    /// Returns an array of timed bitmap events sorted by start time.
    ///
    /// For lower memory usage on long files, use ``extractStreaming(sourceURL:streamIndex:onEvent:)``
    /// which delivers events one at a time without accumulating PNG data.
    public static func extract(sourceURL: String, streamIndex: Int) throws -> [PGSEvent] {
        var events: [PGSEvent] = []
        try extractStreaming(sourceURL: sourceURL, streamIndex: streamIndex) { event in
            events.append(event)
        }
        events.sort { $0.start < $1.start }
        return events
    }

    /// Extract PGS subtitle events one at a time, calling `onEvent` for each.
    /// This avoids accumulating all PNG data in memory at once.
    /// Events are delivered in decode order (generally chronological but not guaranteed to be sorted).
    public static func extractStreaming(sourceURL: String, streamIndex: Int, onEvent: (PGSEvent) throws -> Void) throws {
        avformat_network_init()

        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&fmtCtx, sourceURL, nil, nil)
        guard ret == 0, let ctx = fmtCtx else {
            throw ExtractError.openFailed(ffmpegError(ret))
        }
        defer { avformat_close_input(&fmtCtx) }

        ret = avformat_find_stream_info(ctx, nil)
        guard ret >= 0 else {
            throw ExtractError.openFailed(ffmpegError(ret))
        }

        // Validate stream index and codec
        guard streamIndex < Int(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[streamIndex],
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else {
            throw ExtractError.noSubtitleStream(streamIndex)
        }

        let codecID = codecpar.pointee.codec_id
        guard codecID == AV_CODEC_ID_HDMV_PGS_SUBTITLE else {
            let name = codecIDToName(codecID)
            throw ExtractError.notPGS(name)
        }

        // Set up decoder
        guard let decoder = avcodec_find_decoder(codecID) else {
            throw ExtractError.decodeFailed("No decoder for PGS")
        }
        var decCtx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(decoder)
        guard let dec = decCtx else {
            throw ExtractError.decodeFailed("Failed to allocate decoder context")
        }
        defer { avcodec_free_context(&decCtx) }

        ret = avcodec_parameters_to_context(dec, codecpar)
        guard ret >= 0 else {
            throw ExtractError.decodeFailed("Failed to copy params: \(ffmpegError(ret))")
        }
        ret = avcodec_open2(dec, decoder, nil)
        guard ret >= 0 else {
            throw ExtractError.decodeFailed("Failed to open decoder: \(ffmpegError(ret))")
        }

        // Read and decode PGS subtitle packets
        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let p = pkt else {
            throw ExtractError.decodeFailed("Failed to allocate packet")
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
                    endSec = ptsSec + 5.0
                }

                // Process bitmap rects
                for i in 0..<Int(sub.pointee.num_rects) {
                    guard let rectPtr = sub.pointee.rects?[i] else { continue }
                    let rect = rectPtr.pointee

                    if rect.type == SUBTITLE_BITMAP,
                       rect.w > 0, rect.h > 0,
                       let bitmapData = rect.data.0,
                       let paletteData = rect.data.1 {
                        let w = Int(rect.w)
                        let h = Int(rect.h)
                        let linesize = Int(rect.linesize.0)

                        if let pngData = convertPGSBitmapToPNG(
                            bitmap: bitmapData,
                            palette: paletteData,
                            width: w,
                            height: h,
                            linesize: linesize,
                            numColors: Int(rect.nb_colors)
                        ) {
                            try onEvent(PGSEvent(
                                start: ptsSec,
                                end: endSec,
                                pngData: pngData,
                                x: Int(rect.x),
                                y: Int(rect.y),
                                width: w,
                                height: h
                            ))
                        }
                    }
                }

                avsubtitle_free(sub)
            }

            av_packet_unref(p)
        }
    }

    // MARK: - Bitmap Conversion

    /// Convert a PGS indexed-color bitmap + palette to PNG data.
    ///
    /// PGS bitmaps use 8-bit indexed color with a palette stored as ARGB32.
    /// We expand to RGBA pixels and encode as PNG via CoreGraphics/ImageIO.
    private static func convertPGSBitmapToPNG(
        bitmap: UnsafePointer<UInt8>,
        palette: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        linesize: Int,
        numColors: Int
    ) -> Data? {
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<height {
            let srcRow = bitmap.advanced(by: y * linesize)
            let dstOffset = y * bytesPerRow
            for x in 0..<width {
                let colorIndex = Int(srcRow[x])
                let px = dstOffset + x * 4
                if colorIndex < numColors {
                    // FFmpeg PGS palette is ARGB32 stored as uint32_t.
                    // On little-endian ARM the bytes in memory are [B, G, R, A].
                    let po = colorIndex * 4
                    rgba[px]     = palette[po + 2] // R
                    rgba[px + 1] = palette[po + 1] // G
                    rgba[px + 2] = palette[po]     // B
                    rgba[px + 3] = palette[po + 3] // A
                }
                // else: stays transparent (0,0,0,0)
            }
        }

        return rgba.withUnsafeBytes { rawBuf -> Data? in
            guard let baseAddr = rawBuf.baseAddress else { return nil }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: baseAddr),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.last.rawValue
            ), let cgImage = context.makeImage() else {
                return nil
            }

            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                mutableData as CFMutableData,
                "public.png" as CFString,
                1,
                nil
            ) else { return nil }

            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }

            return mutableData as Data
        }
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
