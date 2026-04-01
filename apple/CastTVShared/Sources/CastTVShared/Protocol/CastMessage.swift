import Foundation

/// Simple command message (no payload beyond the action).
public struct CommandMessage: Codable, Sendable {
    public let action: String

    public init(action: String) {
        self.action = action
    }
}

/// System message sent by the Durable Object when a device connects or disconnects.
public struct DevicePresenceMessage: Codable, Sendable {
    public let type: String // "device_joined" or "device_left"
    public let role: String // "appletv", "androidtv", or "iphone"
    public let timestamp: String
}

/// Wrapper for routing messages by type before full decoding.
public enum CastMessage: Sendable {
    case play(PlayMessage)
    case capabilities(CapabilitiesMessage)
    case error(ErrorMessage)
    case log(LogMessage)
    case logsHistory(LogsHistoryMessage)
    case clearLogs
    case deviceJoined(DevicePresenceMessage)
    case deviceLeft(DevicePresenceMessage)
    case unknown(Data)
}

extension CastMessage {
    /// Decode a JSON payload into the appropriate message type.
    public static func decode(from data: Data) -> CastMessage {
        // Peek at "type" or "action" to determine message kind
        struct Peek: Decodable {
            let type: String?
            let action: String?
        }

        guard let peek = try? JSONDecoder().decode(Peek.self, from: data) else {
            return .unknown(data)
        }

        let decoder = JSONDecoder()

        if let action = peek.action {
            if action == "play" {
                if let msg = try? decoder.decode(PlayMessage.self, from: data) {
                    return .play(msg)
                }
            } else if action == "clear_logs" {
                return .clearLogs
            }
        }

        switch peek.type {
        case "capabilities":
            if let msg = try? decoder.decode(CapabilitiesMessage.self, from: data) {
                return .capabilities(msg)
            }
        case "error":
            if let msg = try? decoder.decode(ErrorMessage.self, from: data) {
                return .error(msg)
            }
        case "log":
            if let msg = try? decoder.decode(LogMessage.self, from: data) {
                return .log(msg)
            }
        case "logs_history":
            if let msg = try? decoder.decode(LogsHistoryMessage.self, from: data) {
                return .logsHistory(msg)
            }
        case "device_joined":
            if let msg = try? decoder.decode(DevicePresenceMessage.self, from: data) {
                return .deviceJoined(msg)
            }
        case "device_left":
            if let msg = try? decoder.decode(DevicePresenceMessage.self, from: data) {
                return .deviceLeft(msg)
            }
        default:
            break
        }

        return .unknown(data)
    }

    /// Encode this message to JSON data.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case .play(let msg): return try encoder.encode(msg)
        case .capabilities(let msg): return try encoder.encode(msg)
        case .error(let msg): return try encoder.encode(msg)
        case .log(let msg): return try encoder.encode(msg)
        case .logsHistory(let msg): return try encoder.encode(msg)
        case .clearLogs: return try encoder.encode(CommandMessage(action: "clear_logs"))
        case .deviceJoined(let msg): return try encoder.encode(msg)
        case .deviceLeft(let msg): return try encoder.encode(msg)
        case .unknown(let data): return data
        }
    }
}
