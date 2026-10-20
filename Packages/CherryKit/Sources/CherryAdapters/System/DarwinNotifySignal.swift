import CherryCore
import Dispatch
import Foundation
import notify

/// Cross-process signals over Darwin notifications (`notify_post`). They carry no content: the receiver reads the shared
/// state again. Before posting, the sender stores its pid as the name's state so that a process skips its own posts.
///
/// `namespace` separates independent setups (a simulated run must not wake the real app): the real app and `cherry`
/// use the bundle identifier; tests pass their own.
public struct DarwinNotifySignal: CrossProcessSignalPort {
    private let namespace: String
    private let queue = DispatchQueue(label: "online.odeployer.CherryUtility.signals")

    public init(namespace: String = "online.odeployer.CherryUtility") {
        self.namespace = namespace
    }

    public func post(_ signal: CrossProcessSignal) {
        let name = name(of: signal)
        var token: Int32 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return }
        notify_set_state(token, UInt64(getpid()))
        notify_post(name)
        notify_cancel(token)
    }

    public func signals(_ signal: CrossProcessSignal) -> AsyncStream<Void> {
        let name = name(of: signal)
        let me = UInt64(getpid())
        let queue = queue
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, queue) { token in
                var sender: UInt64 = 0
                notify_get_state(token, &sender)
                if sender != me { continuation.yield() }
            }
            guard status == NOTIFY_STATUS_OK else {
                continuation.finish()
                return
            }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }

    func name(of signal: CrossProcessSignal) -> String {
        "\(namespace).\(signal.rawValue)"
    }
}
