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

    @Test func coreDependsOnlyOnSystemLibraries() throws {
        let allowed: Set<String> = ["Foundation", "CryptoKit", "Synchronization"]
        for (name, text) in try Self.files("CherryCore") {
            let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }.map { String($0.dropFirst(7)) }
            #expect(Set(imports).isSubset(of: allowed), "\(name) 引入了 \(imports)")
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
