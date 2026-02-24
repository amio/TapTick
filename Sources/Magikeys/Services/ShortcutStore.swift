import Foundation
import Observation

/// Manages persistence and in-memory state of all user-defined shortcuts.
@Observable
final class ShortcutStore: @unchecked Sendable {
    // MARK: - Published State

    private(set) var shortcuts: [Shortcut] = []

    // MARK: - Persistence

    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Magikeys", isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("shortcuts.json")
        loadFromDisk()
    }

    // MARK: - CRUD Operations

    func add(_ shortcut: Shortcut) {
        shortcuts.append(shortcut)
        saveToDisk()
    }

    func update(_ shortcut: Shortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = shortcut
        saveToDisk()
    }

    func remove(id: UUID) {
        shortcuts.removeAll { $0.id == id }
        saveToDisk()
    }

    func remove(atOffsets offsets: IndexSet) {
        shortcuts.remove(atOffsets: offsets)
        saveToDisk()
    }

    func toggleEnabled(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].isEnabled.toggle()
        saveToDisk()
    }

    func markTriggered(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].lastTriggeredAt = Date()
        saveToDisk()
    }

    func shortcut(for keyCombo: KeyCombo) -> Shortcut? {
        shortcuts.first { $0.keyCombo == keyCombo && $0.isEnabled }
    }

    func hasConflict(keyCombo: KeyCombo, excludingID: UUID? = nil) -> Bool {
        shortcuts.contains { shortcut in
            shortcut.keyCombo == keyCombo && shortcut.id != excludingID
        }
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
            print("Magikeys: Failed to load shortcuts: \(error)")
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
            print("Magikeys: Failed to save shortcuts: \(error)")
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
    }
}
