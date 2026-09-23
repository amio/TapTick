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
    private enum WriteBlock {
        case unreadable(String)
        case incompleteRollback(String)

        var message: String {
            switch self {
            case .unreadable(let message), .incompleteRollback(let message): return message
            }
        }
    }
    private var writeBlock: WriteBlock?
    var loadIssue: String? { writeBlock?.message }
    var canRetryLoading: Bool {
        if case .incompleteRollback = writeBlock { return false }
        return true
    }

    // MARK: - Persistence

    let scriptsDirectoryURL: URL

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let cloudSync: CloudSyncService?
    @ObservationIgnored private var directoryMonitor: ScriptDirectoryMonitor?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?

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

        reloadFromDisk()
    }

    /// An unreadable library is never a new empty library. All mutation entry points share this gate.
    private var canWrite: Bool { loadIssue == nil }

    private func requireWritable() throws {
        if let loadIssue { throw ScriptStoreError.fileOperation(loadIssue) }
    }

    func reloadFromDisk() {
        guard canRetryLoading else { return }
        reconcileTask?.cancel()
        reconcileTask = nil
        directoryMonitor = nil
        cloudSync?.onRemoteChange = nil
        do {
            let state = try loadFromDisk()
            try ensureScriptsDirectory()
            writeBlock = nil
            scriptDirectoryIssue = nil
            if state.schemaVersion < ShortcutSyncState.currentSchemaVersion {
                let migrated = try prepareLegacyMigration(state)
                try commitScriptFiles(migrated, replacing: [])
                apply(migrated)
            } else {
                apply(state)
            }
            reconcileScriptDirectory()
            try writeState(syncState)
            startDirectoryMonitor()
            setupCloudSync()
        } catch {
            if canRetryLoading { writeBlock = .unreadable(error.localizedDescription) }
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
        guard canWrite else { return }
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
        try requireWritable()
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
        guard canWrite else { return }
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
        try requireWritable()
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
        guard canWrite else { return }
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
        guard canWrite else { return }
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].isEnabled.toggle()
        shortcuts[index].modifiedAt = Date()
        saveToDisk()
        syncToCloud()
    }

    func markTriggered(id: UUID) {
        guard canWrite else { return }
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
        try requireWritable()
        try ensureScriptsDirectory()
        return scriptsDirectoryURL
    }

    // MARK: - Directory Reconciliation

    /// Adopts the complete current directory state. Exposed internally for deterministic tests.
    func reconcileScriptDirectory() {
        guard canWrite else { return }
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
        guard canWrite else { return }
        cloudSync?.upload(syncState)
    }

    private func applyRemoteChanges(_ remoteState: ShortcutSyncState) {
        guard canWrite else { return }
        do {
            try remoteState.validate()
            reconcileScriptDirectory()
            let merged = CloudSyncService.merge(local: syncState, remote: remoteState)
            if merged != syncState {
                adoptIncomingState(merged)
                saveToDisk()
            }
            if syncState != remoteState { syncToCloud() }
        } catch {
            scriptDirectoryIssue = error.localizedDescription
        }
    }

    func performFullSync() {
        guard canWrite, let cloudSync, cloudSync.isEnabled else { return }
        do {
            let remote = try cloudSync.download()
            try remote?.validate()
            reconcileScriptDirectory()
            if let remote {
                adoptIncomingState(CloudSyncService.merge(local: syncState, remote: remote))
                saveToDisk()
            }
            cloudSync.upload(syncState)
        } catch {
            scriptDirectoryIssue = error.localizedDescription
        }
    }

    // MARK: - Disk I/O

    private func loadFromDisk() throws -> ShortcutSyncState {
        do {
            let data = try Data(contentsOf: fileURL)
            return try ShortcutSyncState.decode(from: data, using: JSONDecoder())
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        }
    }

    private func writeState(_ state: ShortcutSyncState) throws {
        try requireWritable()
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    private func saveToDisk() {
        guard canWrite else { return }
        do {
            try writeState(syncState)
        } catch {
            scriptDirectoryIssue = error.localizedDescription
        }
    }

    // MARK: - Import/Export

    func exportData() throws -> Data {
        try requireWritable()
        reconcileScriptDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(shortcuts)
    }

    func importData(_ data: Data) throws {
        try requireWritable()
        var imported = try JSONDecoder().decode([Shortcut].self, from: data)
        try ShortcutSyncState(shortcuts: imported, deletions: []).validate()

        // Cloud dates have whole-second precision. Restoration must survive its round trip,
        // including when a known edit or deletion is ahead of this machine's clock.
        let latestEvent = (shortcuts + imported).map(\.modifiedAt) + deletions.map(\.deletedAt)
        let nextKnownSecond = floor((latestEvent.max() ?? .distantPast).timeIntervalSince1970) + 1
        let importDate = max(Date(), Date(timeIntervalSince1970: nextKnownSecond))
        for index in imported.indices {
            if case .runScriptFile(let path, let shell) = imported[index].action {
                imported[index].action = .runScript(script: try legacySource(at: path, shell: shell))
            }
            imported[index].modifiedAt = importDate
        }

        let managedNames = Set(shortcuts.filter { $0.action.scriptSource != nil }.map { nameKey($0.name) })
        let originals = try visibleRegularFiles().filter { managedNames.contains(nameKey($0.lastPathComponent)) }
        let replacedNames = Set(originals.map { nameKey($0.lastPathComponent) })
        let entries = try FileManager.default.contentsOfDirectory(atPath: scriptsDirectoryURL.path)
        var occupied = Set(entries.map(nameKey)).subtracting(replacedNames)
        for index in imported.indices where imported[index].action.scriptSource != nil {
            let name = try availableName(preferred: imported[index].name, occupiedKeys: occupied)
            imported[index].name = name
            occupied.insert(nameKey(name))
        }

        let importedIDs = Set(imported.map(\.id))
        let removedIDs = Set(shortcuts.map(\.id)).subtracting(importedIDs)
        let retainedDeletions = deletions.filter { !importedIDs.contains($0.id) && !removedIDs.contains($0.id) }
        let state = ShortcutSyncState(
            shortcuts: imported,
            deletions: retainedDeletions + removedIDs.map { ShortcutDeletion(id: $0, deletedAt: importDate) }
        )
        try commitScriptFiles(state, replacing: originals)
        apply(state)
        syncToCloud()
    }

    /// Metadata is the commit point. Until it succeeds, the published library stays unchanged.
    /// This supports I/O rollback, not crash-atomic replacement across multiple files.
    private func commitScriptFiles(_ state: ShortcutSyncState, replacing originals: [URL]) throws {
        let files = FileManager.default
        let staging = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".shortcut-import-\(UUID().uuidString)")
        let prepared = staging.appendingPathComponent("prepared", isDirectory: true)
        let backup = staging.appendingPathComponent("originals", isDirectory: true)
        var preserveBackup = false
        defer {
            if !preserveBackup { try? files.removeItem(at: staging) }
        }
        try files.createDirectory(at: prepared, withIntermediateDirectories: true)
        try files.createDirectory(at: backup, withIntermediateDirectories: true)
        if files.fileExists(atPath: fileURL.path) {
            try files.copyItem(at: fileURL, to: staging.appendingPathComponent("shortcuts.json"))
        }
        let scripts = state.shortcuts.filter { $0.action.scriptSource != nil }
        for script in scripts {
            try writeScript(script.action.scriptSource!, to: prepared.appendingPathComponent(script.name))
        }

        var movedOriginals: [URL] = []
        var installed: [URL] = []
        do {
            for original in originals {
                try files.moveItem(at: original, to: backup.appendingPathComponent(original.lastPathComponent))
                movedOriginals.append(original)
            }
            for script in scripts {
                let destination = scriptURL(named: script.name)
                try files.moveItem(at: prepared.appendingPathComponent(script.name), to: destination)
                installed.append(destination)
            }
            try writeState(state)
        } catch {
            let commitError = error
            var rollbackFailed = false
            for url in installed.reversed() {
                do { try files.removeItem(at: url) } catch { rollbackFailed = true }
            }
            for original in movedOriginals.reversed() {
                do {
                    try files.moveItem(at: backup.appendingPathComponent(original.lastPathComponent), to: original)
                } catch { rollbackFailed = true }
            }
            if rollbackFailed {
                preserveBackup = true
                let message =
                    "Import failed and some original files could not be restored. Recover them from \(staging.path) before reopening TapTick. \(commitError.localizedDescription)"
                writeBlock = .incompleteRollback(message)
                throw ScriptStoreError.fileOperation(message)
            }
            throw commitError
        }
        scriptDirectoryIssue = nil
        do { try files.removeItem(at: staging) } catch {
            preserveBackup = true
            scriptDirectoryIssue = "Import succeeded, but its temporary backup could not be removed: \(staging.path)"
        }
    }

    // MARK: - Managed File Helpers

    private var syncState: ShortcutSyncState {
        ShortcutSyncState(shortcuts: shortcuts, deletions: deletions)
    }

    private func apply(_ state: ShortcutSyncState) {
        shortcuts = state.shortcuts
        deletions = state.deletions
    }

    private func prepareLegacyMigration(_ state: ShortcutSyncState) throws -> ShortcutSyncState {
        var migrated = state
        var occupied = Set(try FileManager.default.contentsOfDirectory(atPath: scriptsDirectoryURL.path).map(nameKey))
        for index in migrated.shortcuts.indices {
            let source: String
            switch migrated.shortcuts[index].action {
            case .runScript(let inlineSource): source = inlineSource
            case .runScriptFile(let path, let shell):
                // Unavailable external files retain their legacy record for compatibility.
                guard let legacySource = try? legacySource(at: path, shell: shell) else { continue }
                source = legacySource
            case .launchApp: continue
            }
            let name = try availableName(preferred: migrated.shortcuts[index].name, occupiedKeys: occupied)
            occupied.insert(nameKey(name))
            migrated.shortcuts[index].name = name
            migrated.shortcuts[index].action = .runScript(script: source)
        }
        migrated.schemaVersion = ShortcutSyncState.currentSchemaVersion
        return migrated
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
    }

    private func legacySource(at path: String, shell: ShortcutAction.LegacyShell) throws -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let source = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            throw ScriptStoreError.unavailableLegacyFile(path)
        }
        if case .missing = ScriptShebang.inspect(source) {
            return ScriptShebang.replacingShebang(in: source, with: "#!\(shell.rawValue)")
        }
        return source
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

        return try availableName(preferred: preferred, occupiedKeys: occupiedKeys)
    }

    private func availableName(preferred: String, occupiedKeys: Set<String>) throws -> String {
        let base = (try? validatedName(preferred)) ?? "Untitled Script"
        if !occupiedKeys.contains(nameKey(base)) { return base }
        for suffix in 2...10_000 {
            let candidate = try validatedName(suffixedName(base, suffix: suffix))
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
