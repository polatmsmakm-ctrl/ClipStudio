//
//  StudioToolbar.swift
//  ClipStudio — Features/ProStudio
//
//  Edit tool strip above the timeline: select / blade tools, split, delete, ripple
//  delete, duplicate, join, clipboard, paste attributes, freeze frame, detach audio,
//  markers, in/out, snapping, magnetic storyline, multi-select and zoom.
//  Part 3: text & titles, graphics, captions, text-based editing, motion presets,
//  voiceover, sound effects, mixer, audio tools, close gaps and frame snapshot.
//  Part 4: smart tools, music & beat sync, editing style, voice separation,
//  quality check and multi-format outputs. Part 5: AI editing assistant.
//  ⌘-shortcuts are bound here (hardware keyboard on iPad).
//

import SwiftUI

struct StudioToolbar: View {
    @Bindable var vm: StudioViewModel
    var compact: Bool

    private var hasSelection: Bool { !vm.selection.isEmpty }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 2 : 4) {
                toolToggle

                separator
                tool("تقسيم", "scissors", enabled: !vm.timeline.isEmpty) { vm.splitAtPlayhead() }
                    .keyboardShortcut("b", modifiers: .command)
                tool("حذف", "trash", enabled: hasSelection) { vm.deleteSelection(ripple: false) }
                tool("حذف متموّج", "delete.backward", enabled: hasSelection) { vm.deleteSelection(ripple: true) }
                tool("تكرار", "plus.square.on.square", enabled: hasSelection) { vm.duplicateSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                tool("دمج", "link", enabled: vm.canJoinSelection) { vm.joinSelection() }

                separator
                tool("نسخ", "doc.on.doc", enabled: hasSelection) { vm.copySelection() }
                    .keyboardShortcut("c", modifiers: .command)
                tool("قص", "scissors.badge.ellipsis", enabled: hasSelection) { vm.cutSelection() }
                    .keyboardShortcut("x", modifiers: .command)
                tool("لصق", "doc.on.clipboard", enabled: vm.clipboard.hasClips) { vm.paste() }
                    .keyboardShortcut("v", modifiers: .command)
                Menu {
                    Button { vm.copyAttributes() } label: { Label("نسخ خصائص المقطع", systemImage: "paintbrush") }
                        .disabled(vm.primaryClip == nil)
                    Button { vm.activeSheet = .pasteAttributes } label: { Label("لصق الخصائص…", systemImage: "paintbrush.pointed") }
                        .disabled(!vm.clipboard.hasAttributes || !hasSelection)
                    Button { vm.pasteAttributes(.visualLook) } label: { Label("لصق الألوان والتأثيرات", systemImage: "paintpalette") }
                        .disabled(!vm.clipboard.hasAttributes || !hasSelection)
                } label: {
                    toolLabel("الخصائص", "paintbrush.pointed", enabled: true, active: false)
                }

                separator
                tool("إطار ثابت", "pause.rectangle", enabled: vm.primaryClip?.mediaAssetID != nil) { vm.insertFreezeFrame() }
                tool("فصل الصوت", "waveform.badge.minus", enabled: vm.primaryClip?.mediaAssetID != nil) { vm.detachAudio() }
                tool("تسلسل", "square.stack.3d.up", enabled: vm.canCreateCompound) { vm.createCompound() }
                    .keyboardShortcut("g", modifiers: .command)
                tool("طبقة تعديل", "slider.horizontal.below.square.filled.and.square") { vm.addAdjustmentLayer() }

                separator
                tool("نص", "textformat") { vm.activeSheet = .titles }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                tool("رسومات", "square.on.circle") { vm.activeSheet = .graphics }
                tool("ترجمة", "captions.bubble") { vm.activeSheet = .captions }
                tool("بالنص", "text.quote") { vm.activeSheet = .transcript }
                tool("حركة", "wand.and.rays", enabled: hasSelection) { vm.activeSheet = .motionPresets }

                separator
                tool("تعليق صوتي", "mic") { vm.activeSheet = .voiceover }
                tool("مؤثرات", "speaker.wave.3") { vm.activeSheet = .soundEffects }
                tool("المكسر", "slider.horizontal.3") { vm.activeSheet = .mixer }
                Menu {
                    Button { vm.activeSheet = .ducking } label: { Label("خفض الموسيقى تحت الكلام", systemImage: "arrow.down.right.and.arrow.up.left") }
                    Menu("تسوية مستوى الصوت") {
                        ForEach(LoudnessTarget.allCases) { target in
                            Button(target.title) { vm.normalizeLoudness(target: target) }
                        }
                    }
                    .disabled(vm.selectedAudioClips.isEmpty)
                    Button { vm.showsVolumeAutomation.toggle() } label: {
                        Label(vm.showsVolumeAutomation ? "إخفاء خط مستوى الصوت" : "رسم مستوى الصوت",
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                } label: {
                    toolLabel("الصوت", "waveform.badge.plus", enabled: true, active: vm.showsVolumeAutomation)
                }
                tool("حذف الفراغات", "arrow.left.and.right.square", enabled: !vm.timeline.isEmpty) {
                    vm.closeGaps(onTrack: vm.selectedTrackIndex)
                }

                separator
                tool("المساعد", "sparkles") { vm.activeSheet = .assistant }
                tool("ذكي", "wand.and.stars", enabled: vm.primaryVideoClipID != nil) {
                    if let id = vm.primaryVideoClipID { vm.activeSheet = .smartTools(id) }
                }
                tool("الإيقاع", "metronome") { vm.activeSheet = .music }
                tool("أسلوب", "dna", enabled: !vm.timeline.isEmpty) { vm.activeSheet = .editingDNA }
                tool("فصل الكلام", "person.wave.2", enabled: vm.primarySoundClipID != nil) {
                    if let id = vm.primarySoundClipID { vm.activeSheet = .separation(id) }
                }
                tool("فحص الجودة", "checkmark.seal", enabled: !vm.timeline.isEmpty) { vm.activeSheet = .quality }
                tool("مقاسات", "rectangle.3.group", enabled: !vm.timeline.isEmpty && vm.editingCompoundID == nil) {
                    vm.activeSheet = .outputs
                }
                tool("لقطة", "camera", enabled: !vm.timeline.isEmpty) { vm.saveSnapshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])

                separator
                tool("علامة", "bookmark", enabled: vm.editingCompoundID == nil) { vm.addMarker() }
                tool("بداية", "chevron.left.to.line") { vm.markIn() }
                tool("نهاية", "chevron.right.to.line") { vm.markOut() }
                if vm.inPoint != nil || vm.outPoint != nil {
                    tool("مسح", "xmark.circle") { vm.clearInOut() }
                }

                separator
                tool("التقاط", "magnet", active: vm.prefs.snappingEnabled) {
                    vm.prefs.snappingEnabled.toggle()
                    Haptics.selection()
                }
                tool("مغناطيسي", "rectangle.split.3x1", active: vm.prefs.magneticTimeline) {
                    vm.prefs.magneticTimeline.toggle()
                    vm.env.toasts.show(vm.prefs.magneticTimeline ? "المسار الرئيسي مغناطيسي — بلا فراغات" : "تحرير حر لكل المسارات",
                                       style: .info, duration: 1.6)
                }
                tool("تحديد متعدد", "checklist", active: vm.isMultiSelect) { vm.isMultiSelect.toggle() }
                tool("تحديد الكل", "square.dashed.inset.filled") { vm.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)

                separator
                tool("تصغير", "minus.magnifyingglass") { vm.zoom(by: 1 / 1.5) }
                tool("تكبير", "plus.magnifyingglass") { vm.zoom(by: 1.5) }
                tool("ملاءمة", "arrow.left.and.right") { vm.zoomToFit() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
        .background(Theme.Palette.surfaceRaised)
    }

    private var toolToggle: some View {
        HStack(spacing: 0) {
            ForEach(StudioTool.allCases) { option in
                Button {
                    vm.tool = option
                    Haptics.selection()
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 30)
                        .foregroundStyle(vm.tool == option ? Color(hex: 0x1A1408) : Theme.Palette.textPrimary)
                        .background(RoundedRectangle(cornerRadius: 8).fill(vm.tool == option ? Theme.Palette.accent : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("أداة " + option.title)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.surfaceHighlight))
    }

    private var separator: some View {
        Rectangle().fill(Theme.Palette.stroke).frame(width: 1, height: 26).padding(.horizontal, 2)
    }

    private func tool(_ title: String, _ symbol: String, enabled: Bool = true, active: Bool = false,
                      _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            toolLabel(title, symbol, enabled: enabled, active: active)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private func toolLabel(_ title: String, _ symbol: String, enabled: Bool, active: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: compact ? 15 : 16, weight: .medium))
            if !compact { Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1) }
        }
        .frame(minWidth: compact ? 38 : 50, minHeight: compact ? 34 : 40)
        .padding(.horizontal, 2)
        .foregroundStyle(active ? Theme.Palette.accent : (enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary))
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.Palette.accentSoft : Color.clear))
    }
}
