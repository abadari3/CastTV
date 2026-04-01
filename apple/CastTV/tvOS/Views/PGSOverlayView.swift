import SwiftUI
import AVFoundation
import UIKit

/// Displays PGS bitmap subtitles as an image overlay synchronized to AVPlayer.
///
/// Reads PGS PNG files from the storage directory and positions them
/// according to the original PGS coordinates, scaled to the current video frame.
struct PGSOverlayView: View {
    let manifest: PGSManifest
    let storageDirectory: URL
    let player: AVPlayer
    /// The original video resolution used to scale PGS coordinates.
    let videoSize: CGSize

    @State private var currentEntry: PGSManifest.Entry?
    @State private var currentImage: UIImage?

    var body: some View {
        GeometryReader { geo in
            if let image = currentImage, let entry = currentEntry {
                let scale = scaleFactor(viewSize: geo.size, videoSize: videoSize)
                Image(uiImage: image)
                    .interpolation(.high)
                    .resizable()
                    .frame(
                        width: CGFloat(entry.width) * scale,
                        height: CGFloat(entry.height) * scale
                    )
                    .position(
                        x: (CGFloat(entry.x) + CGFloat(entry.width) / 2) * scale,
                        y: (CGFloat(entry.y) + CGFloat(entry.height) / 2) * scale
                    )
            }
        }
        .onAppear { startObserving() }
        .onDisappear { stopObserving() }
    }

    // MARK: - Time Observer

    @State private var timeObserverToken: Any?

    private func startObserving() {
        // Update subtitle overlay ~10 times per second
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }

            let entry = manifest.entry(at: seconds)

            if entry?.index != currentEntry?.index {
                currentEntry = entry
                if let entry {
                    let path = storageDirectory.appendingPathComponent(entry.filename)
                    // Load image from disk — PGS PNGs are small so this is fast
                    currentImage = UIImage(contentsOfFile: path.path)
                } else {
                    currentImage = nil
                }
            }
        }
        timeObserverToken = token
    }

    private func stopObserving() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    /// Compute uniform scale factor to map PGS video coordinates to the current view size.
    private func scaleFactor(viewSize: CGSize, videoSize: CGSize) -> CGFloat {
        guard videoSize.width > 0, videoSize.height > 0 else { return 1 }
        let scaleX = viewSize.width / videoSize.width
        let scaleY = viewSize.height / videoSize.height
        // Use the smaller scale to maintain aspect ratio (letterbox-safe)
        return min(scaleX, scaleY)
    }
}
