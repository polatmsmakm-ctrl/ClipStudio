//
//  ClipStudioWidget.swift
//  ClipStudioWidget — Home Screen & Lock Screen widgets
//
//  Shows the current export (progress), queue size, exports today and recent
//  projects from the snapshot the app writes into the App Group.
//  Arabic RTL with English digits. Tapping opens the relevant screen.
//

import WidgetKit
import SwiftUI

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: WidgetSnapshot(updatedAt: Date(),
            activeExport: .init(title: "قصة — مقطع 03", progress: 0.64, statusText: "جارٍ التصدير"),
            queuedCount: 4, completedToday: 7, lastExportTitle: "دمج الرحلة", lastExportDate: Date(),
            recentProjects: [.init(id: UUID(), name: "بودكاست الحلقة 12", symbol: "scissors", modifiedAt: Date())]))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : StatusEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: Date(), snapshot: WidgetSnapshot.load())
        let refresh = Calendar.current.date(byAdding: .minute, value: entry.snapshot?.activeExport == nil ? 30 : 5, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

private enum WidgetStyle {
    static let accent = Color(red: 0.89, green: 0.69, blue: 0.29)
    static let background = LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.13), Color(red: 0.04, green: 0.04, blue: 0.05)],
                                           startPoint: .top, endPoint: .bottom)
    static func percent(_ value: Double) -> String { String(format: "%.0f%%", min(max(value, 0), 1) * 100) }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: medium
            default: small
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .widgetURL(URL(string: entry.snapshot?.activeExport != nil ? "clipstudio://exports" : "clipstudio://projects"))
    }

    // MARK: Lock Screen

    private var circular: some View {
        Group {
            if let active = entry.snapshot?.activeExport {
                Gauge(value: active.progress) {
                    Image(systemName: "square.and.arrow.up")
                } currentValueLabel: {
                    Text(WidgetStyle.percent(active.progress)).font(.system(size: 11, weight: .bold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 14))
                        Text(String(entry.snapshot?.completedToday ?? 0)).font(.system(size: 14, weight: .bold))
                    }
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let active = entry.snapshot?.activeExport {
                Label("ClipStudio", systemImage: "square.and.arrow.up").font(.caption2.weight(.semibold))
                Text(active.title).font(.caption).lineLimit(1)
                ProgressView(value: active.progress)
            } else {
                Label("ClipStudio", systemImage: "play.rectangle.fill").font(.caption2.weight(.semibold))
                Text("اليوم: " + String(entry.snapshot?.completedToday ?? 0) + " تصدير").font(.caption)
                Text(entry.snapshot?.recentProjects.first?.name ?? "لا توجد مشاريع").font(.caption2).lineLimit(1)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var inline: some View {
        Group {
            if let active = entry.snapshot?.activeExport {
                Text("تصدير " + WidgetStyle.percent(active.progress))
            } else {
                Text("ClipStudio • " + String(entry.snapshot?.completedToday ?? 0) + " اليوم")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: Home Screen

    private var small: some View {
        smallContent
            .containerBackground(for: .widget) { WidgetStyle.background }
    }

    private var smallContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "play.rectangle.fill").foregroundStyle(WidgetStyle.accent)
                Text("ClipStudio").font(.caption.weight(.bold))
            }
            if let active = entry.snapshot?.activeExport {
                Text(active.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
                Text(WidgetStyle.percent(active.progress)).font(.title2.weight(.bold)).foregroundStyle(WidgetStyle.accent)
                ProgressView(value: active.progress).tint(WidgetStyle.accent)
            } else if entry.snapshot == nil {
                Spacer(minLength: 0)
                Text("افتح التطبيق لعرض الحالة").font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
                Text(String(entry.snapshot?.completedToday ?? 0)).font(.system(size: 34, weight: .bold)).foregroundStyle(WidgetStyle.accent)
                Text("تصدير اليوم").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            smallContent
            VStack(alignment: .leading, spacing: 6) {
                Text("المشاريع الأخيرة").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let projects = entry.snapshot?.recentProjects, !projects.isEmpty {
                    ForEach(projects.prefix(3)) { project in
                        Link(destination: URL(string: "clipstudio://projects")!) {
                            HStack(spacing: 6) {
                                Image(systemName: project.symbol).foregroundStyle(WidgetStyle.accent).font(.caption)
                                Text(project.name).font(.caption).lineLimit(1)
                            }
                        }
                    }
                } else {
                    Text("لا توجد مشاريع بعد").font(.caption)
                }
                Spacer(minLength: 0)
                if let queued = entry.snapshot?.queuedCount, queued > 0 {
                    Text("في الانتظار: " + String(queued)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { WidgetStyle.background }
    }
}

struct ClipStudioStatusWidget: Widget {
    let kind = "ClipStudioStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("ClipStudio")
        .description("تقدّم التصدير والمشاريع الأخيرة.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ClipStudioWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClipStudioStatusWidget()
    }
}
