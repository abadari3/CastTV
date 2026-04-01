import Foundation

/// HTTP status check for a room (no WebSocket needed).
public enum RoomStatus {
    /// Check if a TV is connected to a room.
    public static func check(serverBaseURL: String, roomCode: String) async throws -> StatusResponse {
        let urlString = "\(serverBaseURL)/room/\(roomCode)/status"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }
}

public struct StatusResponse: Codable, Sendable {
    public let appleTvConnected: Bool
    public let iphoneConnected: Bool
    public let connectionCount: Int
}
