import Darwin
import Foundation

public enum ControlClientError: Error, Equatable, Sendable {
    /// socket 不存在或没有进程在监听：App 没在运行。
    case unavailable
    case pathTooLong(String)
    case timeout
    /// App 关闭了连接（例如退出）。
    case disconnected
    case malformedResponse
    case system(operation: String, code: Int32)
}

/// 同步的控制协议客户端，供 CLI 使用：一个连接上依次发请求、读响应。不是线程安全的。
public final class ControlClient {
    private let fd: Int32
    private var buffer = LineBuffer()
    private var lines: [Data] = []
    private var nextID = 1

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    /// `timeout` 是每次读写的上限；`watch` 这类长连接传 nil。
    public static func connect(path: String, timeout: Duration? = .seconds(20)) throws(ControlClientError) -> ControlClient {
        guard UnixSocket.fits(path) else { throw .pathTooLong(path) }
        let fd: Int32
        do { fd = try UnixSocket.make() } catch { throw .system(operation: error.operation, code: error.code) }
        let rc = UnixSocket.withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard rc == 0 else {
            let code = errno
            Darwin.close(fd)
            throw [ENOENT, ECONNREFUSED].contains(code) ? .unavailable : .system(operation: "connect", code: code)
        }
        UnixSocket.setTimeout(fd, option: SO_RCVTIMEO, timeout)
        UnixSocket.setTimeout(fd, option: SO_SNDTIMEO, timeout)
        return ControlClient(fd: fd)
    }

    /// 发一个请求并等它的响应。
    public func call(_ method: ControlMethod, _ params: ControlParams? = nil) throws(ControlClientError) -> ControlResponse {
        let id = try send(method, params)
        while true {
            let response = try receive()
            if response.id == id { return response }
        }
    }

    /// 只发送，返回请求 ID；配合 `receive()` 读取推送（`watch`）。
    @discardableResult
    public func send(_ method: ControlMethod, _ params: ControlParams? = nil) throws(ControlClientError) -> Int {
        let id = nextID
        nextID += 1
        let line: Data
        do { line = try ControlCoding.line(ControlRequest(id: id, method: method, params: params)) } catch { throw .malformedResponse }
        guard UnixSocket.writeAll(fd, line) else { throw errno == EAGAIN ? .timeout : .disconnected }
        return id
    }

    public func receive() throws(ControlClientError) -> ControlResponse {
        while lines.isEmpty {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                do { lines += try buffer.append(Data(chunk[0..<count])) } catch { throw .malformedResponse }
            } else if count == 0 {
                throw .disconnected
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw .timeout
            } else {
                throw .system(operation: "read", code: errno)
            }
        }
        let line = lines.removeFirst()
        do { return try ControlCoding.decode(ControlResponse.self, from: line) } catch { throw .malformedResponse }
    }
}
