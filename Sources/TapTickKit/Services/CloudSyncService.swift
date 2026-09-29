import AppKit
import CloudKit
import Foundation
import Observation
import Network
import Security

/// Owns CloudKit transport; ShortcutStore remains the local library and script-file authority.
/// The durable snapshot retains remote data even if local script adoption fails.
@MainActor
@Observable
public final class CloudSyncService: CKSyncEngineDelegate {
    private var isFetching = false
    private var isSending = false
    var isSyncing: Bool { isFetching || isSending }
    private(set) var isAvailable = false
    private(set) var lastSyncDate: Date?
    private(set) var lastError: String?
    private(set) var accountChanged = false
    private(set) var hasPendingChanges = false

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { refresh() } else { stop() }
        }
    }

    @ObservationIgnored var onRemoteChange: ((ShortcutSyncState) throws -> Void)?
    @ObservationIgnored var localState: (() throws -> ShortcutSyncState)?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var snapshot = CloudSyncSnapshot()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private let networkMonitor = NWPathMonitor()
    @ObservationIgnored private var assets: [URL] = []
    @ObservationIgnored private var fatalError = false
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var sendingLibrary: ShortcutSyncState?
    private let cacheURL: URL
    private static let enabledKey = "iCloudSyncEnabled"
    private let containerID = "iCloud." + TapTickRuntimeConfiguration.current.bundleIdentifier

    public init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(TapTickRuntimeConfiguration.current.appSupportDirectoryName)
            .appendingPathComponent("CloudKit/sync.json")
    }

    /// Called after the store is connected and AppKit has finished launching.
    public func start() {
        guard container == nil else { return }
        // CloudKit raises an exception without signed container entitlements (including unit tests).
        guard hasCloudKitEntitlement else {
            lastError = "This build is missing its CloudKit signing profile."
            return
        }
        do { snapshot = try CloudSyncSnapshot.read(from: cacheURL) } catch {
            fail(error)
            return
        }
        isAvailable = true
        container = CKContainer(identifier: containerID)
        NSApplication.shared.registerForRemoteNotifications()
        accountTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard let self else { return }
                self.stop()
                if self.isEnabled { self.refresh() }
            }
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
        networkMonitor.start(queue: .main)
        if isEnabled { refresh() }
    }

    deinit {
        refreshTask?.cancel()
        accountTask?.cancel()
        networkMonitor.cancel()
    }

    private var hasCloudKitEntitlement: Bool {
        var code: SecCode?
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let info = information as? [String: Any],
            let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            let identifiers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return false }
        return identifiers.contains(containerID)
    }

    private func stop() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        let old = engine
        engine = nil
        isFetching = false
        isSending = false
        Task { await old?.cancelOperations() }
    }

    func useCurrentAccount() {
        guard accountChanged else { return }
        stop()
        snapshot = CloudSyncSnapshot()
        accountChanged = false
        do { try persist() } catch { fail(error); return }
        refresh()
    }

    private func refresh() {
        guard isEnabled, let container, !fatalError, refreshTask == nil else { return }
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.refreshGeneration == generation { self.refreshTask = nil } }
            do {
                let account = try await container.userRecordID().recordName
                try Task.checkCancellation()
                guard self.isEnabled else { return }
                if let previous = self.snapshot.account, previous != account {
                    self.stop()
                    self.accountChanged = true
                    self.lastError =
                        "The iCloud account changed. Choose whether to merge this Mac's shortcuts into the current account."
                    return
                }
                self.snapshot.account = account
                self.accountChanged = false
                guard let localState = self.localState else { return }
                try self.snapshot.merge(localState())
                try self.persist()
                try self.adoptRemote()
                if self.engine == nil {
                    let configuration = CKSyncEngine.Configuration(
                        database: container.privateCloudDatabase,
                        stateSerialization: self.snapshot.engineState,
                        delegate: self)
                    self.engine = CKSyncEngine(configuration)
                }
                guard let engine = self.engine else { return }
                self.queueUpload(engine)
                try await engine.fetchChanges()
                try Task.checkCancellation()
                guard self.engine === engine else { return }
                try await engine.sendChanges()
                guard self.engine === engine else { return }
                if !self.snapshot.needsUpload, self.lastError == nil { self.lastSyncDate = Date() }
            } catch is CancellationError {
                // Turning sync off leaves the durable outbox intact.
            } catch {
                guard self.refreshGeneration == generation else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func syncNow() {
        guard isEnabled else { return }
        if fatalError {
            do {
                snapshot = try CloudSyncSnapshot.read(from: cacheURL)
                fatalError = false
            } catch { lastError = error.localizedDescription; return }
        }
        refresh()
    }

    func upload(_ state: ShortcutSyncState) {
        guard isEnabled, !fatalError, !accountChanged, snapshot.account != nil else { return }
        do {
            try snapshot.merge(state)
            try persist()
            if let engine { queueUpload(engine) }
        } catch { fail(error) }
    }

    private func persist() throws {
        try snapshot.write(to: cacheURL)
        hasPendingChanges = snapshot.needsUpload
    }

    private func adoptRemote() throws {
        guard let onRemoteChange else { throw CocoaError(.fileWriteUnknown) }
        try onRemoteChange(snapshot.library)
        lastError = nil
    }

    private func queueUpload(_ engine: CKSyncEngine) {
        guard snapshot.needsUpload else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(CloudSyncSnapshot.recordID)])
            return
        }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSnapshot.zoneID))])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(CloudSyncSnapshot.recordID)])
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        fatalError = true
        stop()
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine, !fatalError else { return }
        do {
            switch event {
            case .stateUpdate(let event):
                snapshot.engineState = event.stateSerialization
                try persist()
            case .accountChange(let event):
                switch event.changeType {
                case .signIn(let currentUser):
                    if currentUser.recordName != snapshot.account {
                        stop()
                        accountChanged = true
                        lastError = "iCloud account changed. Sync is paused; local shortcuts are preserved."
                    }
                case .signOut, .switchAccounts:
                    stop()
                    accountChanged = true
                    lastError = "iCloud account changed. Sync is paused; local shortcuts are preserved."
                @unknown default: stop()
                }
            case .fetchedRecordZoneChanges(let event):
                for modification in event.modifications where modification.record.recordID == CloudSyncSnapshot.recordID
                {
                    try snapshot.receive(modification.record)
                    try persist()
                    do { try adoptRemote() } catch { lastError = error.localizedDescription }
                    queueUpload(syncEngine)
                }
                if event.deletions.contains(where: { $0.recordID == CloudSyncSnapshot.recordID }) {
                    try resetServerRecord(syncEngine)
                }
            case .fetchedDatabaseChanges(let event):
                if event.deletions.contains(where: { $0.zoneID == CloudSyncSnapshot.zoneID }) {
                    try resetServerRecord(syncEngine)
                }
            case .sentRecordZoneChanges(let event):
                for record in event.savedRecords where record.recordID == CloudSyncSnapshot.recordID {
                    guard let sendingLibrary else { throw CocoaError(.coderReadCorrupt) }
                    snapshot.acknowledge(record, library: sendingLibrary)
                    try persist()
                    queueUpload(syncEngine)
                    if !snapshot.needsUpload, lastError == nil { lastSyncDate = Date() }
                }
                for failure in event.failedRecordSaves {
                    switch failure.error.code {
                    case .serverRecordChanged:
                        // Fetch the full asset; conflict error records may omit asset contents.
                        guard let container else { return }
                        let record = try await container.privateCloudDatabase.record(for: CloudSyncSnapshot.recordID)
                        guard engine === syncEngine else { return }
                        try snapshot.receive(record)
                        try persist()
                        do { try adoptRemote() } catch { lastError = error.localizedDescription }
                        queueUpload(syncEngine)
                    case .zoneNotFound, .unknownItem:
                        try resetServerRecord(syncEngine)
                    default:
                        lastError = failure.error.localizedDescription
                    }
                }
            case .sentDatabaseChanges(let event):
                if let failure = event.failedZoneSaves.first { lastError = failure.error.localizedDescription }
            case .willFetchChanges:
                isFetching = true
            case .willSendChanges:
                isSending = true
            case .didFetchRecordZoneChanges(let event):
                if let error = event.error {
                    lastError = error.localizedDescription
                } else if event.zoneID == CloudSyncSnapshot.zoneID, !snapshot.needsUpload, lastError == nil {
                    lastSyncDate = Date()
                }
            case .didFetchChanges:
                isFetching = false
            case .didSendChanges:
                isSending = false
                for url in assets { try? FileManager.default.removeItem(at: url) }
                assets.removeAll()
            case .willFetchRecordZoneChanges: break
            @unknown default: break
            }
        } catch let error as CKError {
            // A conflict asset fetch may fail offline; keep the outbox for the engine's next retry.
            lastError = error.localizedDescription
            queueUpload(syncEngine)
        } catch { fail(error) }
    }

    private func resetServerRecord(_ engine: CKSyncEngine) throws {
        // A CloudKit zone reset is not a user shortcut deletion; retain the local library.
        snapshot.recordFields = nil
        snapshot.acknowledged = nil
        try persist()
        queueUpload(engine)
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine, !fatalError, isEnabled, !accountChanged,
            context.options.scope.contains(.saveRecord(CloudSyncSnapshot.recordID)), snapshot.needsUpload
        else { return nil }
        do {
            let url = cacheURL.deletingLastPathComponent().appendingPathComponent("asset-\(UUID()).json")
            let record = try snapshot.record(assetURL: url)
            assets.append(url)
            sendingLibrary = snapshot.library
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: [record], recordIDsToDelete: [])
        } catch { fail(error); return nil }
    }
    // MARK: - Merge

    /// Merge local and remote state using the newest event for each shortcut ID.
    ///
    /// Rules:
    /// - The later `modifiedAt` wins between live shortcuts with the same ID.
    /// - The later `deletedAt` wins between deletion records with the same ID.
    /// - A deletion wins when its timestamp is equal to or later than the live edit.
    nonisolated static func merge(local: ShortcutSyncState, remote: ShortcutSyncState) -> ShortcutSyncState {
        var shortcutsByID: [UUID: Shortcut] = [:]
        var deletionsByID: [UUID: ShortcutDeletion] = [:]

        for shortcut in local.shortcuts + remote.shortcuts {
            if let existing = shortcutsByID[shortcut.id] {
                if existing.modifiedAt > shortcut.modifiedAt { continue }
                if existing.modifiedAt == shortcut.modifiedAt {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    var first = existing
                    var second = shortcut
                    first.lastTriggeredAt = nil
                    second.lastTriggeredAt = nil
                    let firstData = (try? encoder.encode(first)) ?? Data()
                    let secondData = (try? encoder.encode(second)) ?? Data()
                    if !firstData.lexicographicallyPrecedes(secondData) { continue }
                }
            }
            shortcutsByID[shortcut.id] = shortcut
        }

        for deletion in local.deletions + remote.deletions {
            if let existing = deletionsByID[deletion.id], existing.deletedAt >= deletion.deletedAt {
                continue
            }
            deletionsByID[deletion.id] = deletion
        }

        for (id, deletion) in deletionsByID {
            guard let shortcut = shortcutsByID[id] else { continue }
            if shortcut.modifiedAt > deletion.deletedAt {
                deletionsByID[id] = nil
            } else {
                shortcutsByID[id] = nil
            }
        }

        return ShortcutSyncState(
            schemaVersion: max(
                ShortcutSyncState.currentSchemaVersion,
                local.schemaVersion,
                remote.schemaVersion
            ),
            shortcuts: shortcutsByID.values.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt < $1.createdAt
            },
            deletions: deletionsByID.values.sorted {
                if $0.deletedAt == $1.deletedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.deletedAt < $1.deletedAt
            }
        )
    }

}
