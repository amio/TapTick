import Foundation

enum ShortcutPersistenceError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case duplicateShortcutID

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return
                "This shortcut library uses an unsupported format (version \(version)). Open it with a compatible version of TapTick."
        case .duplicateShortcutID:
            return "The shortcut library contains duplicate shortcut IDs."
        }
    }
}

/// The deletion record used to keep removed shortcuts deleted across devices.
struct ShortcutDeletion: Codable, Equatable, Sendable {
    let id: UUID
    let deletedAt: Date
}

/// The complete persisted state used by local storage and iCloud sync.
struct ShortcutSyncState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var shortcuts: [Shortcut]
    var deletions: [ShortcutDeletion]

    static let empty = ShortcutSyncState(shortcuts: [], deletions: [])

    init(
        schemaVersion: Int = currentSchemaVersion,
        shortcuts: [Shortcut],
        deletions: [ShortcutDeletion]
    ) {
        self.schemaVersion = schemaVersion
        self.shortcuts = shortcuts
        self.deletions = deletions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case shortcuts
        case deletions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        try Self.validateVersion(schemaVersion)
        shortcuts = try container.decode([Shortcut].self, forKey: .shortcuts)
        deletions = try container.decode([ShortcutDeletion].self, forKey: .deletions)
        try validate()
    }

    func validate() throws {
        try Self.validateVersion(schemaVersion)
        guard Set(shortcuts.map(\.id)).count == shortcuts.count else {
            throw ShortcutPersistenceError.duplicateShortcutID
        }
    }

    private static func validateVersion(_ version: Int) throws {
        guard (1...currentSchemaVersion).contains(version) else {
            throw ShortcutPersistenceError.unsupportedVersion(version)
        }
    }

    /// Decodes the current envelope or migrates the legacy shortcut-array format.
    static func decode(from data: Data, using decoder: JSONDecoder) throws -> ShortcutSyncState {
        do {
            return try decoder.decode(ShortcutSyncState.self, from: data)
        } catch DecodingError.typeMismatch(_, let context) where context.codingPath.isEmpty {
            let state = ShortcutSyncState(
                schemaVersion: 1,
                shortcuts: try decoder.decode([Shortcut].self, from: data),
                deletions: []
            )
            try state.validate()
            return state
        }
    }
}
