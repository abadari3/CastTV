import SwiftUI
import CryptoKit
import CastTVShared
import os

private let logger = Logger(subsystem: "com.casttv.tvos", category: "AppState")

@MainActor
final class TVAppState: ObservableObject {
    @Published var roomCode: String = ""
    @Published var qrString: String = "" // full casttv:... for manual pairing
    @Published var qrCodeImage: UIImage?
    @Published var isPaired: Bool = false
    @Published var pairingComplete: Bool = false
    @Published var connectedDeviceName: String?      // non-nil when iPhone is actively connected right now
    @Published var hasEverPaired: Bool = false        // true once any iPhone has paired
    @Published var isConnecting: Bool = false
    @Published var errorMessage: String?

    // Playback state
    @Published var isPlaying: Bool = false
    @Published var currentURL: String?
    @Published var playbackError: String?

    /// Set by the PlayerView when it's ready to receive play commands.
    var onPlayRequest: ((PlayMessage) -> Void)?

    private var encryptionKey: SymmetricKey?
    private var webSocket: WebSocketClient?
    private let storage = PairingStorage.shared
    private let bonjourAdvertiser = BonjourAdvertiser()

    init() {
        if let savedCode = storage.loadOwnRoomCode(),
           let savedKey = storage.encryptionKey(forRoom: savedCode) {
            roomCode = savedCode
            encryptionKey = savedKey
            isPaired = true
            pairingComplete = true
            hasEverPaired = true

            // Regenerate QR code for display
            let qrData = QRCodeData(roomCode: savedCode, encryptionKey: savedKey)
            let encoded = qrData.encode()
            qrString = encoded
            qrCodeImage = qrData.generateImage()

            CastTVLogger.shared.info("Restored pairing: room \(savedCode)")
            startBonjourAdvertising()
            connectToRoom()
        } else {
            CastTVLogger.shared.info("No saved pairing, will show QR")
        }
    }

    func startPairing() {
        isConnecting = true
        errorMessage = nil
        CastTVLogger.shared.info("Starting pairing...")

        Task {
            do {
                // Try availability check, fall back to simple generation if network fails
                let code: String
                do {
                    code = try await RoomCodeGenerator.generateAvailable()
                } catch {
                    logger.info("[CastTV] Room availability check failed: \(error), using random code")
                    code = RoomCodeGenerator.generate()
                }
                let key = Encryption.generateKey()

                self.roomCode = code
                self.encryptionKey = key

                let qrData = QRCodeData(roomCode: code, encryptionKey: key)
                let qrString = qrData.encode()
                self.qrString = qrString
                logger.notice("[CastTV] QR pairing string: \(qrString)")
                self.qrCodeImage = qrData.generateImage()

                storage.saveOwnRoomCode(code)
                try storage.saveDevice(
                    PairedDevice(roomCode: code, name: "This Apple TV"),
                    encryptionKey: key
                )

                logger.notice("[CastTV] Room code: \(code), connecting...")
                CastTVLogger.shared.info("Room \(code) created, connecting...")
                self.startBonjourAdvertising()
                connectToRoom()
                self.isConnecting = false
            } catch {
                logger.error("[CastTV] Pairing error: \(error)")
                CastTVLogger.shared.error("Pairing failed: \(error.localizedDescription)")
                self.errorMessage = "Failed to set up pairing: \(error.localizedDescription)"
                self.isConnecting = false
            }
        }
    }

    func connectToRoom() {
        guard let key = encryptionKey, !roomCode.isEmpty else { return }

        let config = WebSocketClient.Configuration(
            serverBaseURL: CastTVConstants.serverBaseURL,
            roomCode: roomCode,
            role: "appletv",
            encryptionKey: key
        )

        let ws = WebSocketClient(configuration: config)
        self.webSocket = ws
        ws.connect()

        CastTVLogger.shared.info("WebSocket connecting to room \(roomCode)")

        // Stream logs to iPhone via WebSocket
        CastTVLogger.shared.onNewEntry = { [weak ws] logMsg in
            Task {
                try? await ws?.send(.log(logMsg))
            }
        }

        Task {
            for await message in ws.messages {
                await handleMessage(message)
            }
        }

        Task {
            for await state in ws.states {
                switch state {
                case .connected:
                    CastTVLogger.shared.info("WebSocket connected")
                    await sendCapabilities()
                case .disconnected:
                    CastTVLogger.shared.warning("WebSocket disconnected")
                case .connecting:
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: CastMessage) {
        switch message {
        case .play(let playMsg):
            CastTVLogger.shared.info("Received play command: \(playMsg.url)")
            playbackError = nil
            currentURL = playMsg.url
            isPlaying = true
            onPlayRequest?(playMsg)

        case .clearLogs:
            CastTVLogger.shared.clearAll()
            CastTVLogger.shared.info("Logs cleared by iPhone")

        case .deviceJoined(let presence) where presence.role == "iphone":
            CastTVLogger.shared.info("iPhone connected")
            connectedDeviceName = "iPhone"
            isPaired = true
            pairingComplete = true
            hasEverPaired = true
            Task {
                await sendCapabilities()
                await sendLogsHistory()
            }

        case .deviceLeft(let presence) where presence.role == "iphone":
            CastTVLogger.shared.info("iPhone disconnected")
            connectedDeviceName = nil

        default:
            break
        }
    }

    private func sendCapabilities() async {
        let caps = CapabilityDetector.detect()
        CastTVLogger.shared.info("Sending capabilities: \(caps.model) \(caps.display.resolution)")
        let message = CastMessage.capabilities(caps)
        do {
            try await webSocket?.send(message)
        } catch {
            CastTVLogger.shared.error("Failed to send capabilities: \(error)")
        }
    }

    private func sendLogsHistory() async {
        let previousEntries = CastTVLogger.shared.previousSessionEntries()
        let logMessages = previousEntries.map {
            LogMessage(timestamp: $0.timestamp, level: $0.level, message: $0.message)
        }
        if !logMessages.isEmpty {
            let history = LogsHistoryMessage(session: CastTVLogger.shared.sessionStart, entries: logMessages)
            try? await webSocket?.send(.logsHistory(history))
        }
    }

    /// Send a playback error back to the iPhone.
    func reportError(code: String, message: String) {
        CastTVLogger.shared.error("Playback error [\(code)]: \(message)")
        playbackError = message
        let errMsg = CastMessage.error(ErrorMessage(code: code, message: message))
        Task {
            try? await webSocket?.send(errMsg)
        }
    }

    func stopPlayback() {
        isPlaying = false
        currentURL = nil
    }

    private func startBonjourAdvertising() {
        guard !roomCode.isEmpty else { return }
        #if os(tvOS)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = "Apple TV"
        #endif
        bonjourAdvertiser.start(roomCode: roomCode, deviceName: deviceName)
    }

    func resetPairing() {
        bonjourAdvertiser.stop()
        webSocket?.disconnect()
        webSocket = nil

        if !roomCode.isEmpty {
            storage.removeDevice(roomCode: roomCode)
        }

        roomCode = ""
        encryptionKey = nil
        qrCodeImage = nil
        isPaired = false
        pairingComplete = false
        connectedDeviceName = nil
        isPlaying = false
        currentURL = nil
    }

}
