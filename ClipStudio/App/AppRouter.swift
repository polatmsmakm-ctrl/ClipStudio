//
//  AppRouter.swift
//  ClipStudio — App
//
//  Navigation state: top-level sections (sidebar on iPad, tabs on iPhone), a
//  navigation stack per section, and the full-screen Pro Studio editor.
//  Pushing `.studio(id)` opens the editor full screen instead of a stack page,
//  so every "open project" call site works for Pro Studio projects too.
//  Part 4 routes: templates workspace, editing styles, on-device AI model.
//  Part 5 routes: AI studio and AI settings.
//

import Foundation
import SwiftUI
import UIKit

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, studio, stories, merge, batch, media, projects, exports, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "الرئيسية"
        case .studio: "الاستوديو"
        case .stories: "القصص الذكية"
        case .merge: "الدمج الذكي"
        case .batch: "المعالجة الدفعية"
        case .media: "الوسائط"
        case .projects: "المشاريع"
        case .exports: "التصدير"
        case .settings: "الإعدادات"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .studio: "film.stack"
        case .stories: "scissors"
        case .merge: "rectangle.stack.badge.plus"
        case .batch: "square.stack.3d.down.right"
        case .media: "photo.on.rectangle.angled"
        case .projects: "folder"
        case .exports: "square.and.arrow.up.on.square"
        case .settings: "gearshape"
        }
    }

    /// Sections shown as tabs on iPhone (the rest are reached from these).
    static let compactTabs: [AppSection] = [.dashboard, .studio, .stories, .exports, .settings]
}

enum Route: Hashable {
    case story(UUID)
    case storyGallery(UUID)
    case merge(UUID)
    case mergeHome
    case batch
    case projects
    case versions(UUID)
    case exports
    case platformPresets
    case presetEditor(UUID)
    case storage
    case backup
    case exportDefaults
    case studio(UUID)
    case studioHub
    case mediaLibrary
    case lutLibrary
    case studioPreferences
    // Part 4
    case templates
    case editingStyles
    case onDeviceAI
    // Part 5
    case aiStudio
    case aiSettings
    // Part 6
    case performance
    case series
}

/// Identifies the project shown in the full-screen editor.
struct StudioPresentation: Identifiable, Hashable {
    let id: UUID
}

@MainActor
@Observable
final class AppRouter {
    var section: AppSection = .dashboard
    var paths: [AppSection: [Route]] = [:]
    /// A .csbackup file opened from the Files app, waiting for confirmation in Settings.
    var pendingBackupURL: URL? = nil
    /// The Pro Studio editor (full screen) when a project is open.
    var studio: StudioPresentation? = nil

    func path(for section: AppSection) -> Binding<[Route]> {
        Binding(get: { self.paths[section] ?? [] },
                set: { self.paths[section] = $0 })
    }

    /// iPad: selects the sidebar section. iPhone: selects the owning tab and,
    /// for sections without their own tab, pushes the section screen.
    func select(_ target: AppSection) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            section = target
        } else {
            section = Self.tabSection(for: target)
            if let route = Self.route(for: target) {
                paths[section] = [route]
            }
        }
    }

    /// Pushes onto the currently visible section's stack. `.studio` opens the editor full screen.
    func push(_ route: Route) {
        if case .studio(let id) = route {
            openStudio(id)
            return
        }
        paths[section, default: []].append(route)
    }

    func popToRoot() {
        paths[section] = []
    }

    func openStudio(_ projectID: UUID) {
        studio = StudioPresentation(id: projectID)
    }

    func closeStudio() {
        studio = nil
    }

    private static func tabSection(for section: AppSection) -> AppSection {
        switch section {
        case .merge, .batch: .stories
        case .projects, .media: .dashboard
        default: section
        }
    }

    private static func route(for section: AppSection) -> Route? {
        switch section {
        case .merge: .mergeHome
        case .batch: .batch
        case .projects: .projects
        case .media: .mediaLibrary
        default: nil
        }
    }
}
