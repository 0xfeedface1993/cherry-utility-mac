import AppIntentsTesting
import AppKit
import XCTest

/// 系统 App Intents 服务的入口。查找定义和执行意图都放在后台任务里，不占用 XCUITest 操作界面所在的主 actor。
@available(macOS 27.0, *)
enum Intents {
    static let bundleIdentifier = "online.odeployer.CherryUtility"

    @discardableResult
    static func run(_ make: @escaping @Sendable (IntentDefinitions) -> AnyAppIntent) async throws -> ResolvedIntentResult {
        try await detached { try await make(IntentDefinitions(bundleIdentifier: bundleIdentifier)).run() }
    }

    static func query<T: Sendable>(_ body: @escaping @Sendable (IntentDefinitions) async throws -> T) async throws -> T {
        try await detached { try await body(IntentDefinitions(bundleIdentifier: bundleIdentifier)) }
    }

    /// 分离的任务不继承调用方的取消；`run(within:)` 超时取消时要一并取消它，否则意图仍在后台等待。
    private static func detached<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(operation: body)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// 最多等 `seconds` 秒；意图在等用户补参数（needsValue）时 `run()` 可能一直不返回。
    static func run(within seconds: Double, _ make: @escaping @Sendable (IntentDefinitions) -> AnyAppIntent) async throws -> ResolvedIntentResult {
        try await withThrowingTaskGroup(of: ResolvedIntentResult.self) { group in
            group.addTask { try await run(make) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw IntentTimeout(seconds: seconds)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

struct IntentTimeout: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "意图 \(seconds) 秒内没有返回" }
}

@available(macOS 27.0, *)
extension IntentDefinitions {
    func profile(_ number: Int) -> AnyAppEnum { enums["ProfileSlot"].makeCase("\(number)") }
    func effect(_ englishName: String) -> AnyAppEnum { enums["LightingEffectOption"].makeCase(englishName) }
    /// off / low / medium / high / full
    func brightness(_ level: String) -> AnyAppEnum { enums["BrightnessLevel"].makeCase(level) }
    func speed(_ level: Int) -> AnyAppEnum { enums["SpeedLevel"].makeCase("\(level)") }
    /// random / red / orange / … / custom
    func color(_ option: String) -> AnyAppEnum { enums["LightingColorOption"].makeCase(option) }
    func keyboard(_ identifier: String) -> AnyAppEntity { entities["KeyboardEntity"].makeReference(identifier: identifier) }
    func preset(_ identifier: String) -> AnyAppEntity { entities["PresetEntity"].makeReference(identifier: identifier) }
}

/// 意图用例的基类：模拟模式启动 App 后记下它的 pid，每次执行意图前后都核对系统里只有这一个 CherryUtility，
/// 防止意图被系统转给另一份（可能以真机模式运行的）构建。
@available(macOS 27.0, *)
@MainActor
class IntentsTestCase: CherryUITestCase {
    private(set) var appPID: pid_t = 0

    nonisolated static let pixiu75 = "046A:01E2@03100000"
    nonisolated static let second = "046A:01E2@03200000"

    @discardableResult
    func start(_ scenario: String = "pixiu75", environment: [String: String] = [:]) -> XCUIApplication {
        let app = launch(scenario, environment: environment)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Intents.bundleIdentifier)
        XCTAssertEqual(running.count, 1, "应只有一个 CherryUtility 实例")
        appPID = running.first?.processIdentifier ?? 0
        return app
    }

    func assertSingleInstance(file: StaticString = #filePath, line: UInt = #line) {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: Intents.bundleIdentifier).map(\.processIdentifier)
        XCTAssertEqual(pids, [appPID], "意图必须落在本用例启动的模拟实例上", file: file, line: line)
    }

    @discardableResult
    func intent(_ make: @escaping @Sendable (IntentDefinitions) -> AnyAppIntent, file: StaticString = #filePath, line: UInt = #line) async throws -> ResolvedIntentResult {
        assertSingleInstance(file: file, line: line)
        defer { assertSingleInstance(file: file, line: line) }
        return try await Intents.run(make)
    }

    func status(keyboard: String? = nil) async throws -> AnyTransientAppEntity {
        let result = try await intent { definitions in
            keyboard.map { definitions.intents["GetKeyboardStatusIntent"].makeIntent(keyboard: definitions.keyboard($0)) }
                ?? definitions.intents["GetKeyboardStatusIntent"].makeIntent()
        }
        return try result.value
    }

    /// 意图应失败，错误说明里含 `fragment`；返回错误说明供进一步核对。
    @discardableResult
    func expectFailure(
        containing fragment: String, within seconds: Double = 30, file: StaticString = #filePath, line: UInt = #line,
        _ make: @escaping @Sendable (IntentDefinitions) -> AnyAppIntent
    ) async -> String {
        assertSingleInstance(file: file, line: line)
        do {
            try await Intents.run(within: seconds, make)
            XCTFail("意图应失败（期望含「\(fragment)」）", file: file, line: line)
            return ""
        } catch {
            let text = describe(error)
            // 空片段表示只要求失败（Foundation 的 `contains("")` 为 false）。
            XCTAssertTrue(fragment.isEmpty || text.contains(fragment), "错误应含「\(fragment)」，实际：\(text)", file: file, line: line)
            return text
        }
    }

    /// 错误描述与本地化说明一起比对：系统服务可能把意图的错误包装一层。
    func describe(_ error: any Error) -> String { Self.describeError(error) }

    nonisolated static func describeError(_ error: any Error) -> String {
        "\(error) \(error.localizedDescription) \((error as NSError).userInfo)"
    }

    /// 执行意图，返回错误说明；意图成功时返回空字符串。不占用主 actor，可在任务组里并发调用。
    nonisolated static func failureText(
        within seconds: Double = 30, _ make: @escaping @Sendable (IntentDefinitions) -> AnyAppIntent
    ) async -> String {
        do {
            try await Intents.run(within: seconds, make)
            return ""
        } catch {
            return describeError(error)
        }
    }

    /// 实体属性为 nil（型号不支持的字段）时返回 true。
    func isMissing(_ entity: AnyTransientAppEntity, _ property: String) -> Bool {
        let value: (any IntentValueExpressing)? = entity[dynamicMember: property]
        return value == nil
    }
}
