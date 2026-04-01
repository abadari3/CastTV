import Foundation
import AVFoundation
import FFmpegKit
import os

private let logger = Logger(subsystem: "com.casttv.ios", category: "ProbeTest")

enum ProbeTest {
    static func run() {
        // Test FFmpeg probing with a native HLS stream
        testFFmpegProbe()

        let urls = [
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
            "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8",
        ]

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            let asset = AVURLAsset(url: url)

            Task {
                logger.info("=== \(url.lastPathComponent) ===")

                do {
                    let tracks = try await asset.load(.tracks)
                    logger.info("Tracks: \(tracks.count)")
                    for track in tracks {
                        let mediaType = track.mediaType
                        logger.info("  \(mediaType.rawValue)")
                    }
                } catch {
                    logger.error("Failed to load tracks: \(error)")
                }

                do {
                    let groups = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
                    logger.info("Media characteristics: \(groups.count)")
                    for characteristic in groups {
                        if let group = try? await asset.loadMediaSelectionGroup(for: characteristic) {
                            logger.info("  \(characteristic.rawValue): \(group.options.count) options")
                            for option in group.options {
                                logger.info("    - \(option.displayName) [\(option.mediaType.rawValue)]")
                            }
                        }
                    }
                } catch {
                    logger.error("Failed to load media selections: \(error)")
                }

                do {
                    let variants = try await asset.load(.variants)
                    logger.info("Variants: \(variants.count)")
                } catch {
                    logger.error("Failed to load variants: \(error)")
                }

                logger.info("=== done ===")
            }
        }
    }

    /// Write test results to a file since os.Logger doesn't reliably show in simulator `log show`
    private static let testLogFile: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("ffprobe_test.txt")
    }()

    private static func log(_ msg: String) {
        logger.notice("\(msg)")
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: testLogFile.path) {
                if let fh = try? FileHandle(forWritingTo: testLogFile) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: testLogFile)
            }
        }
    }

    private static func testFFmpegProbe() {
        // Clear previous results
        try? FileManager.default.removeItem(at: testLogFile)

        let testURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8")!

        Task.detached {
            log("=== FFmpeg Probe Test ===")
            log("URL: \(testURL.absoluteString)")
            do {
                let result = try FFProber.probe(url: testURL)
                log("Format: \(result.formatName), duration: \(result.duration ?? -1)")
                log("Tracks: \(result.videoTracks.count) video, \(result.audioTracks.count) audio, \(result.subtitleTracks.count) subtitle")
                for v in result.videoTracks {
                    log("  Video[\(v.index)]: \(v.codecName) \(v.width)x\(v.height) @\(String(format: "%.2f", v.frameRate))fps dv=\(v.isDolbyVision)")
                }
                for a in result.audioTracks {
                    log("  Audio[\(a.index)]: \(a.codecName) \(a.channelCount)ch \(a.sampleRate)Hz lang=\(a.language ?? "?")")
                }
                for s in result.subtitleTracks {
                    log("  Sub[\(s.index)]: \(s.codecName) lang=\(s.language ?? "?") forced=\(s.isForced)")
                }
                log("=== PASSED ===")
            } catch {
                log("=== FAILED: \(error) ===")
            }
        }
    }
}
