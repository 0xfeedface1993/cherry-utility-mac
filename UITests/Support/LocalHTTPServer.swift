import Foundation
import Network

/// Minimal loopback HTTP/1.1 server for the update tests: Sparkle only fetches feeds over http(s), and the app reaches
/// `http://127.0.0.1:<port>/` without App Transport Security exceptions. Serves the files of one directory, GET only.
/// The runner needs `com.apple.security.network.server` (UITests/CherryUtilityUITests.entitlements) to listen.
final class LocalHTTPServer: @unchecked Sendable { // listener state is only touched on `queue`
    private let root: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cherry.uitest.http")

    init(serving root: URL) throws {
        self.root = root
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the base URL (`http://127.0.0.1:<port>/`).
    func start(timeout: TimeInterval = 5) throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        let failure = LockedBox<NWError?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure.value = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success, failure.value == nil, let port = listener.port else {
            throw failure.value ?? URLError(.cannotConnectToHost)
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let path = parts.count > 1 ? String(parts[1]).split(separator: "?").first.map(String.init) ?? "/" : "/"
        let name = path.removingPercentEncoding.map { String($0.drop(while: { $0 == "/" })) } ?? ""
        let file = root.appendingPathComponent(name)
        let body: Data?
        if parts.first == "GET", !name.isEmpty, !name.contains(".."), file.path.hasPrefix(root.path) {
            body = try? Data(contentsOf: file)
        } else {
            body = nil
        }
        let status = body == nil ? "404 Not Found" : "200 OK"
        let type = name.hasSuffix(".xml") ? "application/xml; charset=utf-8" : "application/octet-stream"
        let payload = body ?? Data()
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Tiny lock-protected box for values set from the listener's queue.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
