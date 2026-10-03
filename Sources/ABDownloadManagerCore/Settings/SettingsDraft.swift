import Foundation

/// Keeps the Settings window's in-progress edits separate from persisted
/// settings. Periodic app-state refreshes may publish new persisted values,
/// but must not replace a draft the user is currently editing.
public struct SettingsDraft: Sendable, Equatable {
    public private(set) var persisted: AppSettings
    public private(set) var value: AppSettings
    public private(set) var isDirty: Bool

    public init(persisted: AppSettings = AppSettings()) {
        self.persisted = persisted
        self.value = persisted
        self.isDirty = false
    }

    public mutating func updateDraft(_ value: AppSettings) {
        self.value = value
        isDirty = value != persisted
    }

    /// Accepts a store refresh when there is no unsaved edit. If the store
    /// changed while the user was editing, retain the draft and keep the
    /// newest persisted snapshot as the cancel target.
    public mutating func receivePersisted(_ value: AppSettings) {
        guard persisted != value else { return }
        persisted = value
        guard !isDirty else { return }
        self.value = value
    }

    public mutating func saveSucceeded(_ value: AppSettings) {
        persisted = value
        self.value = value
        isDirty = false
    }

    /// A failed save intentionally leaves both the draft and cancel target
    /// alone so the user can correct the problem or discard the edit.
    public mutating func saveFailed() {}

    public mutating func cancel() {
        value = persisted
        isDirty = false
    }
}
