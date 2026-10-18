import CherryCore
import CoreFoundation
import Foundation

/// The automation switches in a preferences domain both processes can read: the app's own domain
/// (`online.odeployer.CherryUtility`), or the throwaway simulation suite in simulated runs. Uses CFPreferences, which is
/// thread-safe and keeps nothing but the domain name here; each read synchronizes first, so a long-running `cherry mcp`
/// sees a switch the user flipped in the app a moment ago.
public struct SharedAutomationPreferences: AutomationPreferencesPort {
    private let domain: String

    public init(domain: String) {
        self.domain = domain
    }

    public func isEnabled(_ entry: AutomationEntry) -> Bool {
        CFPreferencesAppSynchronize(domain as CFString)
        let value = CFPreferencesCopyAppValue(Self.key(entry) as CFString, domain as CFString)
        return (value as? Bool) ?? true
    }

    public func setEnabled(_ entry: AutomationEntry, _ enabled: Bool) {
        CFPreferencesSetAppValue(Self.key(entry) as CFString, enabled as CFBoolean, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    static func key(_ entry: AutomationEntry) -> String {
        switch entry {
        case .commandLine: "automation.commandLineEnabled"
        case .mcp: "automation.mcpEnabled"
        }
    }
}
