//
//  AppGroup.swift
//  Shared (app + widget)
//
//  App Group container access. The App Group is optional: when Sideloadly
//  signing does not provide it, `containerURL` is nil and the widget shows
//  its empty state instead of failing.
//

import Foundation

enum AppGroup {
    static let identifier = "group.com.rashid.clipstudio"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var isAvailable: Bool { containerURL != nil }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("widget-snapshot.json")
    }
}
