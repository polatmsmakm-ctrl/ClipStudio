//
//  PerformanceSettingsView.swift
//  ClipStudio — Features/Settings (Part 6)
//
//  Performance, proxy media and accessibility in one place:
//  • proxies: use for preview, create automatically on import, resolution, list
//    of heavy videos with their state, create all / delete all, storage used;
//  • adaptive preview (heat / Low Power Mode) and live device status: thermal
//    state, memory used / available, memory warnings, purge caches;
//  • accessibility: larger trim handles, and what the app follows from iOS.
//

import SwiftUI

struct PerformanceSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AccessibilityPrefs.largeHandlesKey) private var largeHandles = false
    @State private var confirmDelete = false
    @State private var search = ""

    private var heavyVideos: [MediaAsset] {
        let list = env.library.assets.filter { ProxyPolicy.needsProxy($0) || env.proxies.readyURL(for: $0) != nil }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? list : list.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        @Bindable var proxies = env.proxies
        @Bindable var performance = env.performance
        Form {
            Section {
                Toggle("استخدم النسخ الخفيفة في المعاينة", isOn: $proxies.isEnabled)
                Toggle("أنشئها تلقائيًا عند الاستيراد", isOn: $proxies.autoCreate)
                Picker("الدقة", selection: $proxies.resolution) {
                    ForEach(ProxyResolution.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("الجاهز", value: Fmt.int(proxies.readyCount) + " • " + Fmt.bytes(proxies.totalBytes))
                if !proxies.missingAssets.isEmpty {
                    Button { proxies.enqueue(proxies.missingAssets) } label: {
                        Label("أنشئ " + Fmt.int(proxies.missingAssets.count) + " نسخة خفيفة", systemImage: "bolt.horizontal")
                    }
                }
                if proxies.currentID != nil || !proxies.queue.isEmpty {
                    HStack {
                        ProgressBarView(progress: proxies.currentProgress)
                        Text(Fmt.int(proxies.queue.count + (proxies.currentID == nil ? 0 : 1)) + " متبقية").font(.caption)
                        Button("إيقاف") { proxies.cancelAll() }.font(.caption)
                    }
                    if performance.shouldPauseBackgroundWork {
                        Label("متوقفة مؤقتًا حتى يبرد الجهاز", systemImage: "thermometer.sun").font(.caption).foregroundStyle(Theme.Palette.warning)
                    }
                }
                Button("حذف كل النسخ الخفيفة", role: .destructive) { confirmDelete = true }
                    .disabled(proxies.records.isEmpty)
            } header: {
                Text("النسخ الخفيفة (Proxy)")
            } footer: {
                Text("نسخ أخف من فيديوهات 4K والعالية الجودة تُستخدم للمعاينة والتقطيع فقط، فيصير التشغيل أسلس. التصدير واللقطات والتحليل تستخدم الملف الأصلي دائمًا بجودته الكاملة.")
            }

            if !heavyVideos.isEmpty {
                Section("الفيديوهات الثقيلة") {
                    ForEach(heavyVideos) { asset in
                        proxyRow(asset)
                    }
                }
            }

            Section {
                Toggle("خفّض المعاينة عند الحرارة أو توفير الطاقة", isOn: $performance.adaptsToHeat)
                LabeledContent("حرارة الجهاز", value: performance.thermalTitle)
                LabeledContent("وضع توفير الطاقة", value: performance.isLowPower ? "مفعّل" : "متوقف")
                if let cap = performance.previewCap {
                    LabeledContent("المعاينة الآن", value: Fmt.int(Int(cap)) + "p")
                }
            } header: {
                Text("الأداء")
            } footer: {
                Text("عند الحرارة تنخفض دقة المعاينة مؤقتًا وتتوقف الأعمال في الخلفية والخلفية المتحركة، ثم ترجع تلقائيًا.")
            }

            Section {
                LabeledContent("الذاكرة المستخدمة", value: Fmt.int(Int(performance.footprintMB.rounded())) + " MB")
                LabeledContent("أعلى استخدام", value: Fmt.int(Int(performance.peakFootprintMB.rounded())) + " MB")
                LabeledContent("المتاح قبل الإغلاق", value: Fmt.int(Int(PerformanceMonitor.availableMB().rounded())) + " MB")
                LabeledContent("تحذيرات الذاكرة", value: Fmt.int(performance.memoryWarnings))
                Button {
                    PerformanceMonitor.purgeCaches()
                    performance.sampleFootprint()
                    env.toasts.show("تم تفريغ الذاكرة المؤقتة", style: .success)
                } label: { Label("تفريغ الذاكرة المؤقتة", systemImage: "memorychip") }
            } header: {
                Text("الذاكرة")
            } footer: {
                Text("يُفرّغ التطبيق الصور المصغرة والموجات الصوتية من الذاكرة تلقائيًا عند تحذير iOS. الملفات المحفوظة لا تتأثر.")
            }

            Section {
                Toggle("مقابض قص أكبر في الخط الزمني", isOn: $largeHandles)
                LabeledContent("تقليل الحركة", value: reduceMotion ? "مفعّل — الخلفية ثابتة" : "متوقف")
                LabeledContent("خط عريض", value: legibilityWeight == .bold ? "مفعّل" : "متوقف")
                LabeledContent("حجم النص", value: dynamicTypeSize.isAccessibilitySize ? "كبير جدًا" : "عادي/كبير")
            } header: {
                Text("تسهيلات الاستخدام")
            } footer: {
                Text("مع VoiceOver: كل مقطع يُقرأ بنوعه وتوقيته، وتجد إجراءات (تحديد، قص، تحريك، حذف) بالسحب للأعلى أو للأسفل، ورأس التشغيل قابل للتعديل ثانية بثانية، والإشعارات تُنطق.")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("الأداء وتسهيلات الاستخدام")
        .searchable(text: $search, prompt: "ابحث في الفيديوهات")
        .confirmationDialog("حذف كل النسخ الخفيفة؟ الأصول لا تتأثر.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { env.proxies.removeAll() }
        }
        .onAppear { env.performance.sampleFootprint() }
    }

    private func proxyRow(_ asset: MediaAsset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.displayName).lineLimit(1)
                Text(asset.resolutionText + " • " + Fmt.bytes(asset.fileSize)).font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
            switch env.proxies.status(for: asset) {
            case .ready:
                StatusPill(text: "جاهزة", color: Theme.Palette.success, systemImage: "checkmark")
                Button { env.proxies.remove(asset.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("حذف النسخة الخفيفة")
            case .working(let value):
                Text(Fmt.percent(value)).font(.caption.monospacedDigit())
            case .queued:
                StatusPill(text: "في الانتظار", color: Theme.Palette.textSecondary)
            case .failed(let message):
                Button { env.proxies.enqueue([asset]) } label: { Label("إعادة", systemImage: "arrow.clockwise") }
                    .accessibilityHint(message)
            case .none, .notNeeded:
                Button("أنشئ") { env.proxies.enqueue([asset]) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}
