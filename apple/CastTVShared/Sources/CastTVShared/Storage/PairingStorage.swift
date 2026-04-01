import Foundation
import CryptoKit

/// Persisted info about a paired TV (stored in UserDefaults).
public struct PairedDevice: Codable, Identifiable, Hashable, Sendable {
    public var id: String { roomCode }
    public let roomCode: String
    public var name: String
    public let model: String?
    public let tvOS: String?
    public let capabilities: CapabilitiesMessage?
    public let pairedAt: Date

    public init(roomCode: String, name: String, model: String? = nil, tvOS: String? = nil, capabilities: CapabilitiesMessage? = nil, pairedAt: Date = Date()) {
        self.roomCode = roomCode
        self.name = name
        self.model = model
        self.tvOS = tvOS
        self.capabilities = capabilities
        self.pairedAt = pairedAt
    }
}

/// Manages paired device persistence (UserDefaults + Keychain).
public final class PairingStorage: @unchecked Sendable {

    private let defaults: UserDefaults
    private let key = "com.casttv.paired_devices"

    public static let shared = PairingStorage()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// All saved paired devices.
    public func loadDevices() -> [PairedDevice] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    /// Save a paired device (updates if room code already exists).
    public func saveDevice(_ device: PairedDevice, encryptionKey: SymmetricKey) throws {
        var devices = loadDevices()
        devices.removeAll { $0.roomCode == device.roomCode }
        devices.append(device)

        let data = try JSONEncoder().encode(devices)
        defaults.set(data, forKey: key)

        try KeychainHelper.saveKey(encryptionKey, forRoom: device.roomCode)
    }

    /// Remove a paired device.
    public func removeDevice(roomCode: String) {
        var devices = loadDevices()
        devices.removeAll { $0.roomCode == roomCode }

        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: key)
        }

        KeychainHelper.deleteKey(forRoom: roomCode)
    }

    /// Update the name of a paired device.
    public func renameDevice(roomCode: String, newName: String) {
        var devices = loadDevices()
        if let index = devices.firstIndex(where: { $0.roomCode == roomCode }) {
            devices[index] = PairedDevice(
                roomCode: devices[index].roomCode,
                name: newName,
                model: devices[index].model,
                tvOS: devices[index].tvOS,
                capabilities: devices[index].capabilities,
                pairedAt: devices[index].pairedAt
            )
            if let data = try? JSONEncoder().encode(devices) {
                defaults.set(data, forKey: key)
            }
        }
    }

    /// Get the encryption key for a paired device.
    public func encryptionKey(forRoom roomCode: String) -> SymmetricKey? {
        KeychainHelper.loadKey(forRoom: roomCode)
    }

    // MARK: - TV side: own room code

    private let ownRoomCodeKey = "com.casttv.own_room_code"

    /// Save this TV's own room code.
    public func saveOwnRoomCode(_ code: String) {
        defaults.set(code, forKey: ownRoomCodeKey)
    }

    /// Load this TV's own room code.
    public func loadOwnRoomCode() -> String? {
        defaults.string(forKey: ownRoomCodeKey)
    }
}
