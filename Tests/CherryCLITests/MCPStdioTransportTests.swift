import Darwin
import Foundation
import Synchronization
import Testing
@testable import CherryCLI

/// `MCPStdioTransport` 用 pipe 代替标准输入输出：按行切分、EOF、写出与描述符标志。
@Suite("cherry mcp：事件驱动的 stdio 传输")
struct MCPStdioTransportTests {
    final class Pipes: Sendable {
        let input: (read: Int32, write: Int32)
        let output: (read: Int32, write: Int32)

        init() {
            var a: [Int32] = [0, 0], b: [Int32] = [0, 0]
            precondition(pipe(&a) == 0 && pipe(&b) == 0)
            input = (a[0], a[1])
            output = (b[0], b[1])
            open.withLock { $0 = [a[0], a[1], b[0], b[1]] }
        }

        func feed(_ text: String) {
            let bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(input.write, $0.baseAddress, $0.count) }
                precondition(written > 0)
                offset += written
            }
        }

        /// 每个描述符只关一次：测试并行运行，重复关闭可能关掉别的测试刚打开的同号描述符。
        private let open = Mutex<Set<Int32>>([])

        func closeInput() { closeOnce(input.write) }
        func closeOutputReader() { closeOnce(output.read) }

        private func closeOnce(_ descriptor: Int32) {
            if open.withLock({ $0.remove(descriptor) }) != nil { close(descriptor) }
        }

        deinit {
            open.withLock({ $0 }).forEach { close($0) }
        }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> [String] {
        var lines: [String] = []
        for try await data in stream {
            try Task.checkCancellation()
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines
    }

    @Test func splitsLinesAcrossWritesSkipsEmptyLinesAndEndsAtEOF() async throws {
        let pipes = Pipes()
        let transport = MCPStdioTransport(input: pipes.input.read, output: pipes.output.write)
        try await transport.connect()
        let stream = await transport.receive()
        let reading = Task { try await collect(stream) }
        pipes.feed("{\"a\":1}\n\n{\"b\"")
        try await Task.sleep(for: .milliseconds(50))
        pipes.feed(":2}\n{\"c\":3}\n")
        pipes.closeInput()
        #expect(try await reading.value == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
    }

    /// 标准输入是命名管道（FIFO）时也能读到 EOF：kqueue 对 FIFO 的写端关闭不报可读，早先用 DispatchSource 时进程挂住
    /// （端到端 MC-20 发现，2026-10-18）。
    @Test func endsAtEOFOnANamedPipe() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "cherry-fifo-\(UUID().uuidString)").path
        #expect(mkfifo(path, 0o600) == 0)
        defer { unlink(path) }
        // 先非阻塞地打开读端（否则要等写端出现），再打开写端，然后把读端改回阻塞，与 shell 的 `< fifo` 相同。
        let reader = open(path, O_RDONLY | O_NONBLOCK)
        let writer = open(path, O_WRONLY)
        #expect(reader >= 0 && writer >= 0)
        defer { close(reader) }
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) & ~O_NONBLOCK)
        var sink: [Int32] = [0, 0]
        #expect(pipe(&sink) == 0)
        defer { close(sink[0]); close(sink[1]) }
        let transport = MCPStdioTransport(input: reader, output: sink[1])
        try await transport.connect()
        let stream = await transport.receive()
        let reading = Task { try await collect(stream) }
        let line = Array("{\"id\":1}\n".utf8)
        _ = line.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        close(writer)
        #expect(try await reading.value == ["{\"id\":1}"])
    }

    @Test func deliversAOneMebibyteLineIntact() async throws {
        let pipes = Pipes()
        let transport = MCPStdioTransport(input: pipes.input.read, output: pipes.output.write)
        try await transport.connect()
        let stream = await transport.receive()
        let reading = Task { try await collect(stream) }
        let line = String(repeating: "x", count: 1 << 20)
        let writer = Thread { pipes.feed(line + "\n"); pipes.closeInput() }
        writer.start()
        let lines = try await reading.value
        #expect(lines.count == 1 && lines.first?.count == 1 << 20)
    }

    @Test func sendWritesOneLineAndLeavesDescriptorFlagsAlone() async throws {
        let pipes = Pipes()
        let before = (fcntl(pipes.input.read, F_GETFL), fcntl(pipes.output.write, F_GETFL))
        let transport = MCPStdioTransport(input: pipes.input.read, output: pipes.output.write)
        try await transport.connect()
        try await transport.send(Data("{\"id\":1}".utf8))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { read(pipes.output.read, $0.baseAddress, $0.count) }
        #expect(String(decoding: buffer[..<count], as: UTF8.self) == "{\"id\":1}\n")
        // 只看 O_NONBLOCK：F_GETFL 还带内核自己记的位（写过之后的 FWASWRITTEN，0x10000）。
        #expect(before.0 & O_NONBLOCK == 0 && before.1 & O_NONBLOCK == 0)
        #expect(fcntl(pipes.input.read, F_GETFL) & O_NONBLOCK == 0, "标准输入不应改成非阻塞")
        #expect(fcntl(pipes.output.write, F_GETFL) & O_NONBLOCK == 0, "标准输出不应改成非阻塞")
    }

    @Test func disconnectEndsTheStreamWithoutClosingInput() async throws {
        let pipes = Pipes()
        let transport = MCPStdioTransport(input: pipes.input.read, output: pipes.output.write)
        try await transport.connect()
        let stream = await transport.receive()
        let reading = Task { try await collect(stream) }
        pipes.feed("{\"a\":1}\n")
        try await Task.sleep(for: .milliseconds(50))
        await transport.disconnect()
        #expect(try await reading.value == ["{\"a\":1}"])
        #expect(fcntl(pipes.input.read, F_GETFD) != -1, "标准输入属于父进程，不应被关闭")
    }

    @Test func sendFailsWhenTheReaderIsGone() async throws {
        let pipes = Pipes()
        let transport = MCPStdioTransport(input: pipes.input.read, output: pipes.output.write)
        signal(SIGPIPE, SIG_IGN)
        pipes.closeOutputReader()
        await #expect(throws: (any Error).self) { try await transport.send(Data("{}".utf8)) }
    }
}
