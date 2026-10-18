import CherryCore
import Foundation
import Synchronization

/// In-memory automation switches for tests and previews; every entry starts enabled.
public final class InMemoryAutomationPreferences: AutomationPreferencesPort, Sendable {
    private let values = Mutex<[AutomationEntry: Bool]>([:])

    public init() {}

    public func isEnabled(_ entry: AutomationEntry) -> Bool { values.withLock { $0[entry] ?? true } }
    public func setEnabled(_ entry: AutomationEntry, _ enabled: Bool) { values.withLock { $0[entry] = enabled } }
}

/// In-memory activity record for tests and previews.
public final class InMemoryAutomationActivity: AutomationActivityStore, Sendable {
    private let value = Mutex(AutomationActivity())

    public init() {}

    public func load() -> AutomationActivity { value.withLock { $0 } }
    public func record(_ call: AutomationCall) throws -> AutomationActivity {
        value.withLock { $0 = $0.recording(call); return $0 }
    }
}
