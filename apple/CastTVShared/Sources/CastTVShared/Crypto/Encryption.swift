import Foundation
import CryptoKit

/// AES-GCM encryption/decryption for end-to-end encrypted messaging.
public enum Encryption {

    /// Generate a new AES-256 key.
    public static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Export key as raw bytes.
    public static func exportKey(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// Import key from raw bytes.
    public static func importKey(_ data: Data) -> SymmetricKey {
        SymmetricKey(data: data)
    }

    /// Encrypt plaintext data with AES-GCM.
    /// Returns: nonce (12 bytes) + ciphertext + tag (16 bytes).
    public static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw EncryptionError.sealFailed
        }
        return combined
    }

    /// Decrypt data encrypted with `encrypt`.
    public static func decrypt(_ combined: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key)
    }

    public enum EncryptionError: Error {
        case sealFailed
    }
}
