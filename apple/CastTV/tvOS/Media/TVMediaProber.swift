import CastTVShared
import Foundation

/// Media prober for tvOS — delegates to shared AVProber.
enum TVMediaProber {
    static func probe(url: URL) async throws -> ProbeResult {
        let container = ContainerType.from(url: url)
        return try await AVProber.probe(url: url, container: container)
    }
}
