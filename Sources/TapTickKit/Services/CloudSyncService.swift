import Foundation
import Observation
import os.log

/// Manages bidirectional iCloud Drive sync for shortcut data.
///
/// Uses the iCloud ubiquity container (`iCloud.com.taptick.app`) to store a shared
/// `shortcuts.json` file. Monitors the file for external changes (pushed from other
/// devices) via `NSMetadataQuery` and merges them into the local store.
///
/// Merge strategy: union of all shortcuts by UUID; for conflicting UUIDs the version
/// with the later `modifiedAt` wins. This lets each device add/edit independently.
@Observable
public final class CloudSyncService: @unchecked Sendable {
    // MARK: - State

    private(set) var isSyncing = false
    private(set) var isAvailable = false
    private(set) var lastSyncDate: Date?
    private(set) var lastError: String?

    /// User preference — stored separately so it survives even when iCloud is unavailable.
    @ObservationIgnored
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { startMonitoring() } else { stopMonitoring() }
        }
    }

    // MARK: - Dependencies

    /// Callback invoked when remote changes are detected. The ShortcutStore sets this.
    var onRemoteChange: (([Shortcut]) -> Void)?

    // MARK: - Private

    private static let enabledKey = "iCloudSyncEnabled"
    private static let containerID = "iCloud.com.taptick.app"
    private static let fileName = "shortcuts.json"

    private let logger = Logger(subsystem: "com.taptick.app", category: "CloudSync")
    private var metadataQuery: NSMetadataQuery?
    private var containerURL: URL?

    // Debounce remote-change processing to avoid thrashing during bulk syncs.
    private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(500)

    public init() {
        checkAvailability()
        if isEnabled && isAvailable {
            startMonitoring()
        }
    }

    // MARK: - iCloud Container

    /// Resolve the ubiquity container URL. Returns nil when iCloud is not signed in.
    private func checkAvailability() {
        // url(forUbiquityContainerIdentifier:) returns nil when iCloud is off or unavailable.
        if let url = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID) {
            containerURL = url.appendingPathComponent("Documents", isDirectory: true)
            isAvailable = true

            // Ensure the Documents subdirectory exists.
            try? FileManager.default.createDirectory(
                at: containerURL!, withIntermediateDirectories: true
            )
        } else {
            containerURL = nil
            isAvailable = false
        }
    }

    /// Full path to the synced file inside the iCloud container.
    private var cloudFileURL: URL? {
        containerURL?.appendingPathComponent(Self.fileName)
    }

    // MARK: - Monitoring

    /// Begin watching the iCloud file for external changes.
    /// Must be called on the main thread (NSMetadataQuery requires it).
    func startMonitoring() {
        guard isAvailable, metadataQuery == nil else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Self.fileName)

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.handleMetadataQueryUpdate()
        }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.handleMetadataQueryUpdate()
        }

        query.start()
        metadataQuery = query
        logger.info("Started iCloud monitoring")
    }

    /// Stop watching.
    func stopMonitoring() {
        metadataQuery?.stop()
        metadataQuery = nil
        debounceTask?.cancel()
        debounceTask = nil
        NotificationCenter.default.removeObserver(self)
        logger.info("Stopped iCloud monitoring")
    }

    // MARK: - Upload

    /// Write the current local shortcuts to the iCloud container.
    func upload(shortcuts: [Shortcut]) {
        guard isEnabled, isAvailable, let url = cloudFileURL else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(shortcuts)

            // Use file coordination to avoid conflicts with iCloud daemon.
            var error: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { coordURL in
                do {
                    try data.write(to: coordURL, options: .atomic)
                    self.lastSyncDate = Date()
                    self.lastError = nil
                    self.logger.info("Uploaded \(shortcuts.count) shortcuts to iCloud")
                } catch {
                    self.lastError = error.localizedDescription
                    self.logger.error("Upload write failed: \(error)")
                }
            }

            if let error {
                lastError = error.localizedDescription
                logger.error("Upload coordination failed: \(error)")
            }
        } catch {
            lastError = error.localizedDescription
            logger.error("Upload encode failed: \(error)")
        }
    }

    /// Read shortcuts from the iCloud file. Returns nil if no cloud file exists.
    func download() -> [Shortcut]? {
        guard isEnabled, isAvailable, let url = cloudFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var result: [Shortcut]?
        var coordError: NSError?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                result = try decoder.decode([Shortcut].self, from: data)
            } catch {
                self.lastError = error.localizedDescription
                self.logger.error("Download failed: \(error)")
            }
        }

        if let coordError {
            lastError = coordError.localizedDescription
            logger.error("Download coordination failed: \(coordError)")
        }

        return result
    }

    // MARK: - Merge

    /// Merge remote shortcuts into local set. Returns the merged result.
    ///
    /// Rules:
    /// - New UUIDs from either side are kept.
    /// - For matching UUIDs, the version with the later `modifiedAt` wins.
    static func merge(local: [Shortcut], remote: [Shortcut]) -> [Shortcut] {
        var merged: [UUID: Shortcut] = [:]

        // Start with local.
        for shortcut in local {
            merged[shortcut.id] = shortcut
        }

        // Layer remote on top, keeping the newer version when IDs collide.
        for remoteShortcut in remote {
            if let existing = merged[remoteShortcut.id] {
                if remoteShortcut.modifiedAt > existing.modifiedAt {
                    merged[remoteShortcut.id] = remoteShortcut
                }
                // else: local is newer or equal — keep local
            } else {
                // New shortcut from another device — add it.
                merged[remoteShortcut.id] = remoteShortcut
            }
        }

        // Return sorted by creation date for stable ordering.
        return merged.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Internal

    /// Called when the metadata query detects a change to the cloud file.
    private func handleMetadataQueryUpdate() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            self?.processRemoteChange()
        }
    }

    private func processRemoteChange() {
        guard let remoteShortcuts = download() else { return }
        logger.info("Remote change detected: \(remoteShortcuts.count) shortcuts")
        lastSyncDate = Date()
        onRemoteChange?(remoteShortcuts)
    }
}
