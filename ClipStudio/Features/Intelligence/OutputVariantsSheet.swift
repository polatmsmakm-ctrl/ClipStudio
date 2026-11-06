//
//  OutputVariantsSheet.swift
//  ClipStudio — Features/Intelligence (Part 4)
//
//  Multiple content outputs: makes 9:16 / 16:9 / 1:1 / 4:5 copies of the edit as
//  new projects (the original is untouched), with smart subject-following crops,
//  centred crops or the whole picture over blur, and can queue them all for export.
//

import SwiftUI

struct OutputVariantsSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var formats: Set<OutputFormat> = []
    @State private var options = VariantOptions()
    @State private var exportNow = true
    @State private var exportSettings = ExportSettings()

    private var current: AspectRatio { vm.settings.aspect }
    /// Clips a smart variant still has to analyze (computed once — it reads the analysis cache).
    @State private var analysisCount = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(OutputFormat.allCases) { format in
                        let isCurrent = format.aspect == current
                        Button {
                            guard !isCurrent else { return }
                            if formats.contains(format) { formats.remove(format) } else { formats.insert(format) }
                            Haptics.selection()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: format.symbol)
                                    .font(.title3)
                                    .foregroundStyle(Theme.Palette.accent)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.title).font(.subheadline.weight(.semibold))
                                    Text(isCurrent ? "مقاس المشروع الحالي" : format.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: formats.contains(format) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(formats.contains(format) ? Theme.Palette.accent : Theme.Palette.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent)
                        .opacity(isCurrent ? 0.5 : 1)
                    }
                } header: {
                    Text("المقاسات")
                } footer: {
                    Text("كل مقاس يصير مشروعًا مستقلًا تقدر تعدّله — المشروع الأصلي لا يتغير.")
                }

                Section {
                    Picker("طريقة الملء", selection: $options.method) {
                        ForEach(ReframeMethod.allCases) { method in Text(method.title).tag(method) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if options.method == .smart {
                        PrecisionSlider(title: "نعومة حركة الكاميرا", value: $options.smoothing, range: 0.2...2.5, defaultValue: 0.8,
                                        step: 0.05, format: { Fmt.seconds($0, digits: 2) })
                        if analysisCount > 0 {
                            Label("سيُحلل " + Fmt.int(analysisCount) + " مقطع لتحديد العنصر الأساسي (مرة واحدة).", systemImage: "viewfinder")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                } header: {
                    Text("اللقطات")
                } footer: {
                    Text("النصوص والملصقات يتغير حجمها لتناسب المقاس الجديد وتبقى داخل المنطقة الآمنة، والترجمة يُعاد تقسيم أسطرها.")
                }

                Section {
                    Toggle("أضفها لقائمة التصدير مباشرة", isOn: $exportNow)
                    if exportNow {
                        NavigationLink {
                            Form {
                                ExportSettingsForm(settings: $exportSettings, durationSeconds: vm.duration, canvas: nil)
                            }
                            .scrollContentBackground(.hidden)
                            .screenBackground()
                            .navigationTitle("إعدادات التصدير")
                        } label: {
                            LabeledContent("الإعدادات", value: exportSettings.resolution.title + " • " + exportSettings.quality.title)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("نسخ بمقاسات أخرى")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إنشاء") {
                        let ordered = OutputFormat.allCases.filter { formats.contains($0) }
                        vm.createVariants(formats: ordered, options: options, export: exportNow ? exportSettings : nil)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(formats.isEmpty || vm.timeline.isEmpty)
                }
            }
            .onAppear {
                analysisCount = vm.variantAnalysisJobs().filter { !$0.cached }.count
                exportSettings = vm.exportSettingsForProject
                if formats.isEmpty {
                    formats = Set(OutputFormat.allCases.filter { $0.aspect != current && ($0 == .vertical || $0 == .square) })
                }
            }
        }
    }
}
