import SwiftUI
import CastTVShared

struct DeviceRow: View {
    let device: PairedDevice
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isOnline ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            Image(systemName: device.capabilities?.isAndroidTV == true ? "tv.and.hifispeaker.fill" : "appletv.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    if let caps = device.capabilities {
                        Text(caps.display.resolution)
                        if !caps.display.hdrModes.isEmpty {
                            Text(caps.display.hdrModes.map { DisplayCapabilities.hdrLabel($0) }.joined(separator: " "))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
