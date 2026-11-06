//
//  MediaImportControls.swift
//  ClipStudio — Features/Media
//
//  Reusable import entry points (Photos + Files) with progress and result toasts.
//

import SwiftUI
import PhotosUI

struct MediaImportModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var showPhotos: Bool
    @Binding var showFiles: Bool
    var onImported: ([MediaAsset]) -> Void

    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 50,
                          matching: .any(of: [.videos, .images]))
            .fileImporter(isPresented: $showFiles, allowedContentTypes: MediaImportManager.fileTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        let report = await env.importer.importFiles(urls)
                        finish(report)
                    }
                case .failure(let error):
                    env.toasts.show(error.localizedDescription, style: .error)
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    let report = await env.importer.importFromPhotos(items)
                    photoItems = []
                    finish(report)
                }
            }
    }

    private func finish(_ report: ImportReport) {
        let style: ToastStyle = report.failures.isEmpty ? (report.added.isEmpty ? .info : .success) : .warning
        env.toasts.show(report.summary, style: style)
        onImported(report.all)
    }
}

extension View {
    func mediaImport(showPhotos: Binding<Bool>, showFiles: Binding<Bool>,
                     onImported: @escaping ([MediaAsset]) -> Void = { _ in }) -> some View {
        modifier(MediaImportModifier(showPhotos: showPhotos, showFiles: showFiles, onImported: onImported))
    }
}

/// "+" menu offering Photos or Files import.
struct ImportMenu: View {
    @Binding var showPhotos: Bool
    @Binding var showFiles: Bool

    var body: some View {
        Menu {
            Button { showPhotos = true } label: { Label("من مكتبة الصور", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("من تطبيق الملفات", systemImage: "folder") }
        } label: {
            Label("استيراد", systemImage: "plus.circle.fill")
        }
        .accessibilityLabel("استيراد وسائط")
    }
}

/// Inline import progress card.
struct ImportProgressCard: View {
    let importer: MediaImportManager

    var body: some View {
        if importer.isImporting {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().tint(Theme.Palette.accent)
                        Text("جارٍ الاستيراد " + Fmt.int(min(importer.completedCount + 1, importer.totalCount)) + " من " + Fmt.int(importer.totalCount))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    if !importer.currentName.isEmpty {
                        Text(importer.currentName).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                    }
                    ProgressBarView(progress: importer.progress)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
