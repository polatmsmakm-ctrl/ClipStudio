//
//  ContentStore.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Keeps the latest Content Studio pack of each project (titles, captions,
//  hashtags per platform) in State/AIContent/<project>.json so edits survive
//  relaunches and are part of backups.
//

import Foundation

enum ContentStore {
    static var directory: URL { StorageManager.shared.stateDirectory.appendingPathComponent("AIContent", isDirectory: true) }

    static func url(_ projectID: UUID) -> URL { directory.appendingPathComponent(projectID.uuidString + ".json") }

    static func load(_ projectID: UUID) -> ContentPack? {
        JSONStore.load(ContentPack.self, from: url(projectID))
    }

    static func save(_ pack: ContentPack) {
        try? JSONStore.save(pack, to: url(pack.projectID))
    }

    static func delete(_ projectID: UUID) {
        try? FileManager.default.removeItem(at: url(projectID))
    }
}
