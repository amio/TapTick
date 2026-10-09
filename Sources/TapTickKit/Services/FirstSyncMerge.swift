import Foundation

/// Reconciles independently created scripts only while a Mac first joins an account.
/// Cloud IDs remain canonical; ordinary sync continues to merge by UUID alone.
struct FirstSyncMerge {
    struct Summary: Codable, Equatable, Sendable {
        var identicalScripts: Int
        var keptBothPairs: Int
    }

    let library: ShortcutSyncState
    let replacements: [UUID: UUID]
    let summary: Summary

    init(local: ShortcutSyncState, remote: ShortcutSyncState, now: Date = Date()) {
        var merged = CloudSyncService.merge(local: local, remote: remote)
        let localIDs = Set(local.shortcuts.map(\.id))
        let remoteIDs = Set(remote.shortcuts.map(\.id))
        let scripts = merged.shortcuts.filter {
            if case .runScript = $0.action { return true }
            return false
        }
        let groups = Dictionary(grouping: scripts, by: { ShortcutStore.scriptNameKey($0.name) })
        var replacements: [UUID: UUID] = [:]
        var keptBoth = 0
        for group in groups.values {
            guard group.count == 2,
                let local = group.first(where: { localIDs.contains($0.id) && !remoteIDs.contains($0.id) }),
                let remote = group.first(where: { remoteIDs.contains($0.id) && !localIDs.contains($0.id) }),
                case .runScript(let first) = local.action, case .runScript(let second) = remote.action
            else { continue }
            guard first.utf8.elementsEqual(second.utf8), local.keyCombo == remote.keyCombo,
                local.isEnabled == remote.isEnabled
            else { keptBoth += 1; continue }
            // Match import restoration's whole-second boundary, including clocks ahead of this Mac.
            let latest = max(local.modifiedAt, remote.modifiedAt)
            let eventDate = max(now, Date(timeIntervalSince1970: floor(latest.timeIntervalSince1970) + 1))
            merged.shortcuts.removeAll { $0.id == local.id }
            merged.deletions.removeAll { $0.id == local.id }
            merged.deletions.append(ShortcutDeletion(id: local.id, deletedAt: eventDate))
            replacements[local.id] = remote.id
        }
        library = CloudSyncSnapshot.portable(merged)
        self.replacements = replacements
        summary = Summary(identicalScripts: replacements.count, keptBothPairs: keptBoth)
    }

}

/// Retained until adoption and the first server acknowledgment have succeeded.
struct FirstSyncSession: Codable {
    var hasFetched = false
    var hasAdopted = false
}
