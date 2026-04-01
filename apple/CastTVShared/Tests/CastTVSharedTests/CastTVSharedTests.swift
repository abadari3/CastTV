import XCTest
import Foundation
import CryptoKit
@testable import CastTVShared

final class CastTVSharedTests: XCTestCase {

    func testPlayMessageRoundTrip() throws {
        let play = PlayMessage(url: "https://example.com/video.mp4", subtitleUrl: "https://example.com/subs.vtt", tracks: TrackSelection(video: 0, audio: 1, subtitle: 2))
        let data = try JSONEncoder().encode(play)
        let decoded = try JSONDecoder().decode(PlayMessage.self, from: data)
        XCTAssertEqual(decoded.action, "play")
        XCTAssertEqual(decoded.url, "https://example.com/video.mp4")
        XCTAssertEqual(decoded.subtitleUrl, "https://example.com/subs.vtt")
        XCTAssertEqual(decoded.tracks?.video, 0)
    }

    func testCastMessageDecodePlay() {
        let json = """
        {"action":"play","url":"https://example.com/video.mp4"}
        """.data(using: .utf8)!
        let msg = CastMessage.decode(from: json)
        guard case .play(let play) = msg else {
            XCTFail("Expected play message")
            return
        }
        XCTAssertEqual(play.url, "https://example.com/video.mp4")
    }

    func testCastMessageDecodeCapabilities() {
        let json = """
        {"type":"capabilities","model":"AppleTV6,2","tvOS":"17.4","name":"Living Room","display":{"resolution":"3840x2160","availableModes":["3840x2160"],"maxRefreshRate":60,"displayGamut":"P3","hdrModes":["hdr10"]},"audio":{"maxChannels":8,"outputType":"HDMI","atmosSupported":true,"spatialAudioEnabled":false}}
        """.data(using: .utf8)!
        let msg = CastMessage.decode(from: json)
        guard case .capabilities(let caps) = msg else {
            XCTFail("Expected capabilities message")
            return
        }
        XCTAssertEqual(caps.model, "AppleTV6,2")
        XCTAssertEqual(caps.display.hdrModes, ["hdr10"])
    }

    func testCastMessageDecodeError() {
        let json = """
        {"type":"error","code":"playback_failed","message":"HTTP 404"}
        """.data(using: .utf8)!
        let msg = CastMessage.decode(from: json)
        guard case .error(let err) = msg else {
            XCTFail("Expected error message")
            return
        }
        XCTAssertEqual(err.code, "playback_failed")
    }

    func testEncryptionRoundTrip() throws {
        let key = Encryption.generateKey()
        let plaintext = "Hello, CastTV!".data(using: .utf8)!
        let encrypted = try Encryption.encrypt(plaintext, key: key)
        let decrypted = try Encryption.decrypt(encrypted, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptionKeyExportImport() throws {
        let key = Encryption.generateKey()
        let exported = Encryption.exportKey(key)
        XCTAssertEqual(exported.count, 32)
        let imported = Encryption.importKey(exported)
        let plaintext = "test".data(using: .utf8)!
        let encrypted = try Encryption.encrypt(plaintext, key: key)
        let decrypted = try Encryption.decrypt(encrypted, key: imported)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testQRCodeDataRoundTrip() {
        let key = Encryption.generateKey()
        let original = QRCodeData(roomCode: "A7X2", encryptionKey: key)
        let encoded = original.encode()
        XCTAssert(encoded.hasPrefix("casttv:A7X2:"))

        let decoded = QRCodeData.decode(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.roomCode, "A7X2")

        let originalKeyData = Encryption.exportKey(key)
        let decodedKeyData = Encryption.exportKey(decoded!.encryptionKey)
        XCTAssertEqual(originalKeyData, decodedKeyData)
    }

    func testQRCodeDataInvalid() {
        XCTAssertNil(QRCodeData.decode(from: "garbage"))
        XCTAssertNil(QRCodeData.decode(from: "casttv::"))
        XCTAssertNil(QRCodeData.decode(from: "wrong:A7X2:abc"))
    }
}
