//
//  WidgetSnapshot.swift
//  Shared (app + widget)
//
//  Small JSON snapshot the app writes into the App Group for the widget:
//  export queue status, last export and recent projects.
//

import Foundation

struct WidgetSnapshot: Codable {
    struct ActiveExport: Codable {
        var title: String
        var progress: Double
        var statusText: String
    }

    struct RecentProject: Codable, Identifiable {
        var id: UUID
        var name: String
        var symbol: String
        var modifiedAt: Date
    }

    var updatedAt: Date
    var activeExport: ActiveExport?
    var queuedCount: Int
    var completedToday: Int
    var lastExportTitle: String?
    var lastExportDate: Date?
    var recentProjects: [RecentProject]

    static let empty = WidgetSnapshot(updatedAt: Date(), activeExport: nil, queuedCount: 0, completedToday: 0,
                                      lastExportTitle: nil, lastExportDate: nil, recentProjects: [])

    static func load() -> WidgetSnapshot? {
        guard let url = AppGroup.snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    @discardableResult
    func save() -> Bool {
        guard let url = AppGroup.snapshotURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
