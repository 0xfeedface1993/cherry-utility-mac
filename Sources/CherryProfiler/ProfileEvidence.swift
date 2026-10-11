import CherryCore
import CherryAdapters
import Darwin
import Foundation

struct ProfileOptions: Sendable {
    var mode = "standard"
    var output = URL(fileURLWithPath: "/tmp/CherryProfile-\(UUID().uuidString)", isDirectory: true)
    var idleSeconds = 300
    var inputSeconds = 60
    var scenario = "all"
    var updater: URL?
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count.isMultiple(of: 2) else { throw ProfileError.arguments }
        for i in stride(from: 0, to: args.count, by: 2) {
            let value = args[i + 1]
            switch args[i] {
            case "--mode": mode = value
            case "--output": output = URL(fileURLWithPath: value, isDirectory: true)
            case "--idle-seconds": guard let n = Int(value), (0...300).contains(n) else { throw ProfileError.arguments }; idleSeconds = n
            case "--input-seconds": guard let n = Int(value), (1...60).contains(n) else { throw ProfileError.arguments }; inputSeconds = n
            case "--scenario": scenario = value
            case "--official-updater": updater = URL(fileURLWithPath: value)
            default: throw ProfileError.arguments
            }
        }
        guard ["noop", "standard", "profile"].contains(mode), ["all", "trace"].contains(scenario) else { throw ProfileError.arguments }
    }
}

enum ProfileError: Error { case arguments, assertion(String) }

struct ProfileResources: Codable {
    var cpuSeconds: Double
    var maximumRSSBytes: Int64
    var voluntarySwitches: Int64
    var involuntarySwitches: Int64
    static func current() -> Self {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return .init(cpuSeconds: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
                     maximumRSSBytes: Int64(usage.ru_maxrss), voluntarySwitches: Int64(usage.ru_nvcsw), involuntarySwitches: Int64(usage.ru_nivcsw))
    }
}

struct ProfileRow: Codable {
    let scenario: String
    let samples: Int
    let medianNs: UInt64
    let p95Ns: UInt64
    let maximumNs: UInt64
    let wallNs: UInt64
    let cpuSeconds: Double
    let maximumRSSBytes: Int64
    let voluntarySwitches: Int64
    let involuntarySwitches: Int64
    let sent: Int?
    let consumed: Int?
    let note: String
    init(_ scenario: String, durations: [UInt64], start: ContinuousClock.Instant, resources: ProfileResources,
         sent: Int? = nil, consumed: Int? = nil, note: String = "") {
        let sorted = durations.sorted(), end = ProfileResources.current()
        func percentile(_ p: Double) -> UInt64 { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        self.scenario = scenario; samples = sorted.count; medianNs = percentile(0.5); p95Ns = percentile(0.95)
        maximumNs = sorted.last ?? 0; wallNs = DiagnosticClock.nanoseconds(start.duration(to: .now))
        cpuSeconds = end.cpuSeconds - resources.cpuSeconds; maximumRSSBytes = end.maximumRSSBytes
        voluntarySwitches = end.voluntarySwitches - resources.voluntarySwitches
        involuntarySwitches = end.involuntarySwitches - resources.involuntarySwitches
        self.sent = sent; self.consumed = consumed; self.note = note
    }
}

struct ProfileResult: Codable {
    var schemaVersion = 1
    let runID: UUID
    let generatedAt: Date
    let mode: String
    let buildConfiguration: String
    let environment: DiagnosticEnvironment
    let simulatedReplyDelayNs: UInt64
    let inputSeconds: Int
    let idleSeconds: Int
    let inputRatePerSecond: Int
    let rows: [ProfileRow]
    let diagnosticRunID: UUID
    let diagnosticEvents: Int
    let droppedDiagnosticEvents: UInt64
    let diagnosticPartial: Bool
    let incompleteSpans: Int
    let sampledSpanBegins: Int
    let sampledSpanEnds: Int
    let officialUpdaterSHA256: String?
}
