import Foundation

@main
struct CherryProfiler {
    @MainActor static func main() async {
        do {
            let options = try ProfileOptions()
            try await ProfileRunner(options: options).run()
        } catch {
            // 仅开发工具的终端输出；诊断 journal 仍使用白名单错误。
            FileHandle.standardError.write(Data("CherryProfiler failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
