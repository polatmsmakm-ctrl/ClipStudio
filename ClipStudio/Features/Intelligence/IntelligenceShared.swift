//
//  IntelligenceShared.swift
//  ClipStudio — Features/Intelligence (Part 4)
//
//  Shared UI for the intelligence sheets: the editor's progress overlay shown
//  inside sheets that stay open while an on-device analysis runs (the editor's own
//  overlay is hidden behind the sheet).
//

import SwiftUI

struct StudioBusyOverlay: ViewModifier {
    let vm: StudioViewModel

    func body(content: Content) -> some View {
        content
            .overlay {
                if let busy = vm.busy {
                    BusyOverlay(operation: busy, onCancel: vm.cancelBusy)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.busy?.id)
            .interactiveDismissDisabled(vm.busy != nil)
    }
}

extension View {
    /// Shows the editor's progress (with cancel) above this sheet while an operation runs.
    func studioBusyOverlay(_ vm: StudioViewModel) -> some View {
        modifier(StudioBusyOverlay(vm: vm))
    }
}
