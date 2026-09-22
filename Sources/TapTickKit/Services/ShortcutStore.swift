import Foundation
import Observation

enum ScriptStoreError: LocalizedError, Equatable {
    case invalidName(String)
    case nameExists(String)
    case unavailableLegacyFile(String)
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            return reason
        case .nameExists(let name):
            return "A script named “\(name)” already exists."
        case .unavailableLegacyFile(let path):
            return "The legacy script file is unavailable: \(path)"
        case .fileOperation(let message):
            return message
        }
    }
}

/// Owns shortcut metadata and the managed Scripts directory as one persistence boundary.
///
/// Managed script files are canonical while the source in `ShortcutAction` is a synchronized
/// snapshot for JSON export and iCloud transport. A single directory watcher schedules a
/// debounced full reconciliation, avoiding parallel per-file state.
@MainActor
@Observable
public final class ShortcutStore {
    // MARK: - Published State

    private(set) var shortcuts: [Shortcut] = []
    @ObservationIgnored private(set) var deletions: [ShortcutDeletion] = []
    private(set) var scriptDirectoryIssue: String?

    // MARK: - Persistence

    let scriptsDirectoryURL: URL

    @ObservationIgnored public var onExternalScriptsChanged: (() -> Void)?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let cloudSync: CloudSyncService?
    @ObservationIgnored private var directoryMonitor: ScriptDirectoryMonitor?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var loadedSchemaVersion = ShortcutSyncState.currentSchemaVersion

    public init(directory: URL? = nil, cloudSync: CloudSyncService? = nil) {
        let directory =
            directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent(
                TapTickRuntimeConfiguration.current.appSupportDirectoryName,
                isDirectory: true
            )

        self.fileURL = directory.appendingPathComponent("shortcuts.json")
        self.scriptsDirectoryURL = directory.appendingPathComponent("Scripts", isDirectory: true)
        self.cloudSync = cloudSync

        do {
            try ensureScriptsDirectory()
        } catch {
            scriptDirectoryIssue = error.localizedDescription
        }

        loadFromDisk()
        var isManagedDirectoryReady = true
        if loadedSchemaVersion < ShortcutSyncState.currentSchemaVersion {
            isManagedDirectoryReady = migrateLegacyScripts()
        }
        if isManagedDirectoryReady {
            reconcileScriptDirectory()
            saveToDisk()
            startDirectoryMonitor()
            setupCloudSync()
        }
    }

    deinit {
        reconcileTask?.cancel()
    }

    private func setupCloudSync() {
        guard let cloudSync else { return }
        cloudSync.onRemoteChange = { [weak self] remoteState in
            self?.applyRemoteChanges(remoteState)
        }
    }

    // MARK: - CRUD Operations

    func add(_ shortcut: Shortcut) {
        var shortcut = shortcut
        shortcut.modifiedAt = Date()

        do {
            if case .runScript(let source) = shortcut.action {
                let name = try uniqueName(preferred: shortcut.name)
                shortcut.name = name
                try writeScript(source, to: scriptURL(named: name))
            }
        } catch {
            scriptDirectoryIssue = error.localizedDescription
            return
        }

        clearDeletion(for: shortcut.id)
        shortcuts.append(shortcut)
        saveToDisk()
        syncToCloud()
    }

    @discardableResult
    func createScript() throws -> UUID {
        let name = try uniqueName(preferred: "Untitled Script")
        let shortcut = Shortcut(name: name, action: .runScript(script: ""))
        try writeScript("", to: scriptURL(named: name))
        clearDeletion(for: shortcut.id)
        shortcuts.append(shortcut)
        saveToDisk()
        syncToCloud()
        return shortcut.id
    }

    func update(_ shortcut: Shortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        let current = shortcuts[index]

        if !current.action.isLaunchApp, !shortcut.action.isLaunchApp,
            current.name != shortcut.name || current.action != shortcut.action
        {
            do {
                try updateScript(shortcut)
            } catch {
                scriptDirectoryIssue = error.localizedDescription
            }
            return
        }

        var updated = shortcut
        updated.modifiedAt = Date()
        clearDeletion(for: updated.id)
        shortcuts[index] = updated
        saveToDisk()
        syncToCloud()
    }

    /// Persist editor-owned fields without overwriting a hotkey changed since the draft loaded.
    @discardableResult
    func updateScript(_ shortcut: Shortcut) throws -> Shortcut {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else {
            throw ScriptStoreError.fileOperation("The script no longer exists.")
        }
        let current = shortcuts[index]
        guard case .runScript(let source) = shortcut.action else {
            throw ScriptStoreError.fileOperation("Only managed scripts can be edited.")
        }
        guard !current.action.isLaunchApp else {
            throw ScriptStoreError.fileOperation("The selected shortcut is not a script.")
        }

        let name = try validatedName(shortcut.name)
        if name != current.name {
            try assertNameAvailable(name, excluding: current)
        }

        let oldURL = scriptURL(named: current.name)
        let newURL = scriptURL(named: name)
        let oldSource = current.action.scriptSource

        do {
            if oldURL.path != newURL.path, FileManager.default.fileExists(atPath: oldURL.path) {
                try moveScript(from: oldURL, to: newURL)
            }
            try writeScript(source, to: newURL)
        } catch {
            if oldURL.path != newURL.path {
                try? FileManager.default.removeItem(at: newURL)
                if let oldSource {
                    try? writeScript(oldSource, to: oldURL)
                }
            }
            throw ScriptStoreError.fileOperation(error.localizedDescription)
        }

        var updated = current
        updated.name = name
        updated.action = .runScript(script: source)
        updated.modifiedAt = Date()
        clearDeletion(for: updated.id)
        shortcuts[index] = updated
        saveToDisk()
        syncToCloud()
        scriptDirectoryIssue = nil
        return updated
    }

    func remove(id: UUID) {
        guard let shortcut = shortcuts.first(where: { $0.id == id }) else { return }
        if case .runScript = shortcut.action {
            let url = scriptURL(named: shortcut.name)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                scriptDirectoryIssue = error.localizedDescription
                return
            }
        }

        shortcuts.removeAll { $0.id == id }
        recordDeletion(id: id, at: Date())
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
        // Trigger metadata remains local-only and must not win a content merge.
        saveToDisk()
    }

    func hasConflict(keyCombo: KeyCombo, excludingID: UUID? = nil) -> Bool {
        shortcuts.contains { shortcut in
            guard let bound = shortcut.keyCombo else { return false }
            return bound == keyCombo && shortcut.id != excludingID
        }
    }

    func scriptCommand(for shortcutID: UUID) -> ScriptCommand? {
        guard
            let shortcut = shortcuts.first(where: { $0.id == shortcutID }),
            case .runScript = shortcut.action
        else { return nil }
        return ScriptCommand(fileURL: scriptURL(named: shortcut.name))
    }

    func prepareScriptsDirectory() throws -> URL {
        try ensureScriptsDirectory()
        return scriptsDirectoryURL
    }

    // MARK: - Directory Reconciliation

    /// Adopts the complete current directory state. Exposed internally for deterministic tests.
    func reconcileScriptDirectory() {
        do {
            try ensureScriptsDirectory()
            let urls = try visibleRegularFiles()
            var filesByKey: [String: URL] = [:]
            var issues: [String] = []

            for url in urls {
                let key = nameKey(url.lastPathComponent)
                if filesByKey[key] != nil {
                    issues.append("Conflicting script name: \(url.lastPathComponent)")
                    continue
                }
                filesByKey[key] = url
            }

            var changed = false
            let managedIndices = shortcuts.indices.filter {
                if case .runScript = shortcuts[$0].action { return true }
                return false
            }
            var matchedKeys: Set<String> = []

            for index in managedIndices {
                let key = nameKey(shortcuts[index].name)
                guard let url = filesByKey[key] else { continue }
                matchedKeys.insert(key)

                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    issues.append("Could not read \(url.lastPathComponent) as UTF-8")
                    continue
                }
                try ensureExecutable(url)

                if shortcuts[index].action.scriptSource != source
                    || shortcuts[index].name != url.lastPathComponent
                {
                    shortcuts[index].name = url.lastPathComponent
                    shortcuts[index].action = .runScript(script: source)
                    shortcuts[index].modifiedAt = Date()
                    changed = true
                }
            }

            for (key, url) in filesByKey where !matchedKeys.contains(key) {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    issues.append("Could not read \(url.lastPathComponent) as UTF-8")
                    continue
                }
                try ensureExecutable(url)
                shortcuts.append(
                    Shortcut(name: url.lastPathComponent, action: .runScript(script: source))
                )
                changed = true
            }

            let missingIDs = managedIndices.compactMap { index -> UUID? in
                let shortcut = shortcuts[index]
                return filesByKey[nameKey(shortcut.name)] == nil ? shortcut.id : nil
            }
            if !missingIDs.isEmpty {
                let deletionDate = Date()
                shortcuts.removeAll { missingIDs.contains($0.id) }
                for id in missingIDs {
                    recordDeletion(id: id, at: deletionDate)
                }
                changed = true
            }

            scriptDirectoryIssue = issues.first
            guard changed else { return }
            saveToDisk()
            syncToCloud()
            onExternalScriptsChanged?()
        } catch {
            scriptDirectoryIssue = error.localizedDescription
        }
    }

    private func startDirectoryMonitor() {
        directoryMonitor = ScriptDirectoryMonitor(directoryURL: scriptsDirectoryURL) { [weak self] in
            self?.scheduleDirectoryReconciliation()
        }
    }

    private func scheduleDirectoryReconciliation() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.reconcileScriptDirectory()
        }
    }

    // MARK: - Cloud Sync

    private func syncToCloud() {
        cloudSync?.upload(syncState)
    }

    private func applyRemoteChanges(_ remoteState: ShortcutSyncState) {
        reconcileScriptDirectory()
        let merged = CloudSyncService.merge(local: syncState, remote: remoteState)

        if merged != syncState {
            adoptIncomingState(merged)
            saveToDisk()
        }

        if syncState != remoteState {
            cloudSync?.upload(syncState)
        }
    }

    func performFullSync() {
        guard let cloudSync, cloudSync.isEnabled else { return }
        reconcileScriptDirectory()

        if let remote = cloudSync.download() {
            adoptIncomingState(CloudSyncService.merge(local: syncState, remote: remote))
            saveToDisk()
        }

        cloudSync.upload(syncState)
    }

    // MARK: - Disk I/O

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            apply(.empty)
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            apply(try ShortcutSyncState.decode(from: data, using: JSONDecoder()))
        } catch {
            print("TapTick: Failed to load shortcuts: \(error)")
            apply(.empty)
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(syncState)
            try data.write(to: fileURL, options: .atomic)
            loadedSchemaVersion = ShortcutSyncState.currentSchemaVersion
        } catch {
            print("TapTick: Failed to save shortcuts: \(error)")
        }
    }

    // MARK: - Import/Export

    func exportData() throws -> Data {
        reconcileScriptDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(shortcuts)
    }

    func importData(_ data: Data) throws {
        reconcileScriptDirectory()
        let importDate = Date()
        let imported = try JSONDecoder().decode([Shortcut].self, from: data).map { shortcut in
            var restored = shortcut
            restored.modifiedAt = importDate
            return restored
        }

        for shortcut in shortcuts where shortcut.action.scriptSource != nil {
            try? FileManager.default.removeItem(at: scriptURL(named: shortcut.name))
        }
        shortcuts = []
        deletions = []

        for shortcut in imported {
            addWithoutSaving(shortcut)
        }
        saveToDisk()
        syncToCloud()
    }

    // MARK: - Managed File Helpers

    private var syncState: ShortcutSyncState {
        ShortcutSyncState(shortcuts: shortcuts, deletions: deletions)
    }

    private func apply(_ state: ShortcutSyncState) {
        loadedSchemaVersion = state.schemaVersion
        shortcuts = state.shortcuts
        deletions = state.deletions
    }

    private func migrateLegacyScripts() -> Bool {
        var occupiedKeys = Set((try? visibleRegularFiles().map { nameKey($0.lastPathComponent) }) ?? [])
        var completed = true

        for index in shortcuts.indices {
            let source: String
            switch shortcuts[index].action {
            case .runScript(let inlineSource):
                source = inlineSource
            case .runScriptFile(let path, let shell):
                let expandedPath = NSString(string: path).expandingTildeInPath
                guard let fileSource = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
                    continue
                }
                if case .missing = ScriptShebang.inspect(fileSource) {
                    source = ScriptShebang.replacingShebang(
                        in: fileSource,
                        with: "#!\(shell.rawValue)"
                    )
                } else {
                    source = fileSource
                }
            case .launchApp:
                continue
            }

            do {
                let name = try uniqueName(
                    preferred: shortcuts[index].name,
                    includeStoredNames: false,
                    additionalOccupiedKeys: occupiedKeys
                )
                try writeScript(source, to: scriptURL(named: name))
                occupiedKeys.insert(nameKey(name))
                shortcuts[index].name = name
                shortcuts[index].action = .runScript(script: source)
            } catch {
                scriptDirectoryIssue = error.localizedDescription
                completed = false
            }
        }

        if completed {
            loadedSchemaVersion = ShortcutSyncState.currentSchemaVersion
        }
        return completed
    }

    private func adoptIncomingState(_ state: ShortcutSyncState) {
        let previousByID = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })
        let incomingIDs = Set(state.shortcuts.map(\.id))

        for shortcut in shortcuts where !incomingIDs.contains(shortcut.id) {
            if case .runScript = shortcut.action {
                try? FileManager.default.removeItem(at: scriptURL(named: shortcut.name))
            }
        }

        var adopted: [Shortcut] = []
        var occupiedKeys: Set<String> = []
        for var shortcut in state.shortcuts {
            guard case .runScript(let source) = shortcut.action else {
                adopted.append(shortcut)
                continue
            }

            do {
                let previous = previousByID[shortcut.id]
                let name = try uniqueName(
                    preferred: shortcut.name,
                    excludingFileName: previous?.name,
                    includeStoredNames: false,
                    additionalOccupiedKeys: occupiedKeys
                )
                let oldURL = previous.map { scriptURL(named: $0.name) }
                let newURL = scriptURL(named: name)
                if let oldURL, oldURL.path != newURL.path,
                    FileManager.default.fileExists(atPath: oldURL.path)
                {
                    try moveScript(from: oldURL, to: newURL)
                }
                try writeScript(source, to: newURL)
                shortcut.name = name
                occupiedKeys.insert(nameKey(name))
                adopted.append(shortcut)
            } catch {
                scriptDirectoryIssue = error.localizedDescription
                if let previous = previousByID[shortcut.id] {
                    adopted.append(previous)
                    occupiedKeys.insert(nameKey(previous.name))
                }
            }
        }

        shortcuts = adopted
        deletions = state.deletions
        loadedSchemaVersion = ShortcutSyncState.currentSchemaVersion
    }

    private func addWithoutSaving(_ shortcut: Shortcut) {
        var shortcut = shortcut
        do {
            switch shortcut.action {
            case .runScript(let source):
                let name = try uniqueName(preferred: shortcut.name)
                shortcut.name = name
                try writeScript(source, to: scriptURL(named: name))
            case .runScriptFile(let path, let shell):
                let expandedPath = NSString(string: path).expandingTildeInPath
                guard let fileSource = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
                    throw ScriptStoreError.unavailableLegacyFile(path)
                }
                let source: String
                if case .missing = ScriptShebang.inspect(fileSource) {
                    source = ScriptShebang.replacingShebang(
                        in: fileSource,
                        with: "#!\(shell.rawValue)"
                    )
                } else {
                    source = fileSource
                }
                let name = try uniqueName(preferred: shortcut.name)
                shortcut.name = name
                shortcut.action = .runScript(script: source)
                try writeScript(source, to: scriptURL(named: name))
            case .launchApp:
                break
            }
            shortcuts.append(shortcut)
        } catch {
            scriptDirectoryIssue = error.localizedDescription
        }
    }

    private func ensureScriptsDirectory() throws {
        try FileManager.default.createDirectory(
            at: scriptsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func visibleRegularFiles() throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(
            at: scriptsDirectoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func validatedName(_ proposedName: String) throws -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !name.isEmpty else {
            throw ScriptStoreError.invalidName("Script name is required.")
        }
        guard name != ".", name != "..", !name.hasPrefix(".") else {
            throw ScriptStoreError.invalidName("Script names cannot be hidden or relative paths.")
        }
        guard
            !name.contains("/"),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ScriptStoreError.invalidName("Script names cannot contain “/” or control characters.")
        }
        guard name.utf8.count <= 255 else {
            throw ScriptStoreError.invalidName("Script name is too long.")
        }
        return name
    }

    private func uniqueName(
        preferred: String,
        excludingFileName: String? = nil,
        includeStoredNames: Bool = true,
        additionalOccupiedKeys: Set<String> = []
    ) throws -> String {
        let base = (try? validatedName(preferred)) ?? "Untitled Script"
        let excludedKey = excludingFileName.map(nameKey)
        var occupiedKeys = additionalOccupiedKeys
        if includeStoredNames {
            occupiedKeys.formUnion(
                shortcuts.compactMap { shortcut in
                    guard shortcut.action.scriptSource != nil, shortcut.name != excludingFileName else {
                        return nil
                    }
                    return nameKey(shortcut.name)
                })
        }
        if let files = try? visibleRegularFiles() {
            occupiedKeys.formUnion(
                files.compactMap { url in
                    let key = nameKey(url.lastPathComponent)
                    return key == excludedKey ? nil : key
                })
        }

        if !occupiedKeys.contains(nameKey(base)) { return base }
        for suffix in 2...10_000 {
            let candidate = suffixedName(base, suffix: suffix)
            if !occupiedKeys.contains(nameKey(candidate)) { return candidate }
        }
        throw ScriptStoreError.fileOperation("Could not choose an available script name.")
    }

    private func suffixedName(_ name: String, suffix: Int) -> String {
        let path = name as NSString
        let pathExtension = path.pathExtension
        guard !pathExtension.isEmpty else { return "\(name) \(suffix)" }
        return "\(path.deletingPathExtension) \(suffix).\(pathExtension)"
    }

    private func assertNameAvailable(_ name: String, excluding shortcut: Shortcut) throws {
        let key = nameKey(name)
        if shortcuts.contains(where: {
            $0.id != shortcut.id && $0.action.scriptSource != nil && nameKey($0.name) == key
        }) {
            throw ScriptStoreError.nameExists(name)
        }
        if try visibleRegularFiles().contains(where: {
            $0.lastPathComponent != shortcut.name && nameKey($0.lastPathComponent) == key
        }) {
            throw ScriptStoreError.nameExists(name)
        }
    }

    private func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func scriptURL(named name: String) -> URL {
        scriptsDirectoryURL.appendingPathComponent(name, isDirectory: false)
    }

    private func writeScript(_ source: String, to url: URL) throws {
        try Data(source.utf8).write(to: url, options: .atomic)
        try ensureExecutable(url)
    }

    private func ensureExecutable(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let executablePermissions = permissions | 0o100
        guard executablePermissions != permissions else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: executablePermissions)],
            ofItemAtPath: url.path
        )
    }

    private func moveScript(from source: URL, to destination: URL) throws {
        if nameKey(source.lastPathComponent) == nameKey(destination.lastPathComponent) {
            let temporary = scriptsDirectoryURL.appendingPathComponent(".rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: source, to: temporary)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.moveItem(at: temporary, to: source)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private func recordDeletion(id: UUID, at date: Date) {
        deletions.removeAll { $0.id == id }
        deletions.append(ShortcutDeletion(id: id, deletedAt: date))
    }

    private func clearDeletion(for id: UUID) {
        deletions.removeAll { $0.id == id }
    }
}

private extension ShortcutAction {
    var scriptSource: String? {
        if case .runScript(let source) = self { return source }
        return nil
    }
}
