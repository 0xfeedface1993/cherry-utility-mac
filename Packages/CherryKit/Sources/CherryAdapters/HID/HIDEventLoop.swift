import CherryCore
import CoreFoundation
import Foundation

/// A dedicated thread whose run loop owns every IOKit HID object of the app.
///
/// IOHIDManager / IOHIDDevice callbacks are scheduled on this run loop and all IOKit calls are funnelled
/// through `execute`/`run`, so HID state is confined to one thread (loop-affine, like a NIO EventLoop)
/// and needs no locks. Created once by the composition root and kept for the app's lifetime.
public final class HIDEventLoop: Sendable {
    private let thread: ThreadRef
    let diagnostics: Diagnostics
    private let trampoline = Trampoline()

    /// Only used as a `perform(_:on:)` target and for identity checks, both safe from any thread.
    private struct ThreadRef: @unchecked Sendable { let value: Thread }

    /// Delivers blocks through `perform(_:on:with:waitUntilDone:)`, which queues them on the thread's run loop
    /// even before it starts spinning – so creating the loop never has to wait for the thread.
    private final class Trampoline: NSObject, Sendable {
        @objc func run(_ box: BlockBox) { box.block() }
    }

    private final class BlockBox: NSObject, Sendable {
        let block: @Sendable () -> Void
        init(_ block: @escaping @Sendable () -> Void) { self.block = block }
    }

    public init(name: String = "CherryKit.HID", diagnostics: Diagnostics = .noop) {
        self.diagnostics = diagnostics
        let thread = Thread {
            // A far-future timer keeps CFRunLoopRun from returning while no HID source is attached yet.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = ThreadRef(value: thread)
    }

    var isCurrent: Bool { Thread.current === thread.value }

    /// Enqueues `block` on the HID thread (FIFO).
    func execute(_ block: @escaping @Sendable () -> Void) {
        let scheduled = diagnostics.begin(.hidSchedule)
        // HID 线程没有调用方的 task-local；trace 与 origin 一并带过去。
        let context = TraceContext.current
        let origin = DiagnosticOrigin.current
        let diagnostics = self.diagnostics
        let wrapped: @Sendable () -> Void = {
            scheduled.finish()
            DiagnosticOrigin.$current.withValue(origin) {
                TraceContext.$current.withValue(context) {
                    diagnostics.measure(.hidExecution) { block() }
                }
            }
        }
        trampoline.perform(#selector(Trampoline.run(_:)), on: thread.value, with: BlockBox(wrapped), waitUntilDone: false)
    }

    /// Runs `body` on the HID thread and returns its result.
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            execute { continuation.resume(with: Result { try body() }) }
        }
    }
}
