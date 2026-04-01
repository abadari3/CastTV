import SwiftUI
import CastTVShared

struct HistoryCard: View {
    let entry: URLHistoryEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Cover art or placeholder
                Group {
                    if let coverData = entry.coverArt, let uiImage = UIImage(data: coverData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color(.tertiarySystemBackground)
                            Image(systemName: "play.rectangle")
                                .font(.title3)
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
                .frame(width: 60, height: 40)
                .cornerRadius(6)
                .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    if let title = entry.title {
                        Text(title)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    Text(entry.url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.url
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
        }
        .padding(.horizontal)
    }
}
