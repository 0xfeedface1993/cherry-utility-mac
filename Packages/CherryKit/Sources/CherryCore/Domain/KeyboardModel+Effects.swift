import Foundation

// 同一个原始值在不同型号的灯效表里是不同灯效（例如 PIXIU 98 的 8 是呼吸，PIXIU 75 的 8 是自定义），
// 所以自动化入口一律按名字指定灯效，再在目标键盘的表里解析。
extension KeyboardModel {
    /// The effect of this model's table called `query`: the English name ignoring case and spaces, or the Chinese name.
    public func lightingEffect(named query: String) -> LightingEffect? {
        let key = LightingEffect.nameKey(query)
        guard !key.isEmpty else { return nil }
        return lightingEffects.first { LightingEffect.nameKey($0.englishName) == key || LightingEffect.nameKey($0.name) == key }
    }

    /// Every effect name of the catalog, once each, in first-seen order. Raw values are those of the first model that
    /// has the effect and mean nothing for other models.
    public static let allLightingEffects: [LightingEffect] = {
        var seen = Set<String>()
        return all.flatMap(\.lightingEffects).filter { seen.insert($0.englishName).inserted }
    }()
}

extension LightingEffect {
    static func nameKey(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }
}
