import CastTVShared
import FFmpegKit
import SwiftUI

/// Combined home screen for tvOS.
/// Left side: QR code for pairing. Right side: status + Enter URL.
struct TVHomeView: View {
    @ObservedObject var appState: TVAppState
    @State private var showDirectURL = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left: QR code
                qrSection
                    .frame(maxWidth: .infinity)

                Divider()
                    .padding(.vertical, 60)

                // Right: status + actions
                statusSection
                    .frame(maxWidth: .infinity)
            }

            // Pairing string at the bottom, full width
            if !appState.qrString.isEmpty {
                Text(appState.qrString)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.quaternary)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .onAppear {
            if appState.roomCode.isEmpty {
                appState.startPairing()
            }
            #if targetEnvironment(simulator)
            if let urlString = ProcessInfo.processInfo.environment["CASTTV_AUTO_PLAY"],
               !urlString.isEmpty {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    // Probe to find correct stream indices
                    var videoIdx = 0, audioIdx = 1
                    if let url = URL(string: urlString) {
                        let result = try? FFProber.probe(url: url)
                        if let v = result?.videoTracks.first { videoIdx = v.index }
                        if let a = result?.audioTracks.first { audioIdx = a.index }
                        CastTVLogger.shared.info("Auto-play probe: video=\(videoIdx), audio=\(audioIdx)")
                    }
                    let playMsg = PlayMessage(
                        url: urlString,
                        tracks: TrackSelection(video: videoIdx, audio: audioIdx, subtitle: nil),
                        processing: ProcessingRequirements(remux: true)
                    )
                    appState.isPlaying = true
                    appState.currentURL = urlString
                    appState.onPlayRequest?(playMsg)
                }
            }
            #endif
        }
        .sheet(isPresented: $showDirectURL) {
            DirectURLView(appState: appState)
        }
    }

    // MARK: - QR Section

    @ViewBuilder
    private var qrSection: some View {
        VStack(spacing: 24) {
            Text("CastTV")
                .font(.largeTitle)
                .bold()

            if appState.isConnecting {
                ProgressView("Setting up...")
            } else if let qrImage = appState.qrCodeImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .background(Color.white)
                    .cornerRadius(12)

                Text("Scan with CastTV iPhone app")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(appState.roomCode)
                    .font(.title3)
                    .monospaced()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Generating QR code...")
            }
        }
        .padding(20)
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 24) {
            Spacer()

            // Connection status — centered
            VStack(spacing: 16) {
                if appState.connectedDeviceName != nil {
                    // iPhone actively connected right now
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("iPhone connected")
                        .font(.headline)
                        .foregroundStyle(.green)

                    Text("Send a URL from your iPhone to start casting")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                } else if appState.hasEverPaired {
                    // Paired before, iPhone just not connected right now
                    Image(systemName: "iphone")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Ready")
                        .font(.headline)

                    Text("Open CastTV on your iPhone to cast")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                } else {
                    // Never paired
                    Image(systemName: "iphone.badge.play")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Scan the QR code")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text("Use the CastTV iPhone app to pair")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }

            // Playback error
            if let error = appState.playbackError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.red)
                }
                .font(.callout)
            }

            Spacer()

            // Actions
            Button {
                showDirectURL = true
            } label: {
                Label("Enter URL Directly", systemImage: "keyboard")
            }

            // Error
            if let error = appState.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(20)
    }
}
