import SwiftUI
import AVKit
import CastTVShared

struct DirectURLView: View {
    @ObservedObject var appState: TVAppState
    @State private var urlText: String = ""
    @State private var isProbing = false
    @State private var probeResult: ProbeResult?
    @State private var probeError: String?

    var body: some View {
        VStack(spacing: 30) {
            Text("Enter URL")
                .font(.headline)

            TextField("Video URL", text: $urlText)
                .textFieldStyle(.plain)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            if isProbing {
                ProgressView("Probing...")
            } else {
                Button("Load") { probeURL() }
                    .disabled(urlText.isEmpty)
            }

            if let error = probeError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let result = probeResult {
                // Track summary
                VStack(alignment: .leading, spacing: 8) {
                    if let title = result.title {
                        Text(title).font(.title3)
                    }

                    HStack(spacing: 20) {
                        Text(result.container.rawValue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(result.container.isNativelySupported ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                            .cornerRadius(6)

                        if let dur = result.duration {
                            Text(formatDuration(dur))
                        }
                    }

                    ForEach(result.videoTracks) { track in
                        let compat = CompatibilityEngine.check(video: track, container: result.container, capabilities: nil)
                        HStack(spacing: 8) {
                            Circle().fill(Formatting.compatColor(compat)).frame(width: 8, height: 8)
                            Text("\(track.codec.rawValue) \(track.resolutionLabel) \(String(format: "%.0f", track.frameRate))fps")
                            if track.isHDR { Text("HDR").foregroundStyle(.orange) }
                            if track.isDolbyVision { Text("DV").foregroundStyle(.purple) }
                        }
                    }

                    ForEach(result.audioTracks) { track in
                        let compat = CompatibilityEngine.check(audio: track, container: result.container)
                        HStack(spacing: 8) {
                            Circle().fill(Formatting.compatColor(compat)).frame(width: 8, height: 8)
                            Text("\(track.codec.rawValue) \(track.channelLayout ?? track.channelLabel)")
                            if let lang = track.language { Text(lang) }
                        }
                    }

                    ForEach(result.subtitleTracks) { track in
                        let compat = CompatibilityEngine.check(subtitle: track)
                        HStack(spacing: 8) {
                            Circle().fill(Formatting.compatColor(compat)).frame(width: 8, height: 8)
                            Text(track.format.rawValue)
                            if let lang = track.language { Text(lang) }
                        }
                    }
                }
                .font(.callout)

                // Play button
                let allCompats = computeCompatibilities(result: result)
                let status = CompatibilityEngine.overallStatus(allCompats)

                Button {
                    playDirectly(result: result)
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                }
                .disabled(status != .ready)

                if status == .needsProcessing {
                    Text("Some tracks need processing (V2)")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else if status == .unsupported {
                    Text("Unsupported tracks")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .padding(40)
    }

    private func probeURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            probeError = "Invalid URL"
            return
        }

        isProbing = true
        probeError = nil
        probeResult = nil

        Task {
            do {
                let result = try await TVMediaProber.probe(url: url)
                probeResult = result
            } catch {
                probeError = error.localizedDescription
            }
            isProbing = false
        }
    }

    private func playDirectly(result: ProbeResult) {
        let playMsg = PlayMessage(
            url: result.url.absoluteString,
            tracks: TrackSelection(
                video: result.videoTracks.first?.id,
                audio: result.audioTracks.first?.id,
                subtitle: nil
            )
        )
        appState.isPlaying = true
        appState.currentURL = result.url.absoluteString
        appState.onPlayRequest?(playMsg)
    }

    private func computeCompatibilities(result: ProbeResult) -> [TrackCompatibility] {
        CompatibilityEngine.selectedCompatibilities(
            result: result,
            selectedVideoID: result.videoTracks.first?.id,
            selectedAudioID: result.audioTracks.first?.id,
            selectedSubtitleID: nil,
            capabilities: nil
        )
    }
}
