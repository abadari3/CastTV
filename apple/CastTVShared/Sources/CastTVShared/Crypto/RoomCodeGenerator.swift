import Foundation

public enum RoomCodeGenerator {

    /// Generate a random room code.
    public static func generate(length: Int = CastTVConstants.roomCodeLength) -> String {
        let chars = Array(CastTVConstants.roomCodeCharacters)
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    /// Generate a room code, checking availability with the server.
    /// Retries up to `maxAttempts` times if the room already has an Apple TV connected.
    public static func generateAvailable(maxAttempts: Int = 5) async throws -> String {
        for _ in 0..<maxAttempts {
            let code = generate()
            let status = try await RoomStatus.check(
                serverBaseURL: CastTVConstants.serverBaseURL,
                roomCode: code
            )
            if !status.appleTvConnected {
                return code
            }
        }
        // Last resort — just return one (collision is extremely unlikely with 6 chars from 32 symbols)
        return generate()
    }
}
