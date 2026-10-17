import Darwin
import Foundation
import Synchronization
import Testing
@testable import CherryControl

/// 阻塞的客户端调用放到 GCD 线程上，不占用 Swift 并发的协作线程（服务端处理请求要用它们）。
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
    }
}

/// 最多等 2 秒直到条件成立；条件在锁内只读取，等待在锁外。
func eventually(_ condition: @Sendable () -> Bool) async throws -> Bool {
    for _ in 0..<200 {
        try Task.checkCancellation()
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// 每个用例一个短路径目录（`sun_path` 只有 104 字节；`$TMPDIR` 会被定期清理，不用它）。
struct SocketDirectory: ~Copyable {
    let url: URL
    init() {
        url = URL(fileURLWithPath: "/tmp/cherry-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var socket: String { url.appending(path: "c.sock").path(percentEncoded: false) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("控制协议：编码与分行")
struct ControlCodingTests {
    @Test func requestsAndResponsesRoundTripAsSingleLines() throws {
        let request = ControlRequest(id: 7, method: .update, params: ControlParams(profile: 2, effect: "呼吸\n换行", brightness: 3, color: "#FF7200"))
        let line = try ControlCoding.line(request)
        #expect(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil)
        #expect(try ControlCoding.decode(ControlRequest.self, from: line.dropLast()) == request)
        let response = ControlResponse.failure(7, ControlFailure(code: "noKeyboard", message: "没有连接受支持的 CHERRY 键盘"))
        #expect(try ControlCoding.decode(ControlResponse.self, from: ControlCoding.line(response)) == response)
        let text = String(decoding: try ControlCoding.line(request), as: UTF8.self)
        #expect(text.contains("\"v\":1") && text.contains("\"method\":\"update\""))
    }

    @Test func malformedRequestsStillYieldTheirID() {
        #expect(ControlCoding.requestID(in: Data(#"{"v":1,"id":42,"method":"fly"}"#.utf8)) == 42)
        #expect(ControlCoding.requestID(in: Data("not json".utf8)) == nil)
        #expect(throws: ControlCodingError.malformed) { try ControlCoding.decode(ControlRequest.self, from: Data(#"{"v":1,"id":1,"method":"fly"}"#.utf8)) }
    }

    @Test func lineBufferSplitsAcrossChunksAndEnforcesTheLimit() throws {
        var buffer = LineBuffer(limit: 8)
        #expect(try buffer.append(Data("ab".utf8)).isEmpty)
        #expect(try buffer.append(Data("c\n\nde\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        #expect(try buffer.append(Data("\n".utf8)) == [Data("f".utf8)])
        #expect(throws: ControlCodingError.lineTooLong) { try buffer.append(Data("123456789".utf8)) }
    }

    @Test func socketPathHonoursTheEnvironment() {
        #expect(ControlProtocol.socketPath(environment: ["CHERRY_CONTROL_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(ControlProtocol.socketPath(environment: ["CHERRY_CONTROL_SOCKET": ""]) == ControlProtocol.defaultSocketPath)
        #expect(ControlProtocol.defaultSocketPath.hasSuffix("/Library/Application Support/CherryUtility/control.sock"))
    }
}

@Suite("控制协议：socket 传输", .serialized)
struct ControlTransportTests {
    /// 回显方法名；`watch` 一直等到连接关闭（worker 被取消）。
    final class Probe: Sendable {
        let watchEnded = Mutex(false)
        var hasEndedWatch: Bool { watchEnded.withLock { $0 } }
        var handler: ControlSocketServer.Handler {
            { [self] request, reply in
                if request.method == .watch {
                    reply(.success(request.id, ControlResult(message: "watching")))
                    // 模拟长时间运行的 watch：只在连接关闭、worker 被取消时结束。
                    try? await Task.sleep(for: .seconds(3600))
                    watchEnded.withLock { $0 = true }
                    return
                }
                reply(.success(request.id, ControlResult(message: "\(request.method.rawValue):\(request.params?.profile ?? 0)")))
            }
        }
    }

    @Test func clientCallsAreAnsweredInOrderOnOneConnection() async throws {
        let directory = SocketDirectory()
        let server = ControlSocketServer(path: directory.socket, handler: Probe().handler)
        try server.start()
        defer { server.stop() }
        let path = directory.socket
        let messages = try await blocking {
            let client = try ControlClient.connect(path: path)
            return try (1...3).map { try client.call(.status, ControlParams(profile: $0)).result?.message }
        }
        #expect(messages == ["status:1", "status:2", "status:3"])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func malformedAndForeignVersionRequestsGetErrors() async throws {
        let directory = SocketDirectory()
        let server = ControlSocketServer(path: directory.socket, handler: Probe().handler)
        try server.start()
        defer { server.stop() }
        let path = directory.socket
        let lines = try await blocking { () -> [String] in
            let fd = try UnixSocket.make()
            defer { close(fd) }
            guard UnixSocket.withAddress(path, { connect(fd, $0, $1) }) == 0 else { throw ControlClientError.unavailable }
            UnixSocket.setTimeout(fd, option: SO_RCVTIMEO, .seconds(5))
            _ = UnixSocket.writeAll(fd, Data(#"{"v":1,"id":5,"method":"fly"}"# .utf8 + [0x0A]))
            _ = UnixSocket.writeAll(fd, Data(#"{"v":9,"id":6,"method":"ping"}"#.utf8 + [0x0A]))
            var buffer = LineBuffer()
            var lines: [Data] = []
            while lines.count < 2 {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                lines += try buffer.append(Data(chunk[0..<count]))
            }
            return lines.map { String(decoding: $0, as: UTF8.self) }
        }
        let responses = try lines.map { try ControlCoding.decode(ControlResponse.self, from: Data($0.utf8)) }
        #expect(responses.map(\.id) == [5, 6])
        #expect(responses.map { $0.error?.code } == ["invalidRequest", "unsupportedVersion"])
    }

    @Test func secondServerOnTheSamePathRefusesAndStaleSocketsAreReplaced() async throws {
        let directory = SocketDirectory()
        let first = ControlSocketServer(path: directory.socket, handler: Probe().handler)
        try first.start()
        let second = ControlSocketServer(path: directory.socket, handler: Probe().handler)
        #expect(throws: ControlSocketServer.StartError.alreadyRunning) { try second.start() }
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.socket))
        let path = directory.socket
        await #expect(throws: ControlClientError.unavailable) { try await blocking { _ = try ControlClient.connect(path: path) } }

        // 异常退出留下的 socket 文件：没人应答，新实例删除后照常监听。
        let stale = try UnixSocket.make()
        #expect(UnixSocket.withAddress(path, { bind(stale, $0, $1) }) == 0)
        close(stale)
        try second.start()
        defer { second.stop() }
        #expect(try await blocking { try ControlClient.connect(path: path).call(.ping).ok })
    }

    @Test func overlongPathsAreRejected() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: ControlSocketServer.StartError.pathTooLong) { try ControlSocketServer(path: path, handler: Probe().handler).start() }
        #expect(throws: ControlClientError.pathTooLong(path)) { try ControlClient.connect(path: path) }
    }

    @Test func closingTheClientCancelsALongRunningWatch() async throws {
        let directory = SocketDirectory()
        let probe = Probe()
        let server = ControlSocketServer(path: directory.socket, handler: probe.handler)
        try server.start()
        defer { server.stop() }
        let path = directory.socket
        let ack = try await blocking { () -> String? in
            let client = try ControlClient.connect(path: path)
            try client.send(.watch)
            return try client.receive().result?.message // 客户端随后释放，连接关闭
        }
        #expect(ack == "watching")
        #expect(try await eventually { probe.hasEndedWatch })
        #expect(try await eventually { server.connectionCount == 0 })
    }

    @Test func overlongLinesGetAnErrorBeforeTheConnectionCloses() async throws {
        let directory = SocketDirectory()
        let server = ControlSocketServer(path: directory.socket, handler: Probe().handler)
        try server.start()
        defer { server.stop() }
        let path = directory.socket
        let (reply, closed) = try await blocking { () -> (ControlResponse?, Bool) in
            let fd = try UnixSocket.make()
            defer { close(fd) }
            guard UnixSocket.withAddress(path, { connect(fd, $0, $1) }) == 0 else { throw ControlClientError.unavailable }
            UnixSocket.setTimeout(fd, option: SO_RCVTIMEO, .seconds(5))
            _ = UnixSocket.writeAll(fd, Data(repeating: 0x41, count: ControlProtocol.maxLineLength + 10))
            var buffer = LineBuffer()
            var lines: [Data] = []
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                lines += try buffer.append(Data(chunk[0..<count]))
            }
            return (try lines.first.map { try ControlCoding.decode(ControlResponse.self, from: $0) }, true)
        }
        #expect(reply?.ok == false && reply?.error?.code == "invalidRequest" && reply?.error?.message.contains("64 KiB") == true)
        #expect(closed)
    }

    /// 客户端在 `call` 里把服务端主动回的 id 0 失败当作这次调用的结果，而不是等到连接断开。
    @Test func clientSurfacesServerInitiatedFailures() async throws {
        let directory = SocketDirectory()
        let server = ControlSocketServer(path: directory.socket, handler: Probe().handler)
        try server.start()
        defer { server.stop() }
        let path = directory.socket
        let response = try await blocking { () -> ControlResponse in
            let client = try ControlClient.connect(path: path)
            return try client.call(.applyPreset, ControlParams(preset: String(repeating: "x", count: 70_000)))
        }
        #expect(response.error?.code == "invalidRequest")
    }

    @Test func aRegularFileAtTheSocketPathIsLeftAlone() throws {
        let directory = SocketDirectory()
        FileManager.default.createFile(atPath: directory.socket, contents: Data("keep".utf8))
        #expect(throws: ControlSocketServer.StartError.pathOccupied) {
            try ControlSocketServer(path: directory.socket, handler: Probe().handler).start()
        }
        #expect(FileManager.default.contents(atPath: directory.socket) == Data("keep".utf8))
        #expect(throws: ControlClientError.notASocket(directory.socket)) { try ControlClient.connect(path: directory.socket) }
    }
}

@Suite("控制协议：往返基准", .serialized)
struct ControlBenchmarkTests {
    /// 同一连接上 100 次请求往返的总耗时，供并发验证门读取（`BENCHMARK_CONTROL_ROUNDTRIP_MS`）。
    /// 处理器立即应答，测的是 socket、分行、编解码与 worker 调度本身。
    @Test func controlRoundTripBenchmark() async throws {
        let directory = SocketDirectory()
        let server = ControlSocketServer(path: directory.socket) { request, reply in reply(.success(request.id, ControlResult(message: "ok"))) }
        try server.start()
        defer { server.stop() }
        let path = directory.socket
        let elapsed = try await blocking { () -> Duration in
            let client = try ControlClient.connect(path: path)
            _ = try client.call(.ping)
            let clock = ContinuousClock()
            return try clock.measure {
                for _ in 0..<100 { _ = try client.call(.status, ControlParams(profile: 1)) }
            }
        }
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        print("BENCHMARK_CONTROL_ROUNDTRIP_MS=\(milliseconds)")
        #expect(milliseconds < 450)
    }
}
