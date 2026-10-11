import CherryCore
import Foundation

/// Settings-style draft editing of one profile.
///
/// - `viewing(base)`: what the keyboard holds, no local changes.
/// - `editing(base, draft, dirty, isSaving)`: local edits; `dirty` lists the fields that differ from `base`.
///
/// Remote updates rebuild the base and keep locally dirty fields; saving sends only the dirty fields; a failed
/// save keeps the draft; discarding restores the base.
public enum ProfileEditor: Equatable, Sendable {
    case viewing(base: ProfileSettings)
    public struct SaveContext: Equatable, Sendable {
        let submitted: ProfileSettings
        var edited: Set<ProfileField>
    }
    case editing(base: ProfileSettings, draft: ProfileSettings, dirty: Set<ProfileField>, isSaving: Bool, saveContext: SaveContext? = nil)

    public init(base: ProfileSettings) {
        self = .viewing(base: base)
    }

    public var base: ProfileSettings {
        switch self {
        case .viewing(let base), .editing(let base, _, _, _, _): base
        }
    }

    /// What the editor shows.
    public var draft: ProfileSettings {
        switch self {
        case .viewing(let base): base
        case .editing(_, let draft, _, _, _): draft
        }
    }

    public var dirty: Set<ProfileField> {
        if case .editing(_, _, let dirty, _, _) = self { return dirty }
        return []
    }

    public var isSaving: Bool {
        if case .editing(_, _, _, let saving, _) = self { return saving }
        return false
    }

    private var saveContext: SaveContext? {
        if case .editing(_, _, _, _, let context) = self { return context }
        return nil
    }

    public var hasUnsavedChanges: Bool { !dirty.isEmpty }

    /// 保存期间继续编辑；本次冻结的补丁由 Feature 持有。
    public mutating func edit(_ change: (inout ProfileSettings) -> Void) {
        let before = self.draft
        var draft = before
        change(&draft)
        draft = draft.normalized
        var context = saveContext
        context?.edited.formUnion(ProfileField.differences(between: before, and: draft))
        self = Self.make(base: base, draft: draft, isSaving: isSaving, saveContext: context)
    }

    /// Replaces the whole draft (e.g. a preset loaded into the editor).
    public mutating func replaceDraft(with settings: ProfileSettings) {
        edit { $0 = settings }
    }

    /// The keyboard reported new values: they become the base, and every field the user has not touched follows them.
    public mutating func rebase(onto remote: ProfileSettings) {
        var draft = remote
        for field in dirty.union(saveContext?.edited ?? []) { field.copy(from: self.draft, into: &draft) }
        self = Self.make(base: remote, draft: draft, isSaving: isSaving, saveContext: saveContext)
    }

    /// Marks the save as running and returns the patch to send, or nil when there is nothing to save.
    public mutating func beginSave(including fields: Set<ProfileField> = [], submitted: ProfileSettings? = nil) -> ProfilePatch? {
        guard !isSaving else { return nil }
        let fields = dirty.union(fields)
        guard !fields.isEmpty else { return nil }
        let frozen = submitted ?? draft
        let patch = ProfilePatch(frozen, fields: fields)
        let context = SaveContext(submitted: frozen, edited: ProfileField.differences(between: frozen, and: draft))
        self = .editing(base: base, draft: draft, dirty: dirty, isSaving: true, saveContext: context)
        return patch
    }

    /// The keyboard confirmed the write and returned `saved`; whatever still differs stays dirty.
    public mutating func saveSucceeded(_ saved: ProfileSettings) {
        var rebased = saved
        for field in saveContext?.edited ?? dirty { field.copy(from: draft, into: &rebased) }
        self = Self.make(base: saved, draft: rebased, isSaving: false)
    }

    /// Keeps the draft and the dirty set so the user can retry.
    public mutating func saveFailed() {
        if case .editing(let base, let draft, let dirty, true, _) = self {
            self = .editing(base: base, draft: draft, dirty: dirty, isSaving: false)
        }
    }

    public mutating func discard() {
        self = .viewing(base: base)
    }

    private static func make(base: ProfileSettings, draft: ProfileSettings, isSaving: Bool, saveContext: SaveContext? = nil) -> ProfileEditor {
        let dirty = ProfileField.differences(between: base, and: draft)
        return dirty.isEmpty && !isSaving ? .viewing(base: base) : .editing(base: base, draft: draft, dirty: dirty, isSaving: isSaving, saveContext: saveContext)
    }
}
