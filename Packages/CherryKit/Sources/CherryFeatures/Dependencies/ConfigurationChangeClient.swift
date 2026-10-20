import CherryCore
import ComposableArchitecture
import Foundation

/// 界面之外（快捷指令、Spotlight 等自动化入口）写入并读回的配置；App 据此同步菜单栏和主窗口。
@DependencyClient
public struct ConfigurationChangeClient: Sendable {
    public var changes: @Sendable () -> AsyncStream<ExternalConfigurationChange> = { .finished }
}

extension ConfigurationChangeClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(changes: { AsyncStream { _ in } })
}

extension DependencyValues {
    public var configurationChangeClient: ConfigurationChangeClient {
        get { self[ConfigurationChangeClient.self] }
        set { self[ConfigurationChangeClient.self] = newValue }
    }
}
