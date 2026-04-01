import Foundation
import SwiftUI

/// Shared formatting helpers for display across iOS and tvOS.
public enum Formatting {

    /// Map a track compatibility status to a SwiftUI color.
    public static func compatColor(_ compat: TrackCompatibility) -> Color {
        if compat.isGreen { return .green }
        if compat.isYellow { return .orange }
        return .red
    }

    /// Format a duration in seconds to "H:MM:SS" or "M:SS".
    public static func duration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Format a bitrate in bps to a human-readable string.
    public static func bitrate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f kbps", bps / 1_000) }
        return "\(Int(bps)) bps"
    }
}
