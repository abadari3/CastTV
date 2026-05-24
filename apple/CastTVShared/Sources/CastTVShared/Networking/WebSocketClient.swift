import CryptoKit
import Foundation
import os

private let wsLogger = Logger(subsystem: "com.casttv.shared", category: "WebSocket")

/// WebSocket client for communicating with the CastTV relay server.
///
/// Handles connection, encrypted send/receive, and auto-reconnect.
public final class WebSocketClient: NSObject, @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
    }

    public struct Configuration: Sendable {
        public let serverBaseURL: String
        public let roomCode: String
        public let role: String // "appletv", "androidtv", or "iphone"
        public let encryptionKey: SymmetricKey

        public init(serverBaseURL: String, roomCode: String, role: String, encryptionKey: SymmetricKey) {
            self.serverBaseURL = serverBaseURL
            self.roomCode = roomCode
            self.role = role
            self.encryptionKey = encryptionKey
        }
    }

    private let configuration: Configuration
    private let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation
    private let messageStream: AsyncStream<CastMessage>
    private let messageContinuation: AsyncStream<CastMessage>.Continuation

    // Mutable state protected by lock
    private let lock = NSLock()
    private var _state: State = .disconnected
    private var _task: URLSessionWebSocketTask?
    private var _session: URLSession?
    private var _shouldReconnect: Bool = false

    public var state: State {
        lock.withLock { _state }
    }

    /// Stream of connection state changes.
    public var states: AsyncStream<State> { stateStream }

    /// Stream of decrypted incoming messages.
    public var messages: AsyncStream<CastMessage> { messageStream }

    public init(configuration: Configuration) {
        self.configuration = configuration
        var sc: AsyncStream<State>.Continuation!
        self.stateStream = AsyncStream { sc = $0 }
        self.stateContinuation = sc
        var mc: AsyncStream<CastMessage>.Continuation!
        self.messageStream = AsyncStream { mc = $0 }
        self.messageContinuation = mc
        super.init()
    }

    deinit {
        stateContinuation.finish()
        messageContinuation.finish()
    }

    /// Connect to the WebSocket relay.
    public func connect() {
        lock.lock()
        guard _state == .disconnected else {
            lock.unlock()
            return
        }
        _state = .connecting
        _shouldReconnect = true
        lock.unlock()
        stateContinuation.yield(.connecting)

        let wsURL = configuration.serverBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let urlString = "\(wsURL)/room/\(configuration.roomCode)/ws?role=\(configuration.role)"
        guard let url = URL(string: urlString) else { return }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)

        lock.lock()
        let oldSession = _session
        _session = session
        _task = task
        lock.unlock()

        oldSession?.invalidateAndCancel()

        task.resume()
        wsLogger.notice("WebSocket task resumed for \(urlString)")
        // State transitions to .connected in urlSession(_:webSocketTask:didOpenWithProtocol:)
        // startReceiving() is also called there after the handshake completes
    }

    /// Disconnect from the WebSocket relay.
    public func disconnect() {
        lock.lock()
        _shouldReconnect = false
        let task = _task
        let session = _session
        _task = nil
        _session = nil
        _state = .disconnected
        lock.unlock()
        stateContinuation.yield(.disconnected)

        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Send an encrypted message.
    public func send(_ message: CastMessage) async throws {
        let plaintext = try message.encode()
        let encrypted = try Encryption.encrypt(plaintext, key: configuration.encryptionKey)
        let base64 = encrypted.base64EncodedString()

        let task = lock.withLock { _task }
        guard let task else {
            wsLogger.error("Send failed: not connected")
            throw WebSocketError.notConnected
        }
        wsLogger.notice("Sending message (\(base64.count) chars)")
        try await task.send(.string(base64))
        wsLogger.notice("Message sent successfully")
    }

    /// Send raw encrypted JSON data.
    public func sendRaw(_ data: Data) async throws {
        let encrypted = try Encryption.encrypt(data, key: configuration.encryptionKey)
        let base64 = encrypted.base64EncodedString()

        let task = lock.withLock { _task }
        guard let task else { throw WebSocketError.notConnected }
        try await task.send(.string(base64))
    }

    // MARK: - Private

    private func startReceiving() {
        let task = lock.withLock { _task }
        guard let task else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let wsMessage):
                switch wsMessage {
                case .string(let text):
                    wsLogger.notice("Received string (\(text.prefix(100))...)")
                case .data(let data):
                    wsLogger.notice("Received data (\(data.count) bytes)")
                @unknown default:
                    wsLogger.notice("Received unknown message type")
                }
                self.handleMessage(wsMessage)
                self.startReceiving() // continue listening

            case .failure(let error):
                wsLogger.error("Receive failed: \(error)")
                self.handleDisconnect()
            }
        }
    }

    private func handleMessage(_ wsMessage: URLSessionWebSocketTask.Message) {
        switch wsMessage {
        case .string(let text):
            // Try to decrypt (encrypted message from peer)
            if let encryptedData = Data(base64Encoded: text),
               let plaintext = try? Encryption.decrypt(encryptedData, key: configuration.encryptionKey) {
                let message = CastMessage.decode(from: plaintext)
                messageContinuation.yield(message)
            } else {
                // Unencrypted system message (device_joined, device_left from the DO)
                if let data = text.data(using: .utf8) {
                    let message = CastMessage.decode(from: data)
                    messageContinuation.yield(message)
                }
            }

        case .data(let data):
            if let plaintext = try? Encryption.decrypt(data, key: configuration.encryptionKey) {
                let message = CastMessage.decode(from: plaintext)
                messageContinuation.yield(message)
            }

        @unknown default:
            break
        }
    }

    private func handleDisconnect() {
        wsLogger.notice("handleDisconnect called, will reconnect: \(self.lock.withLock { self._shouldReconnect })")
        lock.lock()
        let shouldReconnect = _shouldReconnect
        _task = nil
        _state = .disconnected
        lock.unlock()
        stateContinuation.yield(.disconnected)

        if shouldReconnect {
            // Reconnect after a short delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let currentState = self.lock.withLock { self._state }
                let wantsReconnect = self.lock.withLock { self._shouldReconnect }
                if currentState == .disconnected && wantsReconnect {
                    self.connect()
                }
            }
        }
    }

    public enum WebSocketError: Error {
        case notConnected
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketClient: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        wsLogger.notice("WebSocket didOpen (protocol: \(`protocol` ?? "nil"))")
        lock.lock()
        _state = .connected
        lock.unlock()
        stateContinuation.yield(.connected)
        startReceiving()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        wsLogger.notice("WebSocket didClose (code: \(closeCode.rawValue))")
        handleDisconnect()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            wsLogger.error("URLSession task completed with error: \(error)")
            handleDisconnect()
        }
    }
}
