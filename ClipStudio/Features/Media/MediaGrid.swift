//
//  MediaGrid.swift
//  ClipStudio — Features/Media
//
//  Media cells, filtering/sorting helpers and the reusable picker sheet.
//

import SwiftUI

enum MediaFilter: String, CaseIterable, Identifiable {
    case all, video, audio, image, missing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "الكل"
        case .video: "فيديو"
        case .audio: "صوت"
        case .image: "صور"
        case .missing: "مفقود"
        }
    }

    func matches(_ asset: MediaAsset, missing: Bool) -> Bool {
        switch self {
        case .all: true
        case .video: asset.kind == .video
        case .audio: asset.kind == .audio
        case .image: asset.kind == .image
        case .missing: missing
        }
    }
}

enum MediaSort: String, CaseIterable, Identifiable {
    case newest, oldest, name, duration, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "الأحدث"
        case .oldest: "الأقدم"
        case .name: "الاسم"
        case .duration: "المدة"
        case .size: "الحجم"
        }
    }

    func sorted(_ assets: [MediaAsset]) -> [MediaAsset] {
        switch self {
        case .newest: assets.sorted { $0.importedAt > $1.importedAt }
        case .oldest: assets.sorted { $0.importedAt < $1.importedAt }
        case .name: assets.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .duration: assets.sorted { ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0) }
        case .size: assets.sorted { $0.fileSize > $1.fileSize }
        }
    }
}

struct MediaCell: View {
    @Environment(AppEnvironment.self) private var env
    let asset: MediaAsset
    var isSelected = false
    var selectionIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 1))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        if env.library.isMissing(asset) {
                            StatusPill(text: "مفقود", color: Theme.Palette.danger, systemImage: "exclamationmark.triangle.fill")
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            ZStack {
                                Circle().fill(Theme.Palette.accent)
                                if let selectionIndex {
                                    Text(Fmt.int(selectionIndex)).font(.caption.bold()).foregroundStyle(Color(hex: 0x1A1408))
                                } else {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color(hex: 0x1A1408))
                                }
                            }
                            .frame(width: 26, height: 26)
                            .padding(6)
                        }
                    }
                if asset.kind != .image {
                    Text(asset.durationText)
                        .font(Theme.Typo.mono)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(isSelected ? Theme.Palette.accent : .clear, lineWidth: 2))
            HStack(spacing: 4) {
                Image(systemName: asset.kind.symbol).font(.caption2).foregroundStyle(Theme.Palette.accent)
                Text(asset.displayName).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(asset.kind == .audio ? Fmt.bytes(asset.fileSize) : asset.resolutionText + " • " + Fmt.bytes(asset.fileSize))
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(asset.displayName + "، " + asset.kind.title + "، " + asset.durationText)
    }
}

/// Library picker with built-in import. Keeps selection order (used for merge order).
struct MediaPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let title: String
    let kinds: Set<MediaKind>
    let allowsMultiple: Bool
    var confirmTitle = "متابعة"
    let onPick: ([MediaAsset]) -> Void

    @State private var selection: [UUID] = []
    @State private var search = ""
    @State private var showPhotos = false
    @State private var showFiles = false

    private var assets: [MediaAsset] {
        env.library.assets.filter { kinds.contains($0.kind) && !env.library.isMissing($0) }
            .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.md) {
                    ImportProgressCard(importer: env.importer)
                    if assets.isEmpty {
                        EmptyStateView(systemImage: "photo.on.rectangle.angled", title: "لا توجد وسائط",
                                       message: "استورد فيديوهات من مكتبة الصور أو تطبيق الملفات للبدء.",
                                       actionTitle: "استيراد من الصور") { showPhotos = true }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                            ForEach(assets) { asset in
                                let index = selection.firstIndex(of: asset.id)
                                MediaCell(asset: asset, isSelected: index != nil,
                                          selectionIndex: allowsMultiple ? index.map { $0 + 1 } : nil)
                                    .onTapGesture { toggle(asset) }
                            }
                        }
                    }
                }
                .padding(Theme.Space.md)
                .animation(.snappy, value: env.importer.isImporting)
            }
            .searchable(text: $search, prompt: "بحث")
            .screenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ImportMenu(showPhotos: $showPhotos, showFiles: $showFiles) }
            }
            .safeAreaInset(edge: .bottom) {
                if allowsMultiple && !selection.isEmpty {
                    Button(confirmTitle + " (" + Fmt.int(selection.count) + ")") { confirm() }
                        .buttonStyle(.csPrimary)
                        .padding(Theme.Space.md)
                        .background(.ultraThinMaterial)
                }
            }
            .mediaImport(showPhotos: $showPhotos, showFiles: $showFiles) { imported in
                for asset in imported where kinds.contains(asset.kind) && !selection.contains(asset.id) {
                    if allowsMultiple { selection.append(asset.id) } else { selection = [asset.id] }
                }
            }
            .keyboardDoneToolbar()
        }
    }

    private func toggle(_ asset: MediaAsset) {
        Haptics.selection()
        if allowsMultiple {
            if let index = selection.firstIndex(of: asset.id) { selection.remove(at: index) } else { selection.append(asset.id) }
        } else {
            selection = [asset.id]
            confirm()
        }
    }

    private func confirm() {
        let picked = selection.compactMap { env.library.asset($0) }
        guard !picked.isEmpty else { return }
        dismiss()
        onPick(picked)
    }
}
