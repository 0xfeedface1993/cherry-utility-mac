import CherryCore
import ComposableArchitecture
import Foundation

// User-facing text and view models of the custom-firmware page. The core only has typed values.

extension CustomFirmwareError: UserFacingError {
    var message: String {
        switch self {
        case .invalidDefinition(let source, let issues):
            let listed = issues.prefix(3).map(\.message).joined(separator: "；")
            return "固件定义 \(source) 无效：\(listed)" + (issues.count > 3 ? " 等 \(issues.count) 项" : "")
        case .definitionNotFound(let id):
            return "找不到固件定义 \(id)"
        case .invalidVariant(let detail):
            return detail == "name" ? "方案名称不能为空" : "方案文件无法解析"
        case .stockNotInCatalog(let name):
            return "Cherry 官方目录中没有 \(name)，可以改为选择本地升级包"
        case .stockMismatch(let expected, let actual):
            return "该升级包不是定义对应的原厂固件（CRC \(CustomFirmwarePresentation.crc(actual))，应为 \(CustomFirmwarePresentation.crc(expected))）"
        case .unknownSelections(let items):
            return "方案包含当前定义不认识的选项：\(items.joined(separator: "、"))"
        case .variantDefinitionMismatch(let variant, _):
            return "方案「\(variant)」属于另一个固件版本"
        case .verificationMismatch(let expected, let actual):
            return "键盘读回的固件 CRC 为 \(CustomFirmwarePresentation.crc(actual))，与写入的 \(CustomFirmwarePresentation.crc(expected)) 不一致"
        }
    }
}

extension DefinitionIssue {
    var message: String {
        switch self {
        case .malformed: "格式错误"
        case .unsupportedSchema(let v): "不支持的格式版本 \(v)"
        case .invalidHex(let field): "\(field) 不是有效的十六进制"
        case .duplicateID(let id): "ID \(id) 重复"
        case .unknownGroup(let option, let group): "选项 \(option) 引用了不存在的分组 \(group)"
        case .unknownPalette(let option, let palette): "选项 \(option) 引用了不存在的取值表 \(palette)"
        case .noValues(let option): "选项 \(option) 没有可选值"
        case .lengthMismatch(let option, let value): "选项 \(option) 的取值 \(value) 长度与原始字节不一致"
        case .outOfRange(let option, let offset): "选项 \(option) 的偏移 \(CustomFirmwarePresentation.offset(offset)) 超出镜像"
        case .protectedRange(let option, let offset): "选项 \(option) 改动了镜像头或 CRC（偏移 \(CustomFirmwarePresentation.offset(offset))）"
        case .overlap(let option, let other, let offset): "选项 \(option) 与 \(other) 在 \(CustomFirmwarePresentation.offset(offset)) 处重叠"
        case .originalMismatch(let option, let offset): "选项 \(option) 在 \(CustomFirmwarePresentation.offset(offset)) 处的原始字节与原厂镜像不符"
        }
    }
}

struct InstalledPresentation: Equatable {
    enum Tone: Equatable { case neutral, stock, custom, warning }

    var headline: String
    var detail: String
    var systemImage: String
    var tone: Tone
}

struct VariantRowPresentation: Identifiable, Equatable {
    let id: UUID
    var name: String
    var summary: String
    var isInstalled: Bool
    var hasUnsavedChanges: Bool
}

struct OptionChoicePresentation: Identifiable, Equatable {
    let id: String
    var label: String
}

struct OptionRowPresentation: Identifiable, Equatable {
    let id: String
    var name: String
    var detail: String?
    var isExperimental: Bool
    var isToggle: Bool
    /// For toggles: the value that means "on".
    var onValueID: String?
    var stockValueID: String
    var selectedValueID: String
    var choices: [OptionChoicePresentation]
    var isUnsaved: Bool

    var isOn: Bool { selectedValueID != stockValueID }
}

struct OptionGroupPresentation: Identifiable, Equatable {
    let id: String
    var name: String
    var detail: String?
    var options: [OptionRowPresentation]

    /// Every option is experimental: the badge goes on the group once instead of on each row.
    var isExperimental: Bool { !options.isEmpty && options.allSatisfy(\.isExperimental) }
}

enum CustomFirmwarePresentation {
    static let needsWiredConnection = "需要用 USB 线有线连接键盘才能读取固件"

    static func crc(_ value: UInt32) -> String { String(format: "0x%08X", value) }
    static func offset(_ value: Int) -> String { String(format: "0x%05X", value) }

    static func valueLabel(_ value: OptionValue) -> String {
        guard value.isStock else { return value.name }
        return value.name.isEmpty ? "原厂值" : "\(value.name)（原厂）"
    }

    static func newVariantName(existing: [FirmwareVariant]) -> String {
        let names = Set(existing.map(\.name))
        return (existing.count + 1 ... existing.count + 1 + names.count).lazy.map { "方案 \($0)" }.first { !names.contains($0) } ?? "方案"
    }

    static func copyName(of name: String, existing: [FirmwareVariant]) -> String {
        let names = Set(existing.map(\.name))
        let base = "\(name) 副本"
        guard names.contains(base) else { return base }
        return (2 ... names.count + 2).lazy.map { "\(base) \($0)" }.first { !names.contains($0) } ?? base
    }

    static func targetName(_ install: CustomFirmwareInstall) -> String {
        install.variant.map { "方案「\($0.name)」" } ?? "原厂固件"
    }

    static func verificationFailed(_ message: String) -> String {
        "写入已完成，但验证未通过：\(message)"
    }

    // MARK: Installed firmware

    static func installed(_ state: CustomFirmwareFeature.State) -> InstalledPresentation {
        switch state.device {
        case .idle:
            return InstalledPresentation(headline: "尚未读取", detail: "", systemImage: "questionmark.circle", tone: .neutral)
        case .loading:
            return InstalledPresentation(headline: "读取中…", detail: "", systemImage: "hourglass", tone: .neutral)
        case .failed(let message):
            return InstalledPresentation(headline: "无法读取", detail: message, systemImage: "exclamationmark.triangle", tone: .warning)
        case .loaded(let status):
            let crcText = "镜像 CRC \(crc(status.crc))"
            switch state.installed {
            case .stock(let definitionID)?:
                let version = state.catalog.value?.definitions.first { $0.id == definitionID }?.firmware.version.description ?? ""
                return InstalledPresentation(headline: "原厂固件 \(version)", detail: crcText, systemImage: "checkmark.seal", tone: .stock)
            case .variant(let id, _)?:
                let name = state.library.value?.variants.first { $0.id == id }?.name ?? ""
                return InstalledPresentation(headline: "自定义方案「\(name)」", detail: "\(crcText) · 与方案当前内容一致", systemImage: "wand.and.stars", tone: .custom)
            case .earlierBuild(let record)?:
                let exists = state.library.value?.variants.contains { $0.id == record.variantID } ?? false
                let name = record.variantName.map { "方案「\($0)」的早期版本" } ?? "原厂固件"
                let when = record.date.formatted(date: .abbreviated, time: .shortened)
                let note = record.variantID == nil ? "" : (exists ? " · 方案此后已修改" : " · 方案已删除")
                return InstalledPresentation(headline: name, detail: "\(crcText) · \(when) 写入\(note)", systemImage: "clock.arrow.circlepath", tone: .custom)
            case .unknown?, nil:
                return InstalledPresentation(
                    headline: "未知固件", detail: "\(crcText) · 不是已知的原厂镜像，也不是本机写入过的方案",
                    systemImage: "questionmark.diamond", tone: .warning
                )
            }
        }
    }

    // MARK: Variants and options

    static func variantRows(_ state: CustomFirmwareFeature.State) -> [VariantRowPresentation] {
        let installedID: UUID? = if case .variant(let id, _)? = state.installed { id } else { nil }
        return state.variants.map { variant in
            let changes = state.definition?.resolve(variant.selections).changes.count ?? variant.selections.count
            var summary = changes == 0 ? "与原厂相同" : "改动 \(changes) 项"
            if let crc = variant.builtCRC { summary += " · \(Self.crc(crc))" }
            let editing = state.editor?.base.id == variant.id ? state.editor : nil
            return VariantRowPresentation(
                id: variant.id, name: editing?.draft.name ?? variant.name, summary: summary,
                isInstalled: variant.id == installedID, hasUnsavedChanges: editing?.hasUnsavedChanges ?? false
            )
        }
    }

    static func groups(_ definition: FirmwareDefinition, editor: VariantEditor) -> [OptionGroupPresentation] {
        definition.groups.map { group in
            OptionGroupPresentation(id: group.id, name: group.name, detail: group.detail, options: definition.options(in: group).map { option in
                OptionRowPresentation(
                    id: option.id, name: option.name, detail: option.detail, isExperimental: option.stability == .experimental,
                    isToggle: option.isToggle, onValueID: option.isToggle ? option.values.first { !$0.isStock }?.id : nil,
                    stockValueID: option.stockValue.id, selectedValueID: editor.value(of: option).id,
                    choices: option.values.map { OptionChoicePresentation(id: $0.id, label: valueLabel($0)) },
                    isUnsaved: editor.dirty.contains(.option(option.id))
                )
            })
        }
    }

    static func buildSummary(_ state: CustomFirmwareFeature.State) -> String {
        guard let definition = state.definition, let editor = state.editor else { return "" }
        let resolved = definition.resolve(editor.draft.selections)
        var text = resolved.changes.isEmpty ? "与原厂相同" : "改动 \(resolved.changes.count) 项 · \(resolved.changedByteCount) 字节"
        if !editor.hasUnsavedChanges, let crc = editor.base.builtCRC {
            text += " · 镜像 CRC \(Self.crc(crc))"
        } else if state.stock.value == nil {
            text += " · 获取原厂镜像后计算 CRC"
        } else {
            text += " · 保存后计算 CRC"
        }
        return text
    }

    // MARK: Alerts

    static func installAlert(_ install: CustomFirmwareInstall, keyboard: KeyboardSummary, sameImage: Bool) -> AlertState<CustomFirmwareFeature.Action.Alert> {
        let target = targetName(install)
        let headline: String = switch (install.variant == nil, sameImage) {
        case (true, true): "键盘已是原厂固件，确定重新写入？"
        case (true, false): "恢复原厂固件？"
        case (false, true): "键盘已是\(target)，确定重新写入？"
        case (false, false): "写入\(target)？"
        }
        return AlertState {
            TextState(headline)
        } actions: {
            ButtonState(role: .destructive, action: .confirmInstall) { TextState("开始写入") }
            ButtonState(role: .cancel) { TextState("取消") }
        } message: {
            TextState(
                "将向 \(keyboard.displayName) 写入\(target)（\(install.package.image.firmware.count) 字节，CRC \(crc(install.expectedCRC))）。"
                    + (install.variant == nil ? "" : "这是按逆向分析修改的固件；行为异常时可以随时恢复原厂固件。")
                    + "写入约需 30 秒，期间请勿拔线、断电或让电脑休眠。完成后键盘会自动重启。"
            )
        }
    }

    static func deleteAlert(_ name: String, id: UUID) -> AlertState<CustomFirmwareFeature.Action.Alert> {
        AlertState {
            TextState("删除方案「\(name)」？")
        } actions: {
            ButtonState(role: .destructive, action: .confirmDelete(id)) { TextState("删除") }
            ButtonState(role: .cancel) { TextState("取消") }
        } message: {
            TextState("方案文件会被删除；写入记录保留，之后仍能认出键盘上的这个版本。")
        }
    }

    static func discardAlert(selecting id: UUID?) -> AlertState<CustomFirmwareFeature.Action.Alert> {
        AlertState {
            TextState("放弃未保存的修改？")
        } actions: {
            ButtonState(role: .destructive, action: .discardAndSelect(id)) { TextState("放弃修改") }
            ButtonState(role: .cancel) { TextState("继续编辑") }
        }
    }
}
