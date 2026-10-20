import Darwin
import Dispatch
import Foundation
import Synchronization

/// App 端的控制 socket：只接受同一用户的连接，按行读取请求，交给 `handler`，响应写回同一连接。
///
/// 执行模型：
/// - 文件描述符只在各自的串行 DispatchQueue 上读写，阻塞的系统调用不进入 Swift 并发的协作线程池；
/// - 连接表用 `Mutex` 保护，锁内只增删，回调与关闭都在锁外；
/// - 每个连接一个 worker Task（连接持有、关闭时取消），按顺序处理请求；`watch` 会一直占用这个 worker；
/// - 请求行进入有界缓冲（32 行），积压或单行超过 64 KiB 就断开连接，慢客户端不会让 App 无限缓冲。
public final class ControlSocketServer: Sendable {
    public typealias Reply = @Sendable (ControlResponse) -> Void
    public typealias Handler = @Sendable (ControlRequest, @escaping Reply) async -> Void

    public enum StartError: Error, Equatable, Sendable {
        /// 另一个 App 实例已在这个路径上应答。
        case alreadyRunning
        /// 路径上已有一个不是 socket 的文件（例如 `CHERRY_CONTROL_SOCKET` 指错了）；不删除它。
        case pathOccupied
        case pathTooLong
        case system(operation: String, code: Int32)
    }

    private struct State {
        var started = false
        var acceptSource: (any DispatchSourceRead)?
        var connections: [ObjectIdentifier: ControlConnection] = [:]
    }

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "online.odeployer.CherryUtility.control.accept")
    private let state = Mutex(State())

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var connectionCount: Int { state.withLock { $0.connections.count } }

    public func start() throws(StartError) {
        guard UnixSocket.fits(path) else { throw .pathTooLong }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else { throw .pathOccupied }
            // 上次异常退出留下的 socket 文件没人应答，可以删除；有人应答说明 App 已在运行。
            if Self.answers(path) { throw .alreadyRunning }
            unlink(path)
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fd: Int32
        do { fd = try UnixSocket.make() } catch { throw .system(operation: error.operation, code: error.code) }
        func fail(_ operation: String) -> StartError {
            let code = errno
            Darwin.close(fd)
            return .system(operation: operation, code: code)
        }
        guard UnixSocket.withAddress(path, { Darwin.bind(fd, $0, $1) }) == 0 else { throw fail("bind") }
        // 只有本用户能连接（连接 Unix socket 需要对文件的写权限）；接受时还会核对对端 uid。
        guard chmod(path, 0o600) == 0 else { throw fail("chmod") }
        guard listen(fd, 16) == 0 else { throw fail("listen") }
        UnixSocket.setNonBlocking(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        state.withLock {
            $0.started = true
            $0.acceptSource = source
        }
        source.resume()
    }

    /// 关闭监听与所有连接，删除 socket 文件。
    public func stop() {
        let (source, connections, wasStarted) = state.withLock { state in
            let snapshot = (state.acceptSource, Array(state.connections.values), state.started)
            state = State()
            return snapshot
        }
        source?.cancel()
        for connection in connections { connection.close() }
        if wasStarted { unlink(path) }
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard Self.isSameUser(fd) else {
                Darwin.close(fd)
                continue
            }
            UnixSocket.configure(fd)
            UnixSocket.setNonBlocking(fd)
            let connection = ControlConnection(fd: fd, handler: handler) { [weak self] id in
                let removed = self?.state.withLock { $0.connections.removeValue(forKey: id) }
                _ = removed // 在锁外释放
            }
            let accepted = state.withLock { state -> Bool in
                guard state.started else { return false }
                state.connections[ObjectIdentifier(connection)] = connection
                return true
            }
            if accepted { connection.start() } else { Darwin.close(fd) }
        }
    }

    static func isSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    static func answers(_ path: String) -> Bool {
        guard let client = try? ControlClient.connect(path: path, timeout: .seconds(1)) else { return false }
        return (try? client.call(.ping))?.ok == true
    }
}

/// 一个客户端连接。`fd`、`source`、`buffer`、`closed`、`worker` 只在 `queue` 上访问。
final class ControlConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "online.odeployer.CherryUtility.control.connection")
    private let handler: ControlSocketServer.Handler
    private let onClose: @Sendable (ObjectIdentifier) -> Void
    private let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var source: (any DispatchSourceRead)?
    private var buffer = LineBuffer()
    private var closed = false
    private var worker: Task<Void, Never>?

    init(fd: Int32, handler: @escaping ControlSocketServer.Handler, onClose: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.fd = fd
        self.handler = handler
        self.onClose = onClose
        (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(32))
    }

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            self.source = source
            let lines = lines
            worker = Task { [self] in
                for await line in lines {
                    guard !Task.isCancelled else { break }
                    await process(line)
                }
            }
            source.resume()
        }
    }

    func send(_ response: ControlResponse) {
        guard let data = try? ControlCoding.line(response) else { return }
        queue.async { [self] in
            guard !closed else { return }
            if !UnixSocket.writeAll(fd, data) { closeOnQueue() }
        }
    }

    func close() {
        queue.async { [self] in closeOnQueue() }
    }

    private func process(_ line: Data) async {
        let request: ControlRequest
        do {
            request = try ControlCoding.decode(ControlRequest.self, from: line)
        } catch {
            send(.failure(ControlCoding.requestID(in: line) ?? 0, ControlFailure(code: "invalidRequest", message: "请求格式不正确")))
            return
        }
        guard request.v == ControlProtocol.version else {
            send(.failure(request.id, ControlFailure(code: "unsupportedVersion", message: "不支持协议版本 \(request.v)，App 使用版本 \(ControlProtocol.version)")))
            return
        }
        await handler(request) { [weak self] response in self?.send(response) }
    }

    private func readAvailable() {
        guard !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                let received: [Data]
                do {
                    received = try buffer.append(Data(chunk[0..<count]))
                } catch {
                    // 先说明原因再断开，客户端不会把它误判成 App 退出。
                    let limit = ControlProtocol.maxLineLength / 1024
                    reject(ControlFailure(code: "invalidRequest", message: "请求超过 \(limit) KiB 的上限"))
                    return closeOnQueue()
                }
                for line in received {
                    if case .dropped = continuation.yield(line) { return closeOnQueue() }
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                return closeOnQueue()
            }
        }
    }

    /// 在 `queue` 上直接写一条失败响应（随后关闭连接，不经过 worker）。
    private func reject(_ failure: ControlFailure) {
        guard !closed, let data = try? ControlCoding.line(ControlResponse.failure(0, failure)) else { return }
        _ = UnixSocket.writeAll(fd, data)
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        continuation.finish()
        worker?.cancel()
        if let source {
            source.cancel() // 取消处理里关闭 fd
        } else {
            Darwin.close(fd)
        }
        source = nil
        onClose(ObjectIdentifier(self))
    }
}
