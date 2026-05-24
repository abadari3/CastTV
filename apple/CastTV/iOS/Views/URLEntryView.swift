import CastTVShared
import SwiftUI

struct URLEntryView: View {
    let device: PairedDevice
    @ObservedObject var appState: iOSAppState
    @State private var urlText: String = ""
    @State private var subtitleURLText: String = ""
    @State private var showSubtitleField = false
    @State private var probeResult: ProbeResult?
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var clipboardURL: String?
    @State private var isCasting = false
    @State private var castError: String?
    @State private var historyEntries: [URLHistoryEntry] = []
    @FocusState private var urlFieldFocused: Bool

    // Track selection
    @State private var selectedVideoID: Int?
    @State private var selectedAudioID: Int?
    @State private var selectedSubtitleID: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Device info bar
                if let caps = device.capabilities {
                    HStack(spacing: 16) {
                        Label(caps.display.resolution, systemImage: "display")
                        if !caps.display.hdrModes.isEmpty {
                            Label(caps.display.hdrModes.map { DisplayCapabilities.hdrLabel($0) }.joined(separator: "/"), systemImage: "sparkles.tv")
                        }
                        Label("\(caps.audio.maxChannels)ch", systemImage: "speaker.wave.3")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // URL input
                VStack(spacing: 8) {
                    HStack {
                        TextField("Enter video URL", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($urlFieldFocused)
                            .onSubmit { probeURL() }

                        if isProbing {
                            ProgressView()
                        } else {
                            Button("Probe") { probeURL() }
                                .buttonStyle(.borderedProminent)
                                .disabled(urlText.isEmpty)
                        }
                    }

                    // External subtitle URL — hidden by default
                    if showSubtitleField {
                        HStack {
                            TextField("External subtitle URL (.vtt)", text: $subtitleURLText)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption)

                            Button { showSubtitleField = false; subtitleURLText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        if let clip = clipboardURL, clip != urlText {
                            Button {
                                urlText = clip
                                probeURL()
                            } label: {
                                Label("Paste: \(clip.prefix(40))...", systemImage: "doc.on.clipboard")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if !showSubtitleField {
                            Button {
                                showSubtitleField = true
                            } label: {
                                Label("Subtitles", systemImage: "captions.bubble")
                                    .font(.caption)
                            }
                        }
                    }
                }
                .padding(.horizontal)

                if let error = probeError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding(.horizontal)
                }

                if let result = probeResult {
                    ProbeResultsView(
                        result: result,
                        capabilities: device.capabilities,
                        selectedVideoID: $selectedVideoID,
                        selectedAudioID: $selectedAudioID,
                        selectedSubtitleID: $selectedSubtitleID
                    )

                    castButton(result: result)
                }

                if let error = castError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    .font(.callout)
                    .padding(.horizontal)
                }

                // URL History — card style with swipe to delete
                if !historyEntries.isEmpty && probeResult == nil {
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Recent", systemImage: "clock")
                            .font(.subheadline.bold())
                            .padding(.horizontal)
                            .padding(.bottom, 8)

                        List {
                            ForEach(historyEntries) { entry in
                                HistoryCard(entry: entry) {
                                    urlText = entry.url
                                    probeURL()
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                            .onDelete { offsets in
                                for offset in offsets {
                                    URLHistory.shared.remove(historyEntries[offset].url)
                                }
                                historyEntries = URLHistory.shared.loadEntries()
                            }
                        }
                        .listStyle(.plain)
                        .frame(maxHeight: 384)
                        .scrollDisabled(historyEntries.count <= 6)
                    }
                }

                Spacer()
            }
            .padding(.top)
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            NavigationLink {
                LogViewerView(device: device, appState: appState)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
        }
        .onAppear {
            checkClipboard()
            historyEntries = URLHistory.shared.loadEntries()
        }
    }

    @ViewBuilder
    private func castButton(result: ProbeResult) -> some View {
        let compats = selectedCompatibilities(result: result)
        let status = CompatibilityEngine.overallStatus(compats)

        VStack(spacing: 8) {
            Button {
                cast(result: result)
            } label: {
                HStack {
                    if isCasting {
                        ProgressView()
                            .tint(.white)
                    }
                    Image(systemName: "play.tv")
                    Text("Cast to \(device.name)")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(status == .unsupported ? .gray : (status == .needsProcessing ? .orange : .blue))
            .disabled(status == .unsupported || isCasting)
            .padding(.horizontal)

            if status == .needsProcessing {
                Text("Will remux/transcode on \(device.name)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if status == .unsupported {
                Text("Selected tracks contain unsupported formats")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func cast(result: ProbeResult) {
        isCasting = true
        castError = nil

        guard let key = appState.encryptionKey(for: device) else {
            castError = "Encryption key not found — try re-pairing"
            isCasting = false
            return
        }

        // Validate subtitle URL if provided
        let subtitleURL: String?
        if showSubtitleField && !subtitleURLText.isEmpty {
            let trimmed = subtitleURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard URL(string: trimmed) != nil else {
                castError = "Invalid subtitle URL"
                isCasting = false
                return
            }
            subtitleURL = trimmed
        } else {
            subtitleURL = nil
        }

        // Compute processing requirements
        let processing = computeProcessing(result: result)

        let playMsg = PlayMessage(
            url: result.url.absoluteString,
            subtitleUrl: subtitleURL,
            tracks: TrackSelection(
                video: selectedVideoID,
                audio: selectedAudioID,
                subtitle: selectedSubtitleID
            ),
            processing: processing
        )

        // Save to history with metadata
        URLHistory.shared.add(result.url.absoluteString, title: result.title, coverArt: result.coverArt)
        historyEntries = URLHistory.shared.loadEntries()

        let config = WebSocketClient.Configuration(
            serverBaseURL: CastTVConstants.serverBaseURL,
            roomCode: device.roomCode,
            role: "iphone",
            encryptionKey: key
        )

        let ws = WebSocketClient(configuration: config)
        ws.connect()

        Task {
            for await state in ws.states {
                if case .connected = state { break }
            }

            do {
                try await ws.send(.play(playMsg))
            } catch {
                castError = "Failed to send: \(error.localizedDescription)"
                isCasting = false
                ws.disconnect()
                return
            }

            Task {
                for await message in ws.messages {
                    if case .error(let err) = message {
                        castError = err.message
                        break
                    }
                }
            }

            try? await Task.sleep(for: .seconds(10))
            ws.disconnect()
            isCasting = false
        }
    }

    private func probeURL() {
        urlFieldFocused = false // dismiss keyboard

        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            probeError = "Invalid URL — must start with http:// or https://"
            return
        }

        isProbing = true
        probeError = nil
        probeResult = nil
        castError = nil

        Task {
            do {
                let result = try await MediaProber.probe(url: url)
                probeResult = result
                setDefaults(for: result)
            } catch {
                probeError = error.localizedDescription
            }
            isProbing = false
        }
    }

    private func setDefaults(for result: ProbeResult) {
        selectedVideoID = result.videoTracks.first?.id
        if let nativeAudio = result.audioTracks.first(where: {
            CompatibilityEngine.check(audio: $0, container: result.container, capabilities: device.capabilities).isGreen
        }) {
            selectedAudioID = nativeAudio.id
        } else {
            selectedAudioID = result.audioTracks.first?.id
        }
        selectedSubtitleID = nil
    }

    private func selectedCompatibilities(result: ProbeResult) -> [TrackCompatibility] {
        CompatibilityEngine.selectedCompatibilities(
            result: result, selectedVideoID: selectedVideoID,
            selectedAudioID: selectedAudioID, selectedSubtitleID: selectedSubtitleID,
            capabilities: device.capabilities
        )
    }

    private func computeProcessing(result: ProbeResult) -> ProcessingRequirements? {
        CompatibilityEngine.computeProcessing(
            result: result, selectedVideoID: selectedVideoID,
            selectedAudioID: selectedAudioID, selectedSubtitleID: selectedSubtitleID,
            capabilities: device.capabilities
        )
    }

    private func checkClipboard() {
        if UIPasteboard.general.hasStrings,
           let str = UIPasteboard.general.string,
           let url = URL(string: str),
           url.scheme?.hasPrefix("http") == true {
            clipboardURL = str
        }
    }

}
