import CloudKit
import Foundation

/// Durable inbox/outbox and transport cursor. A fetched snapshot survives failed script adoption.
struct CloudSyncSnapshot: Codable {
    var version = 1
    var account: String?
    var library = ShortcutSyncState.empty
    var acknowledged: ShortcutSyncState?
    var recordFields: Data?
    var engineState: CKSyncEngine.State.Serialization?

    static let zoneID = CKRecordZone.ID(zoneName: "Shortcuts")
    static let recordID = CKRecord.ID(recordName: "library", zoneID: zoneID)

    var needsUpload: Bool { library != acknowledged }

    static func read(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let snapshot = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        try snapshot.library.validate()
        try snapshot.acknowledged?.validate()
        return snapshot
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func portable(_ library: ShortcutSyncState) -> ShortcutSyncState {
        var result = library
        for index in result.shortcuts.indices { result.shortcuts[index].lastTriggeredAt = nil }
        return CloudSyncService.merge(local: .empty, remote: result)
    }

    mutating func merge(_ incoming: ShortcutSyncState) throws {
        try incoming.validate()
        library = CloudSyncService.merge(local: library, remote: Self.portable(incoming))
    }

    mutating func receive(_ record: CKRecord) throws {
        let remote = try Self.decode(record)
        try merge(remote)
        acknowledge(record, library: remote)
    }

    mutating func acknowledge(_ record: CKRecord, library: ShortcutSyncState) {
        acknowledged = library
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        recordFields = archiver.encodedData
    }

    static func decode(_ record: CKRecord) throws -> ShortcutSyncState {
        guard record.recordID == recordID, record.recordType == "ShortcutLibrary",
            let version = record["schemaVersion"] as? Int, version == 1,
            let asset = record["payload"] as? CKAsset, let url = asset.fileURL
        else { throw CocoaError(.coderReadCorrupt) }
        let library = try ShortcutSyncState.decode(from: Data(contentsOf: url), using: JSONDecoder())
        return portable(library)
    }

    func record(assetURL: URL) throws -> CKRecord {
        let record: CKRecord
        if let recordFields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: recordFields)
            decoder.requiresSecureCoding = true
            defer { decoder.finishDecoding() }
            guard let restored = CKRecord(coder: decoder), restored.recordID == Self.recordID else {
                throw CocoaError(.coderReadCorrupt)
            }
            record = restored
        } else {
            record = CKRecord(recordType: "ShortcutLibrary", recordID: Self.recordID)
        }
        try JSONEncoder().encode(library).write(to: assetURL, options: .atomic)
        record["schemaVersion"] = 1
        record["payload"] = CKAsset(fileURL: assetURL)
        return record
    }
}
