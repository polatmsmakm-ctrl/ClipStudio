//
//  ClipStudioApp.swift
//  ClipStudio — App entry point
//
//  Opens straight into the main workspace (no login/onboarding).
//  Global: Arabic RTL layout, English digits, dark theme, studio-gold tint.
//

import SwiftUI
import UIKit

@main
struct ClipStudioApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment = AppEnvironment()

    init() {
        // RTL for UIKit-backed chrome (navigation bars, sheets, alerts).
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.titleTextAttributes = [.foregroundColor: UIColor(Theme.Palette.textPrimary)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.Palette.textPrimary)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Fmt.arabicLatin)
                .preferredColorScheme(.dark)
                .tint(Theme.Palette.accent)
                .toastOverlay(environment.toasts)
                .onOpenURL { environment.handleOpenURL($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.handleScenePhase(phase)
        }
    }
}
