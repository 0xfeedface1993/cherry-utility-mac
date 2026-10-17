import Foundation
import Logging
import MCP

/// 包在 MCP 传输外：输入结束（标准输入 EOF）后，等已收到请求的响应都发出去，最多 `drainLimit`，再结束消息流。
///
/// swift-sdk 在各自的 Task 里处理请求，`Server.waitUntilCompleted()` 只等消息循环。客户端写完请求就关闭标准输入时
/// （管道调用、客户端快速退出），不等的话进程在工具调用完成前就退出，响应丢失。
/// 只跟踪带 `id` 的请求与对应的响应；客户端取消（`notifications/cancelled`）的请求 SDK 不再回应，随即不再等待。
///
/// 另外直接回绝缺少工具名的 `tools/call`：SDK 把参数解码失败一律报成 -32603 内部错误，并附上系统本地化的解码说明。
actor DrainingTransport: Transport {
    nonisolated let logger: Logger
    private let inner: any Transport
    private let drainLimit: Duration
    private var inFlight: Set<String> = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pump: Task<Void, Never>?
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(_ inner: any Transport, logger: Logger, drainLimit: Duration = .seconds(25)) {
        self.inner = inner
        self.logger = logger
        self.drainLimit = drainLimit
        (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    var pendingRequests: Int { inFlight.count }

    func connect() async throws {
        try await inner.connect()
        let messages = await inner.receive()
        pump = Task { await self.forward(messages) }
    }

    func disconnect() async {
        pump?.cancel()
        pump = nil
        continuation.finish()
        resumeDrainWaiters()
        await inner.disconnect()
    }

    func send(_ data: Data) async throws {
        try await inner.send(data)
        settle(Self.messages(in: data).compactMap(Self.responseID))
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { stream }

    private func forward(_ messages: AsyncThrowingStream<Data, any Error>) async {
        do {
            for try await data in messages {
                if let rejection = Self.rejection(for: data) {
                    try? await inner.send(rejection)
                    continue
                }
                let decoded = Self.messages(in: data)
                inFlight.formUnion(decoded.compactMap(Self.requestID))
                settle(decoded.compactMap(Self.cancelledID))
                continuation.yield(data)
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }
        await waitForResponses()
        continuation.finish()
    }

    private func waitForResponses() async {
        guard !inFlight.isEmpty, !Task.isCancelled else { return }
        let limit = drainLimit
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.resumeDrainWaiters()
        }
        await withCheckedContinuation { drainWaiters.append($0) }
        timer.cancel()
    }

    private func settle(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        inFlight.subtract(ids)
        if inFlight.isEmpty { resumeDrainWaiters() }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// 单条 `tools/call` 的 `params.name` 不是字符串时的 -32602 响应（批量请求仍交给 SDK）。
    static func rejection(for data: Data) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "tools/call", let id = message["id"], key(id) != nil,
              (message["params"] as? [String: Any])?["name"] as? String == nil else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": -32602, "message": "Invalid params: tools/call 缺少工具名 name"],
        ]
        return try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - JSON-RPC 分类（单条或批量）

    private static func messages(in data: Data) -> [[String: Any]] {
        switch try? JSONSerialization.jsonObject(with: data) {
        case let object as [String: Any]: [object]
        case let batch as [Any]: batch.compactMap { $0 as? [String: Any] }
        default: []
        }
    }

    /// 请求：有 `method` 和 `id`（通知没有 `id`）。
    private static func requestID(_ message: [String: Any]) -> String? {
        guard message["method"] != nil else { return nil }
        return key(message["id"])
    }

    /// 响应：有 `id`、没有 `method`。
    private static func responseID(_ message: [String: Any]) -> String? {
        guard message["method"] == nil else { return nil }
        return key(message["id"])
    }

    private static func cancelledID(_ message: [String: Any]) -> String? {
        guard message["method"] as? String == "notifications/cancelled", let params = message["params"] as? [String: Any] else { return nil }
        return key(params["requestId"])
    }

    private static func key(_ id: Any?) -> String? {
        switch id {
        case let text as String: "s:" + text
        case let number as NSNumber: "n:" + number.stringValue
        default: nil
        }
    }
}
