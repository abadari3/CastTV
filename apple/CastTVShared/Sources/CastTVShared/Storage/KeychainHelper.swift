import Foundation
import Security
import CryptoKit

/// Simple Keychain wrapper for storing encryption keys.
public enum KeychainHelper {

    private static let service = "com.casttv.keys"

    /// Save an encryption key for a room code.
    public static func saveKey(_ key: SymmetricKey, forRoom roomCode: String) throws {
        let keyData = Encryption.exportKey(key)

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomCode,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomCode,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load an encryption key for a room code.
    public static func loadKey(forRoom roomCode: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomCode,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return Encryption.importKey(data)
    }

    /// Delete an encryption key for a room code.
    public static func deleteKey(forRoom roomCode: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: roomCode,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: Error {
        case saveFailed(OSStatus)
    }
}
