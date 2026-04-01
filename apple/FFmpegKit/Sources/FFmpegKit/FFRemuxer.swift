import Foundation
import FFmpeg

/// Remuxes media from non-native containers (MKV, etc.) to HLS segments.
/// Copies video bit-for-bit, optionally transcodes audio to AAC.
public final class FFRemuxer: @unchecked Sendable {

    public struct Configuration: Sendable {
        public let sourceURL: String
        public let outputDirectory: String
        public let videoStreamIndex: Int
        public let audioStreamIndex: Int
        public let subtitleStreamIndex: Int?
        public let transcodeAudio: Bool
        public let segmentDuration: Int
        public let startTimeSeconds: Double
        public let segmentStartIndex: Int

        public init(sourceURL: String, outputDirectory: String,
                    videoStreamIndex: Int, audioStreamIndex: Int,
                    subtitleStreamIndex: Int? = nil,
                    transcodeAudio: Bool = false,
                    segmentDuration: Int = 6,
                    startTimeSeconds: Double = 0,
                    segmentStartIndex: Int = 0) {
            self.sourceURL = sourceURL
            self.outputDirectory = outputDirectory
            self.videoStreamIndex = videoStreamIndex
            self.audioStreamIndex = audioStreamIndex
            self.subtitleStreamIndex = subtitleStreamIndex
            self.transcodeAudio = transcodeAudio
            self.segmentDuration = segmentDuration
            self.startTimeSeconds = startTimeSeconds
            self.segmentStartIndex = segmentStartIndex
        }
    }

    public enum RemuxError: LocalizedError, Sendable {
        case openInputFailed(String)
        case openOutputFailed(String)
        case streamSetupFailed(String)
        case writeFailed(String)
        case encoderSetupFailed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .openInputFailed(let msg): return "Failed to open source: \(msg)"
            case .openOutputFailed(let msg): return "Failed to create output: \(msg)"
            case .streamSetupFailed(let msg): return "Stream setup failed: \(msg)"
            case .writeFailed(let msg): return "Write failed: \(msg)"
            case .encoderSetupFailed(let msg): return "Encoder setup failed: \(msg)"
            case .cancelled: return "Remux cancelled"
            }
        }
    }

    public struct Callbacks: Sendable {
        public var onSegment: (@Sendable (_ index: Int, _ filename: String, _ duration: Double) -> Void)?
        public var onProgress: (@Sendable (_ timeSeconds: Double, _ totalSeconds: Double?) -> Void)?
        public var onFinished: (@Sendable () -> Void)?
        public var onError: (@Sendable (_ error: RemuxError) -> Void)?
        public var onLog: (@Sendable (_ message: String) -> Void)?
        public init() {}
    }

    private let config: Configuration
    private let _callbacks: Callbacks  // immutable after init — set via init, not mutated during run
    private var _isCancelled = false
    private let lock = NSLock()

    public var isCancelled: Bool {
        lock.withLock { _isCancelled }
    }

    public init(configuration: Configuration, callbacks: Callbacks = Callbacks()) {
        self.config = configuration
        self._callbacks = callbacks
    }

    public func cancel() {
        lock.withLock { _isCancelled = true }
    }

    /// Start remuxing. Blocks the calling thread until done or cancelled.
    public func start() {
        avformat_network_init()
        do {
            try runPipeline()
            _callbacks.onFinished?()
        } catch let error as RemuxError {
            _callbacks.onError?(error)
        } catch {
            _callbacks.onError?(.writeFailed(error.localizedDescription))
        }
    }

    // MARK: - Pipeline

    private func log(_ msg: String) {
        _callbacks.onLog?(msg)
    }

    private func runPipeline() throws {
        // 1. Open input with timeout
        log("Opening source: \(config.sourceURL)")
        var inputCtx: UnsafeMutablePointer<AVFormatContext>?
        var inputOpts: OpaquePointer?
        av_dict_set(&inputOpts, "timeout", "15000000", 0)
        av_dict_set(&inputOpts, "rw_timeout", "15000000", 0)
        var ret = avformat_open_input(&inputCtx, config.sourceURL, nil, &inputOpts)
        av_dict_free(&inputOpts)
        guard ret == 0, let inCtx = inputCtx else {
            log("Failed to open source: \(ffmpegError(ret))")
            throw RemuxError.openInputFailed(ffmpegError(ret))
        }
        defer { avformat_close_input(&inputCtx) }

        log("Reading stream info...")
        ret = avformat_find_stream_info(inCtx, nil)
        guard ret >= 0 else {
            log("Failed to read stream info: \(ffmpegError(ret))")
            throw RemuxError.openInputFailed(ffmpegError(ret))
        }
        log("Source opened: \(inCtx.pointee.nb_streams) streams")

        // Seek if starting from a non-zero position
        if config.startTimeSeconds > 0 {
            let seekTarget = Int64(config.startTimeSeconds * Double(AV_TIME_BASE))
            av_seek_frame(inCtx, -1, seekTarget, AVSEEK_FLAG_BACKWARD)
            // Non-fatal if seek fails — continues from beginning
        }

        let totalDuration: Double?
        if inCtx.pointee.duration > 0 && inCtx.pointee.duration != Int64.min {
            totalDuration = Double(inCtx.pointee.duration) / Double(AV_TIME_BASE)
        } else {
            totalDuration = nil
        }

        // Validate stream indices
        let nbStreams = Int(inCtx.pointee.nb_streams)
        guard config.videoStreamIndex < nbStreams,
              config.audioStreamIndex < nbStreams,
              let videoInStream = inCtx.pointee.streams[config.videoStreamIndex],
              let audioInStream = inCtx.pointee.streams[config.audioStreamIndex] else {
            throw RemuxError.streamSetupFailed("Stream index out of bounds (have \(nbStreams) streams)")
        }

        // 2. Open HLS output
        let hlsPath = (config.outputDirectory as NSString).appendingPathComponent("stream.m3u8")
        let segmentPattern = (config.outputDirectory as NSString).appendingPathComponent("segment_%d.ts")

        var outputCtx: UnsafeMutablePointer<AVFormatContext>?
        ret = avformat_alloc_output_context2(&outputCtx, nil, "hls", hlsPath)
        guard ret == 0, let outCtx = outputCtx else {
            throw RemuxError.openOutputFailed(ffmpegError(ret))
        }

        // Configure HLS muxer options
        var opts: OpaquePointer?
        av_dict_set(&opts, "hls_time", "\(config.segmentDuration)", 0)
        av_dict_set(&opts, "hls_segment_filename", segmentPattern, 0)
        av_dict_set(&opts, "hls_flags", "independent_segments+delete_segments", 0)
        // Sliding window: keep last 15 segments in playlist (~90s buffer for AVPlayer)
        av_dict_set(&opts, "hls_list_size", "15", 0)
        av_dict_set(&opts, "hls_start_number_source", "generic", 0)
        av_dict_set(&opts, "start_number", "\(config.segmentStartIndex)", 0)

        // 3. Set up output streams
        guard let videoOutStream = avformat_new_stream(outCtx, nil) else {
            av_dict_free(&opts)
            avformat_free_context(outCtx)
            throw RemuxError.streamSetupFailed("Failed to create video output stream")
        }
        ret = avcodec_parameters_copy(videoOutStream.pointee.codecpar, videoInStream.pointee.codecpar)
        guard ret >= 0 else {
            av_dict_free(&opts)
            avformat_free_context(outCtx)
            throw RemuxError.streamSetupFailed("Failed to copy video params: \(ffmpegError(ret))")
        }
        videoOutStream.pointee.codecpar.pointee.codec_tag = 0
        videoOutStream.pointee.time_base = videoInStream.pointee.time_base
        let videoOutIndex = Int(videoOutStream.pointee.index)

        // Audio output stream
        let audioOutStream: UnsafeMutablePointer<AVStream>
        var audioDecCtx: UnsafeMutablePointer<AVCodecContext>?
        var audioEncCtx: UnsafeMutablePointer<AVCodecContext>?
        var swrCtx: OpaquePointer?

        if config.transcodeAudio {
            do {
                let (decCtx, encCtx, swr, outStream) = try setupAudioTranscode(
                    inCtx: inCtx, outCtx: outCtx, audioInStream: audioInStream
                )
                audioDecCtx = decCtx
                audioEncCtx = encCtx
                swrCtx = swr
                audioOutStream = outStream
            } catch {
                av_dict_free(&opts)
                avformat_free_context(outCtx)
                throw error
            }
        } else {
            guard let outStream = avformat_new_stream(outCtx, nil) else {
                av_dict_free(&opts)
                avformat_free_context(outCtx)
                throw RemuxError.streamSetupFailed("Failed to create audio output stream")
            }
            ret = avcodec_parameters_copy(outStream.pointee.codecpar, audioInStream.pointee.codecpar)
            guard ret >= 0 else {
                av_dict_free(&opts)
                avformat_free_context(outCtx)
                throw RemuxError.streamSetupFailed("Failed to copy audio params: \(ffmpegError(ret))")
            }
            outStream.pointee.codecpar.pointee.codec_tag = 0
            outStream.pointee.time_base = audioInStream.pointee.time_base
            audioOutStream = outStream
        }
        let audioOutIndex = Int(audioOutStream.pointee.index)

        // Cleanup closure for all FFmpeg resources
        defer {
            if audioDecCtx != nil { avcodec_free_context(&audioDecCtx) }
            if audioEncCtx != nil { avcodec_free_context(&audioEncCtx) }
            if swrCtx != nil { swr_free(&swrCtx) }
            // Close I/O before freeing context
            if outCtx.pointee.pb != nil {
                avio_closep(&outCtx.pointee.pb)
            }
            av_dict_free(&opts)
            avformat_free_context(outCtx)
        }

        // 4. Open output I/O and write header
        log("Opening HLS output: \(hlsPath)")
        ret = avio_open(&outCtx.pointee.pb, hlsPath, AVIO_FLAG_WRITE)
        guard ret >= 0 else {
            log("Failed to open HLS output: \(ffmpegError(ret))")
            throw RemuxError.openOutputFailed("Failed to open output: \(ffmpegError(ret))")
        }

        ret = avformat_write_header(outCtx, &opts)
        guard ret >= 0 else {
            log("Failed to write HLS header: \(ffmpegError(ret))")
            throw RemuxError.openOutputFailed("Failed to write header: \(ffmpegError(ret))")
        }
        log("HLS muxer ready, starting packet loop (video=\(config.videoStreamIndex), audio=\(config.audioStreamIndex), transcode=\(config.transcodeAudio))")

        // 5. Read packets and write to output
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let pkt = packet else {
            throw RemuxError.writeFailed("Failed to allocate packet")
        }

        var lastSegmentCount = 0
        var lastProgressReport: Double = 0

        while !isCancelled {
            ret = av_read_frame(inCtx, pkt)
            if ret < 0 { break }

            let streamIndex = Int(pkt.pointee.stream_index)

            if streamIndex == config.videoStreamIndex {
                // Capture PTS before write (write takes ownership and unrefs)
                av_packet_rescale_ts(pkt, videoInStream.pointee.time_base, videoOutStream.pointee.time_base)
                let pts = pkt.pointee.pts
                let tb = videoOutStream.pointee.time_base
                pkt.pointee.stream_index = Int32(videoOutIndex)
                ret = av_interleaved_write_frame(outCtx, pkt)
                // pkt is now unreffed by write — do NOT access pkt.pointee after this

                // Report progress from captured PTS
                if pts != Int64.min && pts >= 0 {
                    let timeSec = Double(pts) * av_q2d(tb)
                    if timeSec - lastProgressReport > 5 {
                        _callbacks.onProgress?(timeSec, totalDuration)
                        lastProgressReport = timeSec
                    }
                }

            } else if streamIndex == config.audioStreamIndex {
                if config.transcodeAudio, let decCtx = audioDecCtx, let encCtx = audioEncCtx, let swr = swrCtx {
                    try transcodeAudioPacket(
                        packet: pkt, decCtx: decCtx, encCtx: encCtx, swrCtx: swr,
                        inStream: audioInStream, outStream: audioOutStream,
                        outCtx: outCtx, outIndex: audioOutIndex
                    )
                } else {
                    av_packet_rescale_ts(pkt, audioInStream.pointee.time_base, audioOutStream.pointee.time_base)
                    pkt.pointee.stream_index = Int32(audioOutIndex)
                    av_interleaved_write_frame(outCtx, pkt)
                }
            } else {
                av_packet_unref(pkt)
            }
            // Note: no av_packet_unref here — av_interleaved_write_frame already unreffed,
            // and for skipped streams we unref above
        }

        if isCancelled {
            log("Remux cancelled")
        } else {
            log("Source EOF reached, flushing...")
        }

        // Flush audio decoder then encoder if transcoding
        if config.transcodeAudio, let decCtx = audioDecCtx, let encCtx = audioEncCtx {
            flushDecoder(decCtx: decCtx, encCtx: encCtx, swrCtx: swrCtx!,
                         outStream: audioOutStream, outCtx: outCtx, outIndex: audioOutIndex)
            flushEncoder(encCtx: encCtx, outStream: audioOutStream, outCtx: outCtx, outIndex: audioOutIndex)
        }

        av_write_trailer(outCtx)
        log("HLS trailer written, remux complete")

        if isCancelled {
            throw RemuxError.cancelled
        }
    }

    // MARK: - Audio Transcode

    private func setupAudioTranscode(
        inCtx: UnsafeMutablePointer<AVFormatContext>,
        outCtx: UnsafeMutablePointer<AVFormatContext>,
        audioInStream: UnsafeMutablePointer<AVStream>
    ) throws -> (
        UnsafeMutablePointer<AVCodecContext>,
        UnsafeMutablePointer<AVCodecContext>,
        OpaquePointer,
        UnsafeMutablePointer<AVStream>
    ) {
        let codecpar = audioInStream.pointee.codecpar!
        guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw RemuxError.encoderSetupFailed("No decoder for audio codec")
        }
        guard let decCtx = avcodec_alloc_context3(decoder) else {
            throw RemuxError.encoderSetupFailed("Failed to alloc decoder context")
        }
        var ret = avcodec_parameters_to_context(decCtx, codecpar)
        guard ret >= 0 else { throw RemuxError.encoderSetupFailed(ffmpegError(ret)) }
        ret = avcodec_open2(decCtx, decoder, nil)
        guard ret >= 0 else { throw RemuxError.encoderSetupFailed(ffmpegError(ret)) }

        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_AAC) else {
            throw RemuxError.encoderSetupFailed("AAC encoder not found")
        }
        guard let encCtx = avcodec_alloc_context3(encoder) else {
            throw RemuxError.encoderSetupFailed("Failed to alloc encoder context")
        }

        let srcChannels = Int(decCtx.pointee.ch_layout.nb_channels)
        let outChannels = min(srcChannels, 6)

        encCtx.pointee.sample_rate = decCtx.pointee.sample_rate > 0 ? decCtx.pointee.sample_rate : 48000
        encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        encCtx.pointee.bit_rate = outChannels <= 2 ? 192000 : 384000

        if outChannels <= 2 {
            av_channel_layout_default(&encCtx.pointee.ch_layout, 2)
        } else {
            av_channel_layout_default(&encCtx.pointee.ch_layout, Int32(outChannels))
        }

        ret = avcodec_open2(encCtx, encoder, nil)
        guard ret >= 0 else { throw RemuxError.encoderSetupFailed(ffmpegError(ret)) }

        var swrCtx: OpaquePointer?
        ret = swr_alloc_set_opts2(
            &swrCtx,
            &encCtx.pointee.ch_layout, encCtx.pointee.sample_fmt, encCtx.pointee.sample_rate,
            &decCtx.pointee.ch_layout, decCtx.pointee.sample_fmt, decCtx.pointee.sample_rate,
            0, nil
        )
        guard ret >= 0, let swr = swrCtx else { throw RemuxError.encoderSetupFailed(ffmpegError(ret)) }
        ret = swr_init(swr)
        guard ret >= 0 else { throw RemuxError.encoderSetupFailed(ffmpegError(ret)) }

        guard let outStream = avformat_new_stream(outCtx, encoder) else {
            throw RemuxError.streamSetupFailed("Failed to create audio output stream")
        }
        ret = avcodec_parameters_from_context(outStream.pointee.codecpar, encCtx)
        guard ret >= 0 else { throw RemuxError.streamSetupFailed(ffmpegError(ret)) }
        outStream.pointee.time_base = AVRational(num: 1, den: encCtx.pointee.sample_rate)

        return (decCtx, encCtx, swr, outStream)
    }

    private var audioPacketCount = 0
    private var audioFrameCount = 0
    private var audioEncodeCount = 0

    private func transcodeAudioPacket(
        packet: UnsafeMutablePointer<AVPacket>,
        decCtx: UnsafeMutablePointer<AVCodecContext>,
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        swrCtx: OpaquePointer,
        inStream: UnsafeMutablePointer<AVStream>,
        outStream: UnsafeMutablePointer<AVStream>,
        outCtx: UnsafeMutablePointer<AVFormatContext>,
        outIndex: Int
    ) throws {
        av_packet_rescale_ts(packet, inStream.pointee.time_base, decCtx.pointee.time_base)
        var ret = avcodec_send_packet(decCtx, packet)
        if ret < 0 {
            audioPacketCount += 1
            if audioPacketCount <= 3 {
                log("Audio decode send failed (\(audioPacketCount)): \(ffmpegError(ret))")
            }
            return
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let frm = frame else { return }

        var encPkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&encPkt) }
        guard let ep = encPkt else { return }

        while true {
            ret = avcodec_receive_frame(decCtx, frm)
            if ret == errEAGAIN || ret == errEOF { break }
            if ret < 0 {
                if audioFrameCount == 0 { log("Audio receive frame failed: \(ffmpegError(ret))") }
                break
            }
            audioFrameCount += 1
            if audioFrameCount == 1 {
                log("First audio frame: \(frm.pointee.nb_samples) samples, \(frm.pointee.ch_layout.nb_channels)ch, rate=\(frm.pointee.sample_rate)")
            }

            // Use swr_convert_frame which handles buffer allocation and multi-plane formats correctly
            var outFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&outFrame) }
            guard let oFrm = outFrame else { av_frame_unref(frm); continue }

            oFrm.pointee.sample_rate = encCtx.pointee.sample_rate
            oFrm.pointee.format = encCtx.pointee.sample_fmt.rawValue
            oFrm.pointee.ch_layout = encCtx.pointee.ch_layout

            let convertRet = swr_convert_frame(swrCtx, oFrm, frm)
            if convertRet < 0 {
                if audioFrameCount <= 3 { log("swr_convert_frame failed: \(ffmpegError(convertRet))") }
                av_frame_unref(oFrm)
                av_frame_unref(frm)
                continue
            }
            oFrm.pointee.pts = frm.pointee.pts

            let sendRet = avcodec_send_frame(encCtx, oFrm)
            if sendRet < 0 {
                if audioEncodeCount == 0 { log("Audio encode send failed: \(ffmpegError(sendRet))") }
            } else {
                while true {
                    let encRet = avcodec_receive_packet(encCtx, ep)
                    if encRet < 0 { break }
                    audioEncodeCount += 1
                    av_packet_rescale_ts(ep, encCtx.pointee.time_base, outStream.pointee.time_base)
                    ep.pointee.stream_index = Int32(outIndex)
                    av_interleaved_write_frame(outCtx, ep)
                }
                if audioEncodeCount == 1 { log("First encoded audio packet written") }
            }

            av_frame_unref(oFrm)
            av_frame_unref(frm)
        }
    }

    /// Flush the audio decoder to drain buffered frames.
    private func flushDecoder(
        decCtx: UnsafeMutablePointer<AVCodecContext>,
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        swrCtx: OpaquePointer,
        outStream: UnsafeMutablePointer<AVStream>,
        outCtx: UnsafeMutablePointer<AVFormatContext>,
        outIndex: Int
    ) {
        avcodec_send_packet(decCtx, nil)

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let frm = frame else { return }

        var encPkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&encPkt) }
        guard let ep = encPkt else { return }

        while true {
            let ret = avcodec_receive_frame(decCtx, frm)
            if ret < 0 { break }

            var outFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&outFrame) }
            guard let oFrm = outFrame else { av_frame_unref(frm); continue }

            oFrm.pointee.sample_rate = encCtx.pointee.sample_rate
            oFrm.pointee.format = encCtx.pointee.sample_fmt.rawValue
            oFrm.pointee.ch_layout = encCtx.pointee.ch_layout

            let convertRet = swr_convert_frame(swrCtx, oFrm, frm)
            guard convertRet >= 0 else { av_frame_unref(frm); continue }
            oFrm.pointee.pts = frm.pointee.pts

            if avcodec_send_frame(encCtx, oFrm) >= 0 {
                while avcodec_receive_packet(encCtx, ep) >= 0 {
                    av_packet_rescale_ts(ep, encCtx.pointee.time_base, outStream.pointee.time_base)
                    ep.pointee.stream_index = Int32(outIndex)
                    av_interleaved_write_frame(outCtx, ep)
                }
            }
            av_frame_unref(frm)
        }
    }

    private func flushEncoder(
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        outStream: UnsafeMutablePointer<AVStream>,
        outCtx: UnsafeMutablePointer<AVFormatContext>,
        outIndex: Int
    ) {
        avcodec_send_frame(encCtx, nil)

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let p = pkt else { return }

        while true {
            let ret = avcodec_receive_packet(encCtx, p)
            if ret < 0 { break }
            av_packet_rescale_ts(p, encCtx.pointee.time_base, outStream.pointee.time_base)
            p.pointee.stream_index = Int32(outIndex)
            av_interleaved_write_frame(outCtx, p)
        }
    }

    // MARK: - Helpers

    private var errEAGAIN: Int32 { -11 }
    private var errEOF: Int32 {
        let tag = (Int32(Character("E").asciiValue!) |
                   (Int32(Character("O").asciiValue!) << 8) |
                   (Int32(Character("F").asciiValue!) << 16) |
                   (Int32(Character(" ").asciiValue!) << 24))
        return -tag
    }

    private func ffmpegError(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buf, 128)
        return String(cString: buf)
    }
}
