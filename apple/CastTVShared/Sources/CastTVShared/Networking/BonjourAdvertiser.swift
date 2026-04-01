import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.casttv.shared", category: "BonjourAdvertiser")

/// Advertises this TV on the local network via Bonjour so iPhones can discover it.
///
/// Publishes a `_casttv._tcp` service with the room code and device name in TXT records.
/// The encryption key is NOT broadcast — it must be exchanged via QR code for security.
/// Bonjour enables auto-reconnect for already-paired devices and discovery of new TVs.
public final class BonjourAdvertiser: @unchecked Sendable {

    public static let serviceType = "_casttv._tcp"

    private let lock = NSLock()
    private var _listener: NWListener?

    public init() {}

    deinit {
        stop()
    }

    /// Start advertising the given room code on the local network.
    /// Only the room code and device name are broadcast — the encryption key
    /// is never sent over mDNS to avoid passive interception on shared networks.
    public func start(roomCode: String, deviceName: String) {
        stop()

        do {
            let listener = try NWListener(using: .tcp)

            // Encode discovery data in TXT record (no encryption key!)
            let txtRecord = NWTXTRecord([
                "room": roomCode,
                "name": deviceName
            ])
            listener.service = NWListener.Service(
                name: "CastTV-\(roomCode)",
                type: Self.serviceType,
                txtRecord: txtRecord
            )

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    logger.notice("Bonjour advertising started for room \(roomCode)")
                case .failed(let error):
                    logger.error("Bonjour advertising failed: \(error)")
                case .cancelled:
                    logger.notice("Bonjour advertising stopped")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                // We don't actually accept TCP connections through Bonjour.
                // Discovery-only: iPhones read the TXT record and connect via the WebSocket relay.
                connection.cancel()
            }

            // Store under lock BEFORE starting to avoid race with stop()
            lock.withLock { _listener = listener }

            listener.start(queue: .global(qos: .utility))
            logger.notice("Bonjour advertiser configured for room \(roomCode)")

        } catch {
            logger.error("Failed to create Bonjour listener: \(error)")
        }
    }

    /// Stop advertising.
    public func stop() {
        let listener = lock.withLock {
            let l = _listener
            _listener = nil
            return l
        }
        listener?.cancel()
    }
}
