//
//  Feedback.swift
//  ClipStudio — Components
//
//  Toasts, empty states and the system share sheet.
//

import SwiftUI
import UIKit

// MARK: - Toasts

enum ToastStyle {
    case info, success, warning, error

    var color: Color {
        switch self {
        case .info: Theme.Palette.accent
        case .success: Theme.Palette.success
        case .warning: Theme.Palette.warning
        case .error: Theme.Palette.danger
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let style: ToastStyle

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

@MainActor
@Observable
final class ToastCenter {
    private(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, style: ToastStyle = .info, duration: Double = 2.6) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            current = ToastMessage(text: text, style: style)
        }
        // Part 6: VoiceOver users hear every toast.
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        switch style {
        case .success: Haptics.success()
        case .warning: Haptics.warning()
        case .error: Haptics.error()
        case .info: break
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
    }
}

struct ToastOverlay: ViewModifier {
    let center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.style.symbol).foregroundStyle(toast.style.color)
                    Text(toast.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(Theme.Palette.stroke)))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .padding(.top, 8)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { center.dismiss() }
                .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}

extension View {
    func toastOverlay(_ center: ToastCenter) -> some View { modifier(ToastOverlay(center: center)) }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 92, height: 92)
                .background(Circle().fill(Theme.Palette.accentSoft))
            Text(title).font(.title3.weight(.bold)).foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.csPrimary)
                    .frame(maxWidth: 280)
                    .padding(.top, 4)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Opens the Files app at a file inside the app's Documents folder.
enum FilesAppLink {
    /// Opens the folder containing `url`.
    static func open(_ url: URL) {
        openFolder(url.deletingLastPathComponent())
    }

    static func openFolder(_ directory: URL) {
        let path = directory.path
        if let link = URL(string: "shareddocuments://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)) {
            UIApplication.shared.open(link)
        }
    }
}
