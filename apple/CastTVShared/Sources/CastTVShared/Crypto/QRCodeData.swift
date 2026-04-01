import Foundation
import CryptoKit
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif

/// Encodes/decodes QR code payload containing room code and encryption key.
///
/// Format: `casttv:<roomCode>:<base64url-encoded key>`
public struct QRCodeData: Sendable {
    public let roomCode: String
    public let encryptionKey: SymmetricKey

    public init(roomCode: String, encryptionKey: SymmetricKey) {
        self.roomCode = roomCode
        self.encryptionKey = encryptionKey
    }

    /// Encode to a string suitable for QR code generation.
    public func encode() -> String {
        let keyData = Encryption.exportKey(encryptionKey)
        let keyString = keyData.base64URLEncoded()
        return "casttv:\(roomCode):\(keyString)"
    }

    /// Decode from a scanned QR code string.
    public static func decode(from string: String) -> QRCodeData? {
        let parts = string.split(separator: ":", maxSplits: 2)
        guard parts.count == 3,
              parts[0] == "casttv",
              !parts[1].isEmpty,
              !parts[2].isEmpty else {
            return nil
        }

        let roomCode = String(parts[1])
        guard let keyData = Data(base64URLEncoded: String(parts[2])) else {
            return nil
        }
        guard keyData.count == 32 else { return nil } // AES-256 = 32 bytes

        let key = Encryption.importKey(keyData)
        return QRCodeData(roomCode: roomCode, encryptionKey: key)
    }

    #if canImport(UIKit)
    /// Generate a UIImage of the QR code for this pairing data.
    public func generateImage(scale: CGFloat = 10) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(encode().utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}

// MARK: - Base64URL (URL-safe, no padding)

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
