import CastTVShared
import SwiftUI

struct LogViewerView: View {
    let device: PairedDevice
    @ObservedObject var appState: iOSAppState
    @State private var logs: [LogMessage] = []
    @State private var historyLogs: [LogMessage] = []
    @State private var filterLevel: LogLevel?
    @State private var isConnected = false
    @State private var webSocket: WebSocketClient?

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar + actions
            HStack {
                filterButton(nil, label: "All")
                filterButton(.info, label: "Info")
                filterButton(.warning, label: "Warn")
                filterButton(.error, label: "Error")

                Spacer()

                Button {
                    copyLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .disabled(allFilteredLogs.isEmpty)

                Button {
                    clearLogs()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .disabled(logs.isEmpty && historyLogs.isEmpty)

                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(isConnected ? "Live" : "Disconnected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // All logs in a single scrollable area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Previous session
                        if !filteredHistory.isEmpty {
                            Text("Previous Session")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .padding(.top, 8)

                            ForEach(Array(filteredHistory.enumerated()), id: \.offset) { _, log in
                                logRow(log)
                            }
                        }

                        // Current session
                        if !filteredLogs.isEmpty {
                            if !filteredHistory.isEmpty {
                                Text("Current Session")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                            }

                            ForEach(Array(filteredLogs.enumerated()), id: \.offset) { index, log in
                                logRow(log)
                                    .id("live-\(index)")
                            }
                        }

                        if allFilteredLogs.isEmpty {
                            ContentUnavailableView(
                                "No Logs",
                                systemImage: "doc.text",
                                description: Text(filterLevel != nil ? "No logs at this level" : "Logs will appear here when the TV sends them")
                            )
                            .padding(.top, 40)
                        }
                    }
                }
                .onChange(of: logs.count) { _, _ in
                    if let last = filteredLogs.indices.last {
                        proxy.scrollTo("live-\(last)", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { connect() }
        .onDisappear { disconnect() }
    }

    // MARK: - Computed

    private var filteredLogs: [LogMessage] {
        guard let level = filterLevel else { return logs }
        return logs.filter { $0.level == level }
    }

    private var filteredHistory: [LogMessage] {
        guard let level = filterLevel else { return historyLogs }
        return historyLogs.filter { $0.level == level }
    }

    private var allFilteredLogs: [LogMessage] {
        filteredHistory + filteredLogs
    }

    // MARK: - Actions

    private func copyLogs() {
        let allLogs = allFilteredLogs
        let text = allLogs.map { log in
            "[\(log.level.rawValue.uppercased())] \(formatTime(log.timestamp)) \(log.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
    }

    private func clearLogs() {
        logs.removeAll()
        historyLogs.removeAll()
        // Tell the Apple TV to clear its logs too
        Task {
            try? await webSocket?.send(.clearLogs)
        }
    }

    // MARK: - Views

    @ViewBuilder
    private func logRow(_ log: LogMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            levelIcon(log.level)
                .frame(width: 14)

            Text(formatTime(log.timestamp))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            Text(log.message)
                .font(.caption2)
                .foregroundStyle(log.level == .error ? .red : log.level == .warning ? .orange : .primary)
        }
        .padding(.horizontal)
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func levelIcon(_ level: LogLevel) -> some View {
        switch level {
        case .info:
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .warning:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.circle")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func filterButton(_ level: LogLevel?, label: String) -> some View {
        Button {
            filterLevel = level
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(filterLevel == level ? Color.blue.opacity(0.2) : Color(.secondarySystemBackground))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - WebSocket

    private func connect() {
        guard let key = appState.encryptionKey(for: device) else { return }

        let config = WebSocketClient.Configuration(
            serverBaseURL: CastTVConstants.serverBaseURL,
            roomCode: device.roomCode,
            role: "iphone",
            encryptionKey: key
        )

        let ws = WebSocketClient(configuration: config)
        self.webSocket = ws
        ws.connect()

        Task {
            for await state in ws.states {
                isConnected = (state == .connected)
            }
        }

        Task {
            for await message in ws.messages {
                switch message {
                case .log(let logMsg):
                    logs.append(logMsg)
                case .logsHistory(let history):
                    historyLogs = history.entries
                default:
                    break
                }
            }
        }
    }

    private func disconnect() {
        webSocket?.disconnect()
        webSocket = nil
    }

    private func formatTime(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm:ss"
            return tf.string(from: date)
        }
        return timestamp.suffix(8).description
    }
}
