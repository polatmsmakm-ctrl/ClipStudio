//
//  ExportSettingsSheet.swift
//  ClipStudio — Features/Export
//
//  Container, codec, resolution, frame rate, quality / custom bitrate, audio
//  bitrate and destination, with a live bitrate and file-size estimate.
//

import SwiftUI

struct ExportSettingsForm: View {
    @Binding var settings: ExportSettings
    var durationSeconds: Double
    var canvas: CGSize?

    private var previewSize: CGSize {
        ExportGeometry.outputSize(canvas: canvas ?? CGSize(width: 1920, height: 1080), resolution: settings.resolution)
    }

    private var bitrate: Double {
        BitrateCalculator.videoBitrate(size: previewSize, fps: settings.frameRate.value ?? 30, settings: settings)
    }

    var body: some View {
        Section("الملف") {
            Picker("الحاوية", selection: $settings.container) {
                ForEach(ExportContainer.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("الترميز", selection: $settings.codec) {
                ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section("الصورة") {
            Picker("الدقة", selection: $settings.resolution) {
                ForEach(ResolutionPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("معدل الإطارات", selection: $settings.frameRate) {
                ForEach(FrameRateOption.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("الجودة", selection: $settings.quality) {
                ForEach(QualityLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if settings.quality == .custom {
                DecimalField(title: "معدل البت", value: $settings.customBitrateMbps, range: 0.5...150, step: 1, digits: 1, unit: "Mbps")
            }
        }
        Section("الصوت") {
            Picker("معدل بت الصوت", selection: $settings.audioBitrateKbps) {
                ForEach([96, 128, 192, 256, 320], id: \.self) { Text(Fmt.int($0) + " kbps").tag($0) }
            }
        }
        Section("الوجهة") {
            Picker("الحفظ في", selection: $settings.destination) {
                ForEach(ExportDestination.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        Section {
            HStack {
                Text("الدقة الناتجة")
                Spacer()
                Text(Fmt.resolution(Int(previewSize.width), Int(previewSize.height))).foregroundStyle(Theme.Palette.textSecondary)
            }
            HStack {
                Text("معدل البت التقريبي")
                Spacer()
                Text(Fmt.bitrate(bitrate)).foregroundStyle(Theme.Palette.textSecondary)
            }
            if durationSeconds > 0 {
                HStack {
                    Text("الحجم التقريبي")
                    Spacer()
                    Text(Fmt.bytes(BitrateCalculator.estimatedBytes(durationSeconds: durationSeconds, videoBitrate: bitrate,
                                                                    audioKbps: settings.audioBitrateKbps)))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Text("التصدير يعيد ترميز الفيديو بتسريع العتاد. الملف الناتج ليس نسخة مطابقة للمصدر.")
                .font(.caption).foregroundStyle(Theme.Palette.textTertiary)
        } header: {
            Text("التقدير")
        }
    }
}

struct ExportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var settings: ExportSettings
    var durationSeconds: Double
    var canvas: CGSize?

    var body: some View {
        NavigationStack {
            Form {
                ExportSettingsForm(settings: $settings, durationSeconds: durationSeconds, canvas: canvas)
            }
            .screenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
            .keyboardDoneToolbar()
        }
    }
}

/// Settings › default export settings used for new projects.
struct ExportDefaultsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            ExportSettingsForm(settings: $settings.defaultExport, durationSeconds: 60, canvas: nil)
        }
        .screenBackground()
        .navigationTitle("إعدادات التصدير الافتراضية")
        .keyboardDoneToolbar()
    }
}
