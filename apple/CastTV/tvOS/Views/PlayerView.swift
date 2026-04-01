import SwiftUI
import AVKit
import CastTVShared

struct PlayerView: UIViewControllerRepresentable {
    let playMessage: PlayMessage
    let appState: TVAppState
    @ObservedObject var remuxService: RemuxService

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        context.coordinator.playerVC = vc
        context.coordinator.appState = appState
        context.coordinator.remuxService = remuxService
        loadAndPlay(playMessage, in: vc, coordinator: context.coordinator)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if context.coordinator.currentURL != playMessage.url {
            loadAndPlay(playMessage, in: vc, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadAndPlay(_ msg: PlayMessage, in vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.currentURL = msg.url

        guard let sourceURL = URL(string: msg.url) else {
            appState.reportError(code: "invalid_url", message: "Invalid URL: \(msg.url)")
            return
        }

        let playbackURL: URL

        if msg.needsProcessing, let processing = msg.processing {
            // V2: Start remux pipeline and play from local server
            let transcodeAudio = processing.audioTranscode != nil
            remuxService.start(
                sourceURL: msg.url,
                videoStreamIndex: msg.tracks?.video ?? 0,
                audioStreamIndex: msg.tracks?.audio ?? 1,
                subtitleStreamIndex: msg.tracks?.subtitle,
                transcodeAudio: transcodeAudio
            )

            guard let localURL = remuxService.playbackURL else {
                appState.reportError(code: "remux_failed", message: "Failed to start remux pipeline")
                return
            }
            playbackURL = localURL
            CastTVLogger.shared.info("Playing via remux: \(localURL.absoluteString)")

            // Wait for FFmpeg to produce the first segment before starting AVPlayer.
            // Read the m3u8 directly from disk (not via HTTP) to avoid overhead.
            // Wait for first segment then start playback.
            // We pass everything needed to the coordinator so it survives SwiftUI view updates.
            coordinator.pendingPlayback = (vc, playbackURL, msg)
            let storageDir = remuxService.storageDirectory
            let remux = remuxService
            Task {
                CastTVLogger.shared.info("Waiting for HLS segments (dir: \(storageDir?.path ?? "nil"))...")
                var found = false
                for i in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if case .error = remux.state {
                        CastTVLogger.shared.error("Remux errored while waiting for segments")
                        break
                    }
                    if let dir = storageDir,
                       let content = try? String(contentsOf: dir.appendingPathComponent("stream.m3u8")),
                       content.contains(".ts") {
                        CastTVLogger.shared.info("HLS ready after \(Double(i) * 0.5)s, starting playback")
                        found = true
                        break
                    }
                }
                if !found {
                    CastTVLogger.shared.warning("HLS wait timed out after 30s")
                }

                await MainActor.run { [weak coordinator] in
                    guard let coordinator, let pending = coordinator.pendingPlayback else { return }
                    coordinator.pendingPlayback = nil
                    self.startPlayback(vc: pending.0, url: pending.1, coordinator: coordinator, msg: pending.2)
                }
            }
            return
        } else {
            // V1: Direct playback
            playbackURL = sourceURL
        }

        startPlayback(vc: vc, url: playbackURL, coordinator: coordinator, msg: msg)
    }

    private func startPlayback(vc: AVPlayerViewController, url: URL, coordinator: Coordinator, msg: PlayMessage) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        // Buffer 60s ahead to reduce stuttering on variable-bandwidth networks
        item.preferredForwardBufferDuration = 60

        if let existingPlayer = vc.player {
            existingPlayer.replaceCurrentItem(with: item)
        } else {
            let player = AVPlayer(playerItem: item)
            vc.player = player
        }

        coordinator.isRemuxed = msg.needsProcessing
        coordinator.observePlayer(vc.player!, item: item, url: msg.url)

        // Resume: seek to saved position
        let resume = ResumeStorage.shared
        if let savedPosition = resume.load(for: msg.url) {
            let time = CMTime(seconds: savedPosition, preferredTimescale: 600)
            vc.player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        vc.player?.play()
        coordinator.startPositionSaving(url: msg.url)
    }

    final class Coordinator: NSObject {
        var playerVC: AVPlayerViewController?
        var appState: TVAppState?
        var remuxService: RemuxService?
        var currentURL: String?
        var isRemuxed: Bool = false
        var pendingPlayback: (AVPlayerViewController, URL, PlayMessage)?
        private var errorObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
        private var bufferEmptyObservation: NSKeyValueObservation?
        private var timeObserverToken: Any?
        private var lastKnownTime: Double = 0

        func observePlayer(_ player: AVPlayer, item: AVPlayerItem, url: String) {
            errorObservation?.invalidate()
            statusObservation?.invalidate()
            bufferEmptyObservation?.invalidate()
            if let token = timeObserverToken {
                player.removeTimeObserver(token)
                timeObserverToken = nil
            }
            NotificationCenter.default.removeObserver(self)

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    let errorMsg = item.error?.localizedDescription ?? "Unknown playback error"
                    Task { @MainActor in
                        self?.appState?.reportError(code: "playback_failed", message: errorMsg)
                    }
                }
            }

            errorObservation = item.observe(\.error, options: [.new]) { [weak self] item, _ in
                if let error = item.error {
                    Task { @MainActor in
                        self?.appState?.reportError(code: "playback_error", message: error.localizedDescription)
                    }
                }
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemFailed(_:)),
                name: .AVPlayerItemFailedToPlayToEndTime,
                object: item
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemDidEnd(_:)),
                name: .AVPlayerItemDidPlayToEndTime,
                object: item
            )

            // For remuxed content: detect seeks beyond buffered range.
            // Only trigger if buffer is empty AND there was a large time discontinuity (>30s).
            // Normal playback pauses won't trigger this since lastKnownTime tracks smoothly.
            if isRemuxed {
                bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
                    guard let self, self.isRemuxed, item.isPlaybackBufferEmpty else { return }
                    let currentTime = item.currentTime().seconds
                    if currentTime.isFinite && self.lastKnownTime > 0 && abs(currentTime - self.lastKnownTime) > 30 {
                        let seekTarget = currentTime
                        // Reset to prevent retriggering
                        self.lastKnownTime = seekTarget
                        Task { @MainActor [weak self] in
                            self?.remuxService?.seekTo(timeSeconds: seekTarget)
                        }
                    }
                }
            }
        }

        func startPositionSaving(url: String) {
            guard let player = playerVC?.player else { return }

            // Save position every 10 seconds
            let interval = CMTime(seconds: 10, preferredTimescale: 600)
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self, let currentURL = self.currentURL else { return }
                let seconds = time.seconds
                if seconds.isFinite && seconds > 0 {
                    self.lastKnownTime = seconds
                    ResumeStorage.shared.save(position: seconds, for: currentURL)
                }
            }
        }

        @objc private func playerItemFailed(_ notification: Notification) {
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                Task { @MainActor [weak self] in
                    self?.appState?.reportError(code: "playback_failed", message: error.localizedDescription)
                }
            }
        }

        @objc private func playerItemDidEnd(_ notification: Notification) {
            // Clear resume position when playback reaches the end
            if let url = currentURL {
                ResumeStorage.shared.clear(for: url)
            }
            Task { @MainActor [weak self] in
                self?.remuxService?.stop()
                self?.appState?.stopPlayback()
            }
        }

        deinit {
            errorObservation?.invalidate()
            statusObservation?.invalidate()
            bufferEmptyObservation?.invalidate()
            if let token = timeObserverToken, let player = playerVC?.player {
                player.removeTimeObserver(token)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }
}
