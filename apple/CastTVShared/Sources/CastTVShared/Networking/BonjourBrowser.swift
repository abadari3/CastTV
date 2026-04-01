import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.casttv.shared", category: "BonjourBrowser")

/// A TV discovered on the local network via Bonjour.
public struct DiscoveredTV: Identifiable, Equatable, Hashable, Sendable {
    public let id: String // service name
    public let roomCode: String
    public let keyBase64URL: String
    public let deviceName: String

    public init(id: String, roomCode: String, keyBase64URL: String, deviceName: String) {
        self.id = id
        self.roomCode = roomCode
        self.keyBase64URL = keyBase64URL
        self.deviceName = deviceName
    }
}

/// Browses the local network for CastTV services advertised by TV apps.
///
/// Uses `NWBrowser` to discover `_casttv._tcp` Bonjour services and extracts
/// room code, encryption key, and device name from TXT records for quick-connect pairing.
public final class BonjourBrowser: @unchecked Sendable {

    private let lock = NSLock()
    private var _browser: NWBrowser?
    private var _discovered: [String: DiscoveredTV] = [:]

    private let discoveredStream: AsyncStream<[DiscoveredTV]>
    private let discoveredContinuation: AsyncStream<[DiscoveredTV]>.Continuation

    /// Stream of currently discovered TVs, updated as services appear/disappear.
    /// Note: `AsyncStream` supports only a single consumer. If multiple observers
    /// are needed, use `currentDiscoveries` for snapshot access instead.
    public var discoveries: AsyncStream<[DiscoveredTV]> { discoveredStream }

    /// Current snapshot of discovered TVs.
    public var currentDiscoveries: [DiscoveredTV] {
        lock.withLock { Array(_discovered.values) }
    }

    public init() {
        var cont: AsyncStream<[DiscoveredTV]>.Continuation!
        self.discoveredStream = AsyncStream { cont = $0 }
        self.discoveredContinuation = cont
    }

    deinit {
        stop()
        discoveredContinuation.finish()
    }

    /// Start browsing for CastTV services on the local network.
    public func start() {
        stop()

        let browser = NWBrowser(for: .bonjour(type: BonjourAdvertiser.serviceType, domain: nil), using: .tcp)

        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.notice("Bonjour browser started")
            case .failed(let error):
                logger.error("Bonjour browser failed: \(error)")
            case .cancelled:
                logger.notice("Bonjour browser stopped")
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            self.handleResults(results)
        }

        // Store under lock BEFORE starting to avoid race with stop()
        lock.withLock { _browser = browser }
        browser.start(queue: .global(qos: .utility))
    }

    /// Stop browsing.
    public func stop() {
        let browser = lock.withLock {
            let b = _browser
            _browser = nil
            return b
        }
        browser?.cancel()

        lock.withLock {
            _discovered.removeAll()
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var newDiscovered: [String: DiscoveredTV] = [:]

        for result in results {
            guard case .service(let name, let type, _, _) = result.endpoint else { continue }
            guard type == BonjourAdvertiser.serviceType else { continue }

            // Extract TXT record metadata
            if case .bonjour(let txtRecord) = result.metadata {
                guard let roomCode = txtRecord["room"],
                      let key = txtRecord["key"],
                      let deviceName = txtRecord["name"] else {
                    logger.warning("Bonjour service \(name) missing required TXT fields")
                    continue
                }

                let tv = DiscoveredTV(
                    id: name,
                    roomCode: roomCode,
                    keyBase64URL: key,
                    deviceName: deviceName
                )
                newDiscovered[name] = tv
            }
        }

        lock.withLock {
            _discovered = newDiscovered
        }
        let snapshot = Array(newDiscovered.values)

        logger.notice("Discovered \(snapshot.count) TV(s) on local network")
        discoveredContinuation.yield(snapshot)
    }
}
