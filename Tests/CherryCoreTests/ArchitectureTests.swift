import Foundation
import Testing

/// 六边形边界的静态检查：编译器只管模块依赖，这里补上它管不到的约定。
@Suite("六边形边界")
struct ArchitectureTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    static func files(_ module: String, under folder: String? = nil) throws -> [(name: String, text: String)] {
        var root = sources.appendingPathComponent(module)
        if let folder { root.appendPathComponent(folder) }
        let paths = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let swift = paths.filter { $0.pathExtension == "swift" }
        #expect(!swift.isEmpty, "未找到 \(module) 源码：\(root.path)")
        return try swift.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// 去掉注释行，只检查代码。
    static func code(_ text: String) -> String {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// Core 只定义类型与规则；OSLog 命名、错误文案、图标、本地化格式、平台错误识别分别属于适配器和 Features。
    @Test func coreHoldsNoAdapterOrPresentationDetails() throws {
        for (name, text) in try Self.files("CherryCore") {
            let code = Self.code(text)
            for token in ["StaticString", "signpost", "URLError", "var title", "var message", "LocalizedError", "errorDescription", ".formatted(", "symbol"] {
                #expect(!code.contains(token), "CherryCore/\(name) 含有 \(token)")
            }
        }
    }

    /// 生产适配器只含真实实现；模拟键盘与合成升级包在 CherrySimulation。
    @Test func productionAdaptersHoldNoSimulation() throws {
        for (name, text) in try Self.files("CherryAdapters") {
            #expect(!Self.code(text).contains("Simulated") && !Self.code(text).contains("Synthetic"), "CherryAdapters/\(name) 含模拟实现")
        }
    }

    @Test func coreDependsOnlyOnSystemLibraries() throws {
        let allowed: Set<String> = ["Foundation", "CryptoKit", "Synchronization"]
        for (name, text) in try Self.files("CherryCore") {
            let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }.map { String($0.dropFirst(7)) }
            #expect(Set(imports).isSubset(of: allowed), "\(name) 引入了 \(imports)")
        }
    }

    /// 文案、控制服务与命令行不依赖界面框架：独立的 cherry 命令在 App 之外直连键盘时，只带 Core、适配器和文案。
    @Test func commandLineStackStaysFreeOfUserInterfaceFrameworks() throws {
        let forbidden: Set<String> = ["SwiftUI", "AppKit", "ComposableArchitecture", "CherryFeatures"]
        for module in ["CherryPresentation", "CherryControlService", "CherryCLI"] {
            for (name, text) in try Self.files(module) {
                let imports = Set(text.split(separator: "\n").filter { $0.hasPrefix("import ") }.map { String($0.dropFirst(7)) })
                #expect(imports.isDisjoint(with: forbidden), "\(module)/\(name) 引入了 \(imports.intersection(forbidden))")
            }
        }
    }

    @Test func domainTypesCarryNoObservability() throws {
        for (name, text) in try Self.files("CherryCore", under: "Domain") {
            #expect(!text.contains("TraceContext") && !text.contains("Diagnostic"), "\(name) 的领域类型引用了观测类型")
        }
    }

    /// 被调用方（Core 服务、被驱动适配器）只继承 origin；声明来源是驱动侧的职责。
    @Test func calleesNeverDeclareAnOrigin() throws {
        let literal = try Regex(#"origin: \.([a-zA-Z]+)"#)
        for module in ["CherryCore", "CherryAdapters"] {
            for (name, text) in try Self.files(module) {
                let declared = text.matches(of: literal).map { String(text[$0.range]) }.filter { !$0.hasSuffix(".background") }
                #expect(declared.isEmpty, "\(module)/\(name) 声明了 \(declared)")
            }
        }
    }
}
