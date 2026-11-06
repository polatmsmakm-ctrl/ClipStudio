//
//  AudioInfoInspectors.swift
//  ClipStudio — Features/ProStudio/Inspector
//
//  Clip info (name, source details, timing, label color, enable, replace, nested
//  sequence actions, select all clips of the same file). The audio tab moved to
//  Features/AudioStudio/AudioStudioInspector.swift in Part 3.
//

import SwiftUI

struct ClipInfoInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }
    private let labels: [UInt32] = [0xE3B04B, 0xE25C55, 0x5FC48F, 0x5B8DEF, 0xB07CE8, 0xE58F4A]

    var body: some View {
        if let clip = editor.clip {
            VStack(spacing: 12) {
                InspectorSection(title: "المقطع", systemImage: "info.circle") {
                    TextField("الاسم", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { vm.renameClip(clipID, nameDraft) }
                        .onChange(of: nameFocused) { _, focused in if !focused { vm.renameClip(clipID, nameDraft) } }
                    infoRow("النوع", clip.source.title)
                    infoRow("البداية", Fmt.timecode(clip.start.seconds, fps: vm.frameRate))
                    infoRow("المدة", Fmt.durationPrecise(clip.duration.seconds))
                    if let range = clip.sourceRange {
                        infoRow("من المصدر", Fmt.timecode(range.start.seconds, fps: vm.frameRate) + " ← "
                                + Fmt.timecode(range.end.seconds, fps: vm.frameRate))
                    }
                    if let asset = vm.asset(for: clip) {
                        infoRow("الملف", asset.displayName)
                        infoRow("الدقة", asset.resolutionText)
                        if let fps = asset.frameRate { infoRow("الإطارات", Fmt.fps(fps)) }
                        if let codec = asset.videoCodec { infoRow("الترميز", codec) }
                    }
                    Toggle(isOn: Binding(get: { clip.isEnabled }, set: { value in
                        editor.update("تفعيل المقطع", key: "enabled") { $0.isEnabled = value }
                        vm.endContinuousEdit()
                    })) {
                        Label("المقطع مفعّل", systemImage: "eye")
                    }
                    .tint(Theme.Palette.accent)
                }
                InspectorSection(title: "لون التسمية", systemImage: "tag") {
                    HStack(spacing: 10) {
                        Button { vm.setLabel(nil) } label: {
                            Image(systemName: "nosign").frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        ForEach(labels, id: \.self) { hex in
                            Button { vm.setLabel(RGBAColor(hex: hex)) } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: clip.label == RGBAColor(hex: hex) ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                InspectorSection(title: "إجراءات", systemImage: "wrench.and.screwdriver") {
                    if !clip.source.assetIDs.isEmpty {
                        Button { vm.selectSameSource(as: clipID) } label: {
                            Label("تحديد كل مقاطع نفس الملف", systemImage: "square.on.square.dashed").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.csSecondary)
                    }
                    Button { vm.activeSheet = .replaceMedia(clipID) } label: {
                        Label("استبدال بملف آخر", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.csSecondary)
                    if vm.compound(for: clip) != nil {
                        Button { vm.openCompound(for: clipID) } label: {
                            Label("فتح التسلسل المتداخل", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.csSecondary)
                        Button { vm.expandCompound(clipID: clipID) } label: {
                            Label("تفكيك إلى المقاطع الأصلية", systemImage: "square.stack.3d.down.right").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.csSecondary)
                    }
                    Button(role: .destructive) {
                        vm.select(clipID)
                        vm.deleteSelection(ripple: false)
                    } label: {
                        Label("حذف المقطع", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.csSecondary)
                }
            }
            .onAppear { nameDraft = clip.name }
            .onChange(of: clipID) { _, _ in nameDraft = editor.clip?.name ?? "" }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
    }
}
