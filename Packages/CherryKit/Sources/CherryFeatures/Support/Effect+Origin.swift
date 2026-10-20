import CherryCore
import ComposableArchitecture

extension Effect {
    /// 驱动侧声明观测来源：effect 内调用的 Core 服务和适配器都继承这个 origin，被调用方不自行指定。
    static func run(
        origin: DiagnosticOrigin,
        operation: @escaping @Sendable (_ send: Send<Action>) async throws -> Void,
        catch handler: (@Sendable (_ error: any Error, _ send: Send<Action>) async -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> Self {
        .run(
            operation: { send in try await DiagnosticOrigin.$current.withValue(origin) { try await operation(send) } },
            catch: handler, fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    /// reducer 不直接写观测：结果被采用或忽略由它决定，记录作为 effect 执行。
    static func record(_ operation: DiagnosticOperation, origin: DiagnosticOrigin, outcome: DiagnosticOutcome?,
                       with diagnostics: Diagnostics) -> Self {
        .run(origin: origin) { _ in diagnostics.emit(operation, outcome: outcome) }
    }
}
