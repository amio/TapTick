import Cocoa

/// A single user-defined shortcut binding a key combo to an action.
struct Shortcut: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// The key combination that triggers this shortcut. `nil` means no hotkey is bound yet.
    var keyCombo: KeyCombo?
    var action: ShortcutAction
    var isEnabled: Bool
    var createdAt: Date
    /// Tracks the last time this shortcut's content was edited. Used for iCloud merge conflict resolution.
    var modifiedAt: Date
    var lastTriggeredAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        keyCombo: KeyCombo? = nil,
        action: ShortcutAction,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        lastTriggeredAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.keyCombo = keyCombo
        self.action = action
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastTriggeredAt = lastTriggeredAt
    }

    // Custom Decodable: `modifiedAt` may be absent in data created before iCloud sync was added.
    // Falls back to `createdAt` so existing shortcuts.json files decode without data loss.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyCombo = try container.decodeIfPresent(KeyCombo.self, forKey: .keyCombo)
        action = try container.decode(ShortcutAction.self, forKey: .action)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        lastTriggeredAt = try container.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
    }

    /// Whether the action's target is available on this machine (app installed, script file exists).
    var isAvailableOnThisDevice: Bool {
        switch action {
        case .launchApp(let bundleIdentifier, _):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        case .runScript:
            // Inline scripts are always portable.
            return true
        case .runScriptFile(let path, _):
            let expanded = NSString(string: path).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded)
        }
    }
}
