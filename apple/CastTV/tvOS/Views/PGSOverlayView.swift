import SwiftUI
import UIKit

/// Displays a single PGS bitmap subtitle image, positioned and scaled
/// to match the original video coordinates with letterbox offset.
///
/// This view is intentionally stateless — the Coordinator in PlayerView
/// manages the time observer and updates the displayed image/position.
struct PGSOverlayView: View {
    let image: UIImage?
    let entry: PGSManifest.Entry?
    let videoSize: CGSize

    var body: some View {
        // `geo` is used via `geo.size` below; SwiftLint's analyzer misses it
        // (likely confused by the `if let image, let entry` shadowing).
        // swiftlint:disable:next unused_closure_parameter
        GeometryReader { geo in
            if let image, let entry {
                let scale = scaleFactor(viewSize: geo.size)
                let offset = letterboxOffset(viewSize: geo.size, scale: scale)
                Image(uiImage: image)
                    .interpolation(.high)
                    .resizable()
                    .frame(
                        width: CGFloat(entry.width) * scale,
                        height: CGFloat(entry.height) * scale
                    )
                    .position(
                        x: offset.x + (CGFloat(entry.x) + CGFloat(entry.width) / 2) * scale,
                        y: offset.y + (CGFloat(entry.y) + CGFloat(entry.height) / 2) * scale
                    )
            }
        }
    }

    /// Uniform scale factor to fit video into view while preserving aspect ratio.
    private func scaleFactor(viewSize: CGSize) -> CGFloat {
        guard videoSize.width > 0, videoSize.height > 0 else { return 1 }
        return min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
    }

    /// Offset to center the scaled video within the view (letterbox/pillarbox).
    private func letterboxOffset(viewSize: CGSize, scale: CGFloat) -> CGPoint {
        CGPoint(
            x: (viewSize.width - videoSize.width * scale) / 2,
            y: (viewSize.height - videoSize.height * scale) / 2
        )
    }
}
