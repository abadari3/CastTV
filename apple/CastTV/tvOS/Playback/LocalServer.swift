import CastTVShared
import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.casttv.tvos", category: "LocalServer")

/// Minimal HTTP server using Network.framework.
/// Serves HLS playlists and segments from a local directory to AVPlayer.
final class LocalServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.casttv.localserver", qos: .userInitiated)
    private let connectionsLock = NSLock()
    private var connections: [NWConnection] = []
    private var _assignedPort: UInt16 = 0
    private let portSemaphore = DispatchSemaphore(value: 0)

    /// Handler called for each HTTP request. Returns (statusCode, contentType, body).
    var requestHandler: ((String) -> (Int, String, Data))?

    /// The base URL clients should use. Only valid after start() returns.
    var baseURL: String { "http://localhost:\(_assignedPort)" }

    /// The port the server is listening on. Only valid after start() returns.
    var port: UInt16 { _assignedPort }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
    }

    /// Start the server. Blocks briefly until the port is assigned.
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener.port {
                    self?._assignedPort = port.rawValue
                    logger.notice("Server listening on port \(port.rawValue)")
                    CastTVLogger.shared.info("HTTP server started on port \(port.rawValue)")
                    self?.portSemaphore.signal()
                }
            case .failed(let error):
                logger.error("Server failed: \(error)")
                CastTVLogger.shared.error("HTTP server failed: \(error)")
                self?.listener.cancel()
                self?.portSemaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)

        // Wait for port assignment (should be near-instant)
        _ = portSemaphore.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
        connectionsLock.lock()
        let conns = connections
        connections.removeAll()
        connectionsLock.unlock()
        for conn in conns {
            conn.cancel()
        }
        logger.notice("Server stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.append(connection)
        connectionsLock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let conn = connection {
                self?.removeConnection(conn)
            }
        }

        connection.start(queue: queue)
        receiveHTTPRequest(on: connection)
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        // Read up to 8KB for HTTP request headers
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.sendResponse(on: connection, status: 400, contentType: "text/plain", body: Data("Bad Request".utf8))
                return
            }

            // Parse HTTP request line: "GET /path HTTP/1.1"
            let lines = requestString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                self.sendResponse(on: connection, status: 400, contentType: "text/plain", body: Data("Bad Request".utf8))
                return
            }

            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendResponse(on: connection, status: 400, contentType: "text/plain", body: Data("Bad Request".utf8))
                return
            }

            let method = String(parts[0])
            let path = String(parts[1])

            logger.debug("Request: \(method) \(path)")

            if method != "GET" {
                self.sendResponse(on: connection, status: 405, contentType: "text/plain", body: Data("Method Not Allowed".utf8))
                return
            }

            // Dispatch to handler
            if let handler = self.requestHandler {
                let (status, contentType, body) = handler(path)
                if status != 200 {
                    CastTVLogger.shared.warning("HTTP \(status) \(path)")
                }
                self.sendResponse(on: connection, status: status, contentType: contentType, body: body)
            } else {
                CastTVLogger.shared.warning("HTTP 404 \(path) (no handler)")
                self.sendResponse(on: connection, status: 404, contentType: "text/plain", body: Data("Not Found".utf8))
            }
        }
    }

    private func sendResponse(on connection: NWConnection, status: Int, contentType: String, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 400: statusText = "Bad Request"
        case 405: statusText = "Method Not Allowed"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Unknown"
        }

        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Cache-Control: no-cache\r\n"
        response += "Connection: keep-alive\r\n"
        response += "\r\n"

        var responseData = Data(response.utf8)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error {
                logger.error("Send error: \(error)")
                connection.cancel()
                self?.removeConnection(connection)
                return
            }
            // Keep connection alive — listen for the next request
            self?.receiveHTTPRequest(on: connection)
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeAll { $0 === connection }
        connectionsLock.unlock()
    }
}
