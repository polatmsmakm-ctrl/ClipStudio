//
//  StudioKeyCommands.swift
//  ClipStudio — Features/ProStudio
//
//  Hardware keyboard support (iPad Magic Keyboard / any Bluetooth keyboard):
//  J/K/L shuttle, Space play, arrows for frames and edit points, I/O in/out,
//  M marker, B blade, S split, Delete / ⇧Delete, N snapping, +/− zoom and more.
//  ⌘ combinations are bound to buttons (toolbar / top bar) so they appear in the
//  iPad shortcut overlay. Apple Pencil double-tap runs a configurable action.
//

import SwiftUI
import UIKit

struct ShortcutEntry: Hashable {
    let keys: String
    let action: String
}

enum StudioKeyHandler {
    @MainActor
    static func handle(_ press: KeyPress, vm: StudioViewModel, onGoTo: () -> Void) -> KeyPress.Result {
        guard vm.busy == nil, vm.activeSheet == nil else { return .ignored }
        if press.modifiers.contains(.command) { return .ignored }
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option)

        switch press.key {
        case .space:
            vm.togglePlay()
        case .leftArrow:
            if option { vm.nudgeSelection(frames: shift ? -10 : -1) } else if shift { vm.seek(to: vm.currentTime - 1) } else { vm.step(frames: -1) }
        case .rightArrow:
            if option { vm.nudgeSelection(frames: shift ? 10 : 1) } else if shift { vm.seek(to: vm.currentTime + 1) } else { vm.step(frames: 1) }
        case .upArrow:
            vm.previousEditPoint()
        case .downArrow:
            vm.nextEditPoint()
        case .delete, .deleteForward:
            vm.deleteSelection(ripple: shift)
        case .home:
            vm.goToStart()
        case .end:
            vm.goToEnd()
        case .escape:
            vm.deselectAll()
            vm.tool = .select
        case .return:
            if let clip = vm.primaryClip, vm.compound(for: clip) != nil { vm.openCompound(for: clip.id) } else { return .ignored }
        default:
            switch press.characters.lowercased() {
            case "j": vm.shuttle(-1)
            case "k": vm.shuttle(0)
            case "l": vm.shuttle(1)
            case "i": vm.markIn()
            case "o": vm.markOut()
            case "x": vm.clearInOut()
            case "m": vm.addMarker()
            case "b": vm.toggleTool()
            case "a": vm.tool = .select
            case "s": vm.splitAtPlayhead()
            case "n": vm.prefs.snappingEnabled.toggle()
            case "=", "+": vm.zoom(by: 1.4)
            case "-": vm.zoom(by: 1 / 1.4)
            case "z": if shift { vm.zoomToFit() } else { return .ignored }
            case ",": vm.nudgeSelection(frames: -1)
            case ".": vm.nudgeSelection(frames: 1)
            case "[": vm.jumpToMarker(next: false)
            case "]": vm.jumpToMarker(next: true)
            case "f": vm.insertFreezeFrame()
            case "t": vm.goToStartOrTimecode(onGoTo)
            case "d": vm.toggleEnabled()
            default: return .ignored
            }
        }
        return .handled
    }

    static let reference: [ShortcutEntry] = [
        ShortcutEntry(keys: "Space", action: "تشغيل / إيقاف"),
        ShortcutEntry(keys: "J / K / L", action: "تشغيل للخلف / إيقاف / تشغيل للأمام (اضغط أكثر للتسريع)"),
        ShortcutEntry(keys: "← / →", action: "إطار واحد (⇧ = ثانية)"),
        ShortcutEntry(keys: "⌥ ← / →", action: "تحريك المقاطع المحددة إطارًا (⇧ = 10 إطارات)"),
        ShortcutEntry(keys: "↑ / ↓", action: "نقطة القطع السابقة / التالية"),
        ShortcutEntry(keys: "Home / End", action: "بداية / نهاية الخط الزمني"),
        ShortcutEntry(keys: "I / O / X", action: "نقطة البداية / النهاية / مسحهما"),
        ShortcutEntry(keys: "M", action: "إضافة علامة"),
        ShortcutEntry(keys: "[ / ]", action: "العلامة السابقة / التالية"),
        ShortcutEntry(keys: "S أو ⌘B", action: "تقسيم عند رأس التشغيل"),
        ShortcutEntry(keys: "B / A", action: "أداة الشفرة / أداة التحديد"),
        ShortcutEntry(keys: "Delete", action: "حذف (⇧ = حذف متموّج)"),
        ShortcutEntry(keys: "F", action: "إطار ثابت"),
        ShortcutEntry(keys: "D", action: "تفعيل / تعطيل المقطع"),
        ShortcutEntry(keys: "N", action: "تشغيل / إيقاف الالتقاط"),
        ShortcutEntry(keys: "+ / − / ⇧Z", action: "تكبير / تصغير / ملاءمة"),
        ShortcutEntry(keys: "T", action: "الانتقال إلى توقيت"),
        ShortcutEntry(keys: "Return", action: "فتح التسلسل المتداخل"),
        ShortcutEntry(keys: "Esc", action: "إلغاء التحديد"),
        ShortcutEntry(keys: "⌘Z / ⇧⌘Z", action: "تراجع / إعادة"),
        ShortcutEntry(keys: "⌘C / ⌘X / ⌘V", action: "نسخ / قص / لصق"),
        ShortcutEntry(keys: "⌘D", action: "تكرار"),
        ShortcutEntry(keys: "⌘A", action: "تحديد الكل"),
        ShortcutEntry(keys: "⌘G", action: "تسلسل متداخل من المحدد"),
        ShortcutEntry(keys: "⌘E", action: "تصدير"),
        ShortcutEntry(keys: "⇧⌘T", action: "إضافة نص أو عنوان"),
        ShortcutEntry(keys: "⇧⌘S", action: "لقطة من الإطار الحالي")
    ]
}

extension StudioViewModel {
    func goToStartOrTimecode(_ onGoTo: () -> Void) {
        onGoTo()
    }

    func handlePencilDoubleTap() {
        switch prefs.pencilDoubleTap {
        case .toggleBlade: toggleTool()
        case .playPause: togglePlay()
        case .undo: performUndo()
        case .none: break
        }
    }
}

extension View {
    /// Makes the editor focusable and routes hardware-keyboard presses to the editor.
    @MainActor
    func studioKeyCommands(vm: StudioViewModel, focus: FocusState<Bool>.Binding, onGoTo: @escaping () -> Void) -> some View {
        self
            .focusable()
            .focused(focus)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                StudioKeyHandler.handle(press, vm: vm, onGoTo: onGoTo)
            }
            .onAppear { focus.wrappedValue = true }
            .onChange(of: vm.activeSheet) { _, sheet in
                if sheet == nil { focus.wrappedValue = true }
            }
    }
}

// MARK: - Apple Pencil

/// Hosts a UIPencilInteraction so a Pencil double-tap/squeeze-tap triggers an editor action.
struct PencilDoubleTapView: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @available(iOS, introduced: 12.1, deprecated: 17.5)
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            action()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            action()
        }
    }
}

// MARK: - Shortcuts reference

struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(StudioKeyHandler.reference, id: \.self) { entry in
                        HStack {
                            Text(entry.keys)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Theme.Palette.accent)
                                .environment(\.layoutDirection, .leftToRight)
                            Spacer()
                            Text(entry.action).font(.subheadline).multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    Text("تعمل الاختصارات مع لوحة مفاتيح الآيباد أو أي لوحة بلوتوث. ضغطة القلم المزدوجة قابلة للتخصيص من تفضيلات الاستوديو.")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("اختصارات لوحة المفاتيح")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }
}
