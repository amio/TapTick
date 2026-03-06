import Foundation
import Observation

/// Manages persistence and in-memory state of all user-defined shortcuts.
///
/// Local data lives in `~/Library/Application Support/TapTick/shortcuts.json`.
/// When iCloud sync is enabled, every local mutation is also pushed to the cloud,
/// and remote changes are merged in automatically via `CloudSyncService`.
@Observable
public final class ShortcutStore: @unchecked Sendable {
    // MARK: - Published State

    private(set) var shortcuts: [Shortcut] = []

    // MARK: - Persistence

    private let fileURL: URL
    private let cloudSync: CloudSyncService?

    /// Flag to prevent upload loops when applying a merge that came from the cloud.
    private var isApplyingRemote = false

    public init(directory: URL? = nil, cloudSync: CloudSyncService? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("TapTick", isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("shortcuts.json")
        self.cloudSync = cloudSync
        loadFromDisk()
        setupCloudSync()
    }

    /// Wire up the cloud sync callback so remote changes are merged automatically.
    private func setupCloudSync() {
        guard let cloudSync else { return }
        cloudSync.onRemoteChange = { [weak self] remoteShortcuts in
            self?.applyRemoteChanges(remoteShortcuts)
        }
    }

    // MARK: - CRUD Operations

    func add(_ shortcut: Shortcut) {
        var s = shortcut
        s.modifiedAt = Date()
        shortcuts.append(s)
        saveToDisk()
        syncToCloud()
    }

    func update(_ shortcut: Shortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        var s = shortcut
        s.modifiedAt = Date()
        shortcuts[index] = s
        saveToDisk()
        syncToCloud()
    }

    func remove(id: UUID) {
        shortcuts.removeAll { $0.id == id }
        saveToDisk()
        syncToCloud()
    }

    func remove(atOffsets offsets: IndexSet) {
        shortcuts.remove(atOffsets: offsets)
        saveToDisk()
        syncToCloud()
    }

    func toggleEnabled(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].isEnabled.toggle()
        shortcuts[index].modifiedAt = Date()
        saveToDisk()
        syncToCloud()
    }

    func markTriggered(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].lastTriggeredAt = Date()
        // Trigger timestamps are local-only — no cloud sync or modifiedAt bump.
        saveToDisk()
    }

    func shortcut(for keyCombo: KeyCombo) -> Shortcut? {
        shortcuts.first { $0.keyCombo == keyCombo && $0.isEnabled }
    }

    func hasConflict(keyCombo: KeyCombo, excludingID: UUID? = nil) -> Bool {
        shortcuts.contains { shortcut in
            // Shortcuts with no bound hotkey never conflict.
            guard let bound = shortcut.keyCombo else { return false }
            return bound == keyCombo && shortcut.id != excludingID
        }
    }

    // MARK: - Cloud Sync

    private func syncToCloud() {
        guard !isApplyingRemote else { return }
        cloudSync?.upload(shortcuts: shortcuts)
    }

    /// Merge remote shortcuts into local data without re-uploading.
    private func applyRemoteChanges(_ remoteShortcuts: [Shortcut]) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        let merged = CloudSyncService.merge(local: shortcuts, remote: remoteShortcuts)

        // Only persist if something actually changed.
        guard merged != shortcuts else { return }
        shortcuts = merged
        saveToDisk()
    }

    /// Perform a full sync: download + merge + upload the merged result.
    func performFullSync() {
        guard let cloudSync, cloudSync.isEnabled else { return }

        if let remote = cloudSync.download() {
            let merged = CloudSyncService.merge(local: shortcuts, remote: remote)
            shortcuts = merged
            saveToDisk()
        }

        // Upload the (possibly merged) local data so the cloud has the latest.
        cloudSync.upload(shortcuts: shortcuts)
    }

    // MARK: - Disk I/O

    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            shortcuts = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            shortcuts = try JSONDecoder().decode([Shortcut].self, from: data)
        } catch {
            print("TapTick: Failed to load shortcuts: \(error)")
            shortcuts = []
        }
    }

    func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(shortcuts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("TapTick: Failed to save shortcuts: \(error)")
        }
    }

    // MARK: - Import/Export

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(shortcuts)
    }

    func importData(_ data: Data) throws {
        let decoded = try JSONDecoder().decode([Shortcut].self, from: data)
        shortcuts = decoded
        saveToDisk()
        syncToCloud()
    }
}
