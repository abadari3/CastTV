import CastTVShared
import SwiftUI

struct ProbeResultsView: View {
    let result: ProbeResult
    let capabilities: CapabilitiesMessage?
    @Binding var selectedVideoID: Int?
    @Binding var selectedAudioID: Int?
    @Binding var selectedSubtitleID: Int?

    @State private var videoExpanded = false
    @State private var audioExpanded = false
    @State private var subtitleExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cover art + title header
            mediaHeaderSection

            // Asset info
            assetInfoSection

            // Video
            if !result.videoTracks.isEmpty {
                CollapsibleTrackPicker(
                    title: "Video",
                    systemImage: "film",
                    trackCount: result.videoTracks.count,
                    isExpanded: $videoExpanded
                ) {
                    // Summary: selected track
                    if let id = selectedVideoID, let track = result.videoTracks.first(where: { $0.id == id }) {
                        let compat = CompatibilityEngine.check(video: track, container: result.container, capabilities: capabilities)
                        TrackSummaryRow(compatColor: compatColor(compat)) {
                            videoTrackContent(track)
                        }
                    }
                } expanded: {
                    ForEach(result.videoTracks) { track in
                        let compat = CompatibilityEngine.check(video: track, container: result.container, capabilities: capabilities)
                        TrackRow(
                            isSelected: selectedVideoID == track.id,
                            compatibility: compat
                        ) {
                            selectedVideoID = track.id
                            videoExpanded = false
                        } content: {
                            videoTrackContent(track)
                        }
                    }
                }
            }

            // Audio
            if !result.audioTracks.isEmpty {
                CollapsibleTrackPicker(
                    title: "Audio",
                    systemImage: "waveform",
                    trackCount: result.audioTracks.count,
                    isExpanded: $audioExpanded
                ) {
                    if let id = selectedAudioID, let track = result.audioTracks.first(where: { $0.id == id }) {
                        let compat = CompatibilityEngine.check(audio: track, container: result.container, capabilities: capabilities)
                        TrackSummaryRow(compatColor: compatColor(compat)) {
                            audioTrackContent(track)
                        }
                    } else {
                        Text("None selected").font(.caption).foregroundStyle(.secondary)
                    }
                } expanded: {
                    ForEach(result.audioTracks) { track in
                        let compat = CompatibilityEngine.check(audio: track, container: result.container, capabilities: capabilities)
                        TrackRow(
                            isSelected: selectedAudioID == track.id,
                            compatibility: compat
                        ) {
                            selectedAudioID = track.id
                            audioExpanded = false
                        } content: {
                            audioTrackContent(track)
                        }
                    }
                }
            }

            // Subtitles
            if !result.subtitleTracks.isEmpty {
                CollapsibleTrackPicker(
                    title: "Subtitles",
                    systemImage: "captions.bubble",
                    trackCount: result.subtitleTracks.count,
                    isExpanded: $subtitleExpanded
                ) {
                    if let id = selectedSubtitleID, let track = result.subtitleTracks.first(where: { $0.id == id }) {
                        let compat = CompatibilityEngine.check(subtitle: track, capabilities: capabilities)
                        TrackSummaryRow(compatColor: compatColor(compat)) {
                            subtitleTrackContent(track)
                        }
                    } else {
                        Text("None").font(.caption).foregroundStyle(.secondary)
                    }
                } expanded: {
                    // "None" option
                    TrackRow(
                        isSelected: selectedSubtitleID == nil,
                        compatibility: .native
                    ) {
                        selectedSubtitleID = nil
                        subtitleExpanded = false
                    } content: {
                        Text("None").foregroundStyle(.secondary)
                    }

                    ForEach(result.subtitleTracks) { track in
                        let compat = CompatibilityEngine.check(subtitle: track, capabilities: capabilities)
                        TrackRow(
                            isSelected: selectedSubtitleID == track.id,
                            compatibility: compat
                        ) {
                            selectedSubtitleID = track.id
                            subtitleExpanded = false
                        } content: {
                            subtitleTrackContent(track)
                        }
                    }
                }
            }

            // HLS variants
            if !result.hlsVariants.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Quality Tiers", systemImage: "list.bullet")
                        .font(.subheadline.bold())
                    ForEach(Array(result.hlsVariants.enumerated()), id: \.offset) { _, variant in
                        hlsVariantRow(variant)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Media Header

    @ViewBuilder
    private var mediaHeaderSection: some View {
        if result.title != nil || result.coverArt != nil {
            HStack(alignment: .top, spacing: 12) {
                if let coverData = result.coverArt,
                   let uiImage = UIImage(data: coverData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 80, maxHeight: 120)
                        .cornerRadius(6)
                        .shadow(radius: 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let title = result.title {
                        Text(title)
                            .font(.headline)
                            .lineLimit(3)
                    }
                    if let dur = result.duration {
                        Text(formatDuration(dur))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Asset Info

    private var assetInfoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.title != nil && result.coverArt == nil {
                Text(result.title!).font(.headline)
            }
            HStack(spacing: 16) {
                Text(result.container.rawValue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(result.container.isNativelySupported ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .cornerRadius(4)

                if result.coverArt == nil, let dur = result.duration {
                    Text(formatDuration(dur))
                }

                Text("\(result.videoTracks.count)V \(result.audioTracks.count)A \(result.subtitleTracks.count)S")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    // MARK: - Track Content

    private func videoTrackContent(_ track: VideoTrackInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(track.codec.rawValue).bold()
                Text(track.resolutionLabel)
                Text("\(String(format: "%.1f", track.frameRate))fps")
            }
            HStack(spacing: 8) {
                if let depth = track.bitDepth { Text("\(depth)-bit") }
                if track.isDolbyVision { Text("Dolby Vision").foregroundStyle(.purple) }
                if track.isHDR { Text("HDR").foregroundStyle(.orange) }
                if let rate = track.estimatedDataRate { Text(formatBitrate(rate)) }
                if let lang = track.language { Text(lang) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func audioTrackContent(_ track: AudioTrackInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(track.codec.rawValue).bold()
                Text(track.channelLayout ?? track.channelLabel)
                if let lang = track.language { Text(lang) }
            }
            HStack(spacing: 8) {
                if let sr = track.sampleRate { Text("\(Int(sr / 1000))kHz") }
                if let rate = track.estimatedDataRate { Text(formatBitrate(rate)) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func subtitleTrackContent(_ track: SubtitleTrackInfo) -> some View {
        HStack(spacing: 8) {
            Text(track.format.rawValue).bold()
            if let lang = track.language { Text(lang) }
            if track.isForced { Text("Forced").italic() }
        }
    }

    private func hlsVariantRow(_ variant: HLSVariant) -> some View {
        HStack(spacing: 8) {
            if let res = variant.resolution {
                Text("\(Int(res.width))x\(Int(res.height))")
            }
            if let rate = variant.peakBitRate {
                Text(formatBitrate(rate))
            }
        }
        .font(.caption)
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func compatColor(_ compat: TrackCompatibility) -> Color {
        Formatting.compatColor(compat)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        Formatting.duration(seconds)
    }

    private func formatBitrate(_ bps: Double) -> String {
        Formatting.bitrate(bps)
    }
}

// MARK: - Collapsible Track Picker

struct CollapsibleTrackPicker<Summary: View, Expanded: View>: View {
    let title: String
    let systemImage: String
    let trackCount: Int
    @Binding var isExpanded: Bool
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let expanded: () -> Expanded

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — tap to toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Label(title, systemImage: systemImage)
                        .font(.subheadline.bold())

                    if trackCount > 1 {
                        Text("(\(trackCount))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)

            if isExpanded {
                // All tracks in a scrollable area (cap height for many tracks)
                let needsScroll = trackCount > 6
                if needsScroll {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            expanded()
                        }
                    }
                    .frame(maxHeight: 280)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        expanded()
                    }
                }
            } else {
                // Collapsed: show selected track summary
                summary()
                    .padding(.leading, 20)
            }
        }
    }
}

// MARK: - Track Summary Row (collapsed state)

struct TrackSummaryRow<Content: View>: View {
    let compatColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(compatColor)
                .frame(width: 8, height: 8)
            content()
                .font(.caption)
        }
    }
}

// MARK: - Track Row (expanded state)

struct TrackRow<Content: View>: View {
    let isSelected: Bool
    let compatibility: TrackCompatibility
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)

                Circle()
                    .fill(compatColor)
                    .frame(width: 8, height: 8)

                content()
                    .font(.caption)

                Spacer()

                if !compatibility.isGreen {
                    Text(compatibility.label)
                        .font(.caption2)
                        .foregroundStyle(compatColor)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var compatColor: Color {
        Formatting.compatColor(compatibility)
    }
}
