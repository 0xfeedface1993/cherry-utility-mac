import Dispatch
import Foundation
import Logging
import MCP

/// stdio 上按行分隔的 MCP 传输，替代 swift-sdk 的 `StdioTransport`。
///
/// swift-sdk 的实现把标准输入输出设成非阻塞，没有数据时每 10 ms 睡一次再读：`cherry mcp` 空闲时每秒醒来约 100 次，
/// 常驻约 1% CPU（Claude 开着就一直如此），每个请求还要多等最多 10 ms。而且这两个描述符与父进程（AI 客户端）共用，
/// 改成非阻塞也会影响对方。这里在一个专用线程上阻塞读标准输入：没有数据时线程睡在 `read` 里，不轮询、不改描述符的标志，
/// 也不占用协作线程池；写入在串行队列上阻塞写完。不用 `DispatchSource`：标准输入是命名管道（FIFO）时，写端关闭后
/// kqueue 不报可读，读不到 EOF，进程就不会退出。消息格式与 swift-sdk 相同：一行一条 JSON，空行忽略，EOF 时结束消息流。
actor MCPStdioTransport: Transport {
    nonisolated let logger: Logger
    private let input: Int32
    private let output: Int32
    /// 读取回调和写入都在各自的串行队列上执行。
    /// 写入在串行队列上执行，按调用顺序写出。
    private let writeQueue = DispatchQueue(label: "online.odeployer.cherry.mcp.stdout")
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var reader: Thread?

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, logger: Logger? = nil) {
        self.input = input
        self.output = output
        self.logger = logger ?? Logger(label: "online.odeployer.cherry.mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
        (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    func connect() async throws {
        guard reader == nil else { return }
        let lines = LineReader(descriptor: input, continuation: continuation)
        let thread = Thread { lines.run() }
        thread.name = "online.odeployer.cherry.mcp.stdin"
        reader = thread
        thread.start()
    }

    func disconnect() async {
        // 结束消息流；读线程在下一次 read 返回（数据或 EOF）时退出，或随进程结束。标准输入输出属于父进程，不关闭。
        continuation.finish()
        reader = nil
    }

    func send(_ message: Data) async throws {
        var framed = message
        framed.append(UInt8(ascii: "\n"))
        let line = framed
        let descriptor = output
        let failure: Int32? = await withCheckedContinuation { finished in
            writeQueue.async { finished.resume(returning: Self.writeAll(line, to: descriptor)) }
        }
        if let failure {
            throw MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO))
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { stream }

    /// 阻塞写完整段数据；返回失败时的 errno。
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { buffer -> Int32? in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return written < 0 ? errno : EIO
                }
            }
            return nil
        }
    }
}

/// 在专用线程上阻塞读取、切分输入行，交给消息流。
private final class LineReader: Sendable {
    private let descriptor: Int32
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(descriptor: Int32, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.descriptor = descriptor
        self.continuation = continuation
    }

    func run() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                continuation.finish(throwing: MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
                return
            }
            if count == 0 {
                continuation.finish()
                return
            }
            pending.append(contentsOf: buffer[..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                if !line.isEmpty, case .terminated = continuation.yield(Data(line)) { return }
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
    }
}
