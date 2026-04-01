import SwiftUI
import CryptoKit
import CastTVShared
import os

private let logger = Logger(subsystem: "com.casttv.ios", category: "AppState")

@MainActor
final class iOSAppState: ObservableObject {
    @Published var pairedDevices: [PairedDevice] = []
    @Published var onlineStatus: [String: Bool] = [:] // roomCode -> isOnline
    @Published var isCheckingStatus: Bool = false
    @Published var showScanner: Bool = false
    @Published var isPairing: Bool = false
    @Published var pairingError: String?

    private let storage = PairingStorage.shared
    private var webSocket: WebSocketClient?

    init() {
        loadDevices()
    }

    func loadDevices() {
        pairedDevices = storage.loadDevices()
    }

    // MARK: - Online Status

    func checkAllStatus() async {
        isCheckingStatus = true
        let devices = pairedDevices

        await withTaskGroup(of: (String, Bool).self) { group in
            for device in devices {
                group.addTask {
                    do {
                        let status = try await RoomStatus.check(
                            serverBaseURL: CastTVConstants.serverBaseURL,
                            roomCode: device.roomCode
                        )
                        return (device.roomCode, status.appleTvConnected)
                    } catch {
                        return (device.roomCode, false)
                    }
                }
            }

            for await (roomCode, isOnline) in group {
                onlineStatus[roomCode] = isOnline
            }
        }

        isCheckingStatus = false
    }

    func isOnline(_ device: PairedDevice) -> Bool {
        onlineStatus[device.roomCode] ?? false
    }

    // MARK: - Pairing

    func startScanning() {
        showScanner = true
        pairingError = nil
    }

    func handleScannedQR(_ string: String) {
        showScanner = false

        guard let qrData = QRCodeData.decode(from: string) else {
            pairingError = "Invalid QR code"
            return
        }

        isPairing = true
        pairingError = nil

        let config = WebSocketClient.Configuration(
            serverBaseURL: CastTVConstants.serverBaseURL,
            roomCode: qrData.roomCode,
            role: "iphone",
            encryptionKey: qrData.encryptionKey
        )

        let ws = WebSocketClient(configuration: config)
        self.webSocket = ws
        ws.connect()

        Task {
            for await message in ws.messages {
                switch message {
                case .capabilities(let caps):
                    let device = PairedDevice(
                        roomCode: qrData.roomCode,
                        name: caps.name,
                        model: caps.model,
                        tvOS: caps.tvOS,
                        capabilities: caps
                    )
                    do {
                        try storage.saveDevice(device, encryptionKey: qrData.encryptionKey)
                        self.loadDevices()
                        self.isPairing = false
                        ws.disconnect()
                        self.webSocket = nil
                        // Refresh status
                        await self.checkAllStatus()
                    } catch {
                        self.pairingError = "Failed to save pairing: \(error.localizedDescription)"
                        self.isPairing = false
                    }
                    return
                default:
                    break
                }
            }

            if self.isPairing {
                self.pairingError = "Connection lost before receiving TV capabilities"
                self.isPairing = false
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(30))
            if self.isPairing {
                self.pairingError = "Pairing timed out — make sure the CastTV app is open on your TV"
                self.isPairing = false
                ws.disconnect()
                self.webSocket = nil
            }
        }
    }

    // MARK: - Key Access

    func encryptionKey(for device: PairedDevice) -> CryptoKit.SymmetricKey? {
        storage.encryptionKey(forRoom: device.roomCode)
    }

    // MARK: - Device Management

    func removeDevice(at offsets: IndexSet) {
        for index in offsets {
            let device = pairedDevices[index]
            storage.removeDevice(roomCode: device.roomCode)
            onlineStatus.removeValue(forKey: device.roomCode)
        }
        loadDevices()
    }

    func removeDevice(roomCode: String) {
        storage.removeDevice(roomCode: roomCode)
        onlineStatus.removeValue(forKey: roomCode)
        loadDevices()
    }

    func renameDevice(roomCode: String, newName: String) {
        storage.renameDevice(roomCode: roomCode, newName: newName)
        loadDevices()
    }

    #if targetEnvironment(simulator)
    /// Debug: send a play command to the first paired device.
    func debugCastURL(_ urlString: String) {
        guard let device = pairedDevices.first else {
            logger.error("debugCastURL: no paired devices")
            return
        }
        guard let key = encryptionKey(for: device) else {
            logger.error("debugCastURL: no encryption key")
            return
        }

        let playMsg = PlayMessage(
            url: urlString,
            subtitleUrl: nil,
            tracks: TrackSelection(video: nil, audio: nil, subtitle: nil)
        )

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
                logger.notice("debugCastURL: play command sent for \(urlString)")
            } catch {
                logger.error("debugCastURL: send failed: \(error)")
            }

            // Listen for errors briefly
            Task {
                for await message in ws.messages {
                    if case .error(let err) = message {
                        logger.error("debugCastURL: error from TV: \(err.message)")
                        break
                    }
                }
            }

            try? await Task.sleep(for: .seconds(5))
            ws.disconnect()
        }
    }
    #endif
}
