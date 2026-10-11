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
    case editing(base: ProfileSettings, draft: ProfileSettings, dirty: Set<ProfileField>, isSaving: Bool)

    public init(base: ProfileSettings) {
        self = .viewing(base: base)
    }

    public var base: ProfileSettings {
        switch self {
        case .viewing(let base), .editing(let base, _, _, _): base
        }
    }

    /// What the editor shows.
    public var draft: ProfileSettings {
        switch self {
        case .viewing(let base): base
        case .editing(_, let draft, _, _): draft
        }
    }

    public var dirty: Set<ProfileField> {
        if case .editing(_, _, let dirty, _) = self { return dirty }
        return []
    }

    public var isSaving: Bool {
        if case .editing(_, _, _, let saving) = self { return saving }
        return false
    }

    public var hasUnsavedChanges: Bool { !dirty.isEmpty }

    /// Applies a local edit. Ignored while a save is running.
    public mutating func edit(_ change: (inout ProfileSettings) -> Void) {
        guard !isSaving else { return }
        var draft = self.draft
        change(&draft)
        self = Self.make(base: base, draft: draft.normalized, isSaving: false)
    }

    /// Replaces the whole draft (e.g. a preset loaded into the editor).
    public mutating func replaceDraft(with settings: ProfileSettings) {
        edit { $0 = settings }
    }

    /// The keyboard reported new values: they become the base, and every field the user has not touched follows them.
    public mutating func rebase(onto remote: ProfileSettings) {
        var draft = remote
        for field in dirty { field.copy(from: self.draft, into: &draft) }
        self = Self.make(base: remote, draft: draft, isSaving: isSaving)
    }

    /// Marks the save as running and returns the patch to send, or nil when there is nothing to save.
    public mutating func beginSave() -> ProfilePatch? {
        guard case .editing(let base, let draft, let dirty, false) = self, !dirty.isEmpty else { return nil }
        self = .editing(base: base, draft: draft, dirty: dirty, isSaving: true)
        return ProfilePatch(draft, fields: dirty)
    }

    /// The keyboard confirmed the write and returned `saved`; whatever still differs stays dirty.
    public mutating func saveSucceeded(_ saved: ProfileSettings) {
        self = Self.make(base: saved, draft: draft, isSaving: false)
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

    private static func make(base: ProfileSettings, draft: ProfileSettings, isSaving: Bool) -> ProfileEditor {
        let dirty = ProfileField.differences(between: base, and: draft)
        return dirty.isEmpty && !isSaving ? .viewing(base: base) : .editing(base: base, draft: draft, dirty: dirty, isSaving: isSaving)
    }
}
