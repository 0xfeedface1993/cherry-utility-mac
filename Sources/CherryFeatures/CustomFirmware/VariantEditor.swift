import CherryCore
import Foundation

public enum VariantField: Hashable, Sendable {
    case name
    case option(String)
}

public struct VariantDraft: Equatable, Sendable {
    public var name: String
    /// Option ID → value ID, non-stock choices only (like `FirmwareVariant.selections`).
    public var selections: [String: String]

    init(_ variant: FirmwareVariant) {
        name = variant.name
        selections = variant.selections
    }
}

/// Settings-style draft editing of one saved variant.
///
/// - `viewing(base)`: the saved variant, no local changes.
/// - `editing(base, draft, dirty, isSaving)`: local edits; `dirty` lists what differs from `base`.
///
/// A reloaded variant becomes the base and every field the user has not touched follows it; saving writes the draft;
/// a failed save keeps the draft; discarding restores the base. Editing is disabled while a save runs (it is a local
/// file write and a build, so it is short).
public enum VariantEditor: Equatable, Sendable {
    case viewing(base: FirmwareVariant)
    case editing(base: FirmwareVariant, draft: VariantDraft, dirty: Set<VariantField>, isSaving: Bool)

    public init(base: FirmwareVariant) {
        self = .viewing(base: base)
    }

    public var base: FirmwareVariant {
        switch self {
        case .viewing(let base), .editing(let base, _, _, _): base
        }
    }

    public var draft: VariantDraft {
        switch self {
        case .viewing(let base): VariantDraft(base)
        case .editing(_, let draft, _, _): draft
        }
    }

    public var dirty: Set<VariantField> {
        if case .editing(_, _, let dirty, _) = self { return dirty }
        return []
    }

    public var isSaving: Bool {
        if case .editing(_, _, _, let saving) = self { return saving }
        return false
    }

    public var hasUnsavedChanges: Bool { !dirty.isEmpty }

    /// The variant as the editor shows it.
    public var current: FirmwareVariant {
        var variant = base
        variant.name = draft.name
        variant.selections = draft.selections
        return variant
    }

    public func value(of option: CustomizationOption) -> OptionValue {
        draft.selections[option.id].flatMap(option.value) ?? option.stockValue
    }

    public mutating func setName(_ name: String) {
        edit { $0.name = name }
    }

    /// Choosing the stock value removes the option from the selections.
    public mutating func select(_ valueID: String, for option: CustomizationOption) {
        guard let value = option.value(valueID) else { return }
        edit { $0.selections[option.id] = value.isStock ? nil : value.id }
    }

    /// Drops selections the definition no longer knows.
    public mutating func removeUnknownSelections(in definition: FirmwareDefinition) {
        edit { $0.selections = definition.normalized($0.selections, droppingUnknown: true) }
    }

    /// The saved variant changed underneath (e.g. its build CRC after a flash): untouched fields follow it.
    public mutating func rebase(onto remote: FirmwareVariant) {
        var draft = VariantDraft(remote)
        for field in dirty {
            switch field {
            case .name: draft.name = self.draft.name
            case .option(let id): draft.selections[id] = self.draft.selections[id]
            }
        }
        self = Self.make(base: remote, draft: draft, isSaving: isSaving)
    }

    /// Marks the save as running and returns the variant to store, or nil when there is nothing to save.
    public mutating func beginSave() -> FirmwareVariant? {
        guard !isSaving, hasUnsavedChanges else { return nil }
        self = .editing(base: base, draft: draft, dirty: dirty, isSaving: true)
        return current
    }

    public mutating func saveSucceeded(_ saved: FirmwareVariant) {
        self = .viewing(base: saved)
    }

    /// Keeps the draft and the dirty set so the user can retry.
    public mutating func saveFailed() {
        if case .editing(let base, let draft, let dirty, true) = self {
            self = .editing(base: base, draft: draft, dirty: dirty, isSaving: false)
        }
    }

    public mutating func discard() {
        self = .viewing(base: base)
    }

    private mutating func edit(_ change: (inout VariantDraft) -> Void) {
        guard !isSaving else { return }
        var draft = self.draft
        change(&draft)
        self = Self.make(base: base, draft: draft, isSaving: false)
    }

    private static func make(base: FirmwareVariant, draft: VariantDraft, isSaving: Bool) -> VariantEditor {
        var dirty: Set<VariantField> = []
        if draft.name != base.name { dirty.insert(.name) }
        for id in Set(draft.selections.keys).union(base.selections.keys) where draft.selections[id] != base.selections[id] {
            dirty.insert(.option(id))
        }
        return dirty.isEmpty && !isSaving ? .viewing(base: base) : .editing(base: base, draft: draft, dirty: dirty, isSaving: isSaving)
    }
}
