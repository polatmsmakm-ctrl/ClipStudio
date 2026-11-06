//
//  AIStudioView.swift
//  ClipStudio — Features/AI (Part 5)
//
//  The AI hub: Storyboard, Smart Highlights and Content Studio, with the active
//  provider (Gemini with the user's key, or on device), today's usage and a link
//  to the AI settings. Every tool works without a key, with simpler results.
//

import SwiftUI

struct AIStudioView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var settings = AISettings.shared
    @State private var usage = AIUsageManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                statusCard
                LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 280 : 300), spacing: 14)], spacing: 14) {
                    NavigationLink { StoryboardView() } label: {
                        toolCard("القصة المصورة", "من فكرتك ووسائطك إلى مشاهد مرتبة ومشروع جاهز للتعديل.", "rectangle.split.3x3")
                    }
                    NavigationLink { HighlightsView() } label: {
                        toolCard("أفضل اللقطات", "يختار أجمل لحظات فيديو طويل ويصنع منها مقطعًا قصيرًا.", "star.square.on.square")
                    }
                    NavigationLink { ContentStudioView(projectID: nil) } label: {
                        toolCard("استوديو المحتوى", "عناوين ووصف وهاشتاقات لكل منصة من كلام مشروعك.", "text.bubble")
                    }
                    NavigationLink { SeriesBuilderView() } label: {
                        toolCard("سلسلة حلقات", "عدة فيديوهات ← مشروع لكل حلقة بنفس الأسلوب والمقدمة والموسيقى.", "square.stack.3d.down.right")
                    }
                }
                .buttonStyle(.plain)
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "داخل الاستوديو", systemImage: "sparkles")
                        Text("افتح أي مشروع ثم من قائمة «الذكاء الاصطناعي»: مساعد المونتاج (بالكتابة أو بصوتك)، فحص الخطّاف قبل النشر، الاختصار الذكي، ترجمة الترجمة النصية، تعليق صوتي من نص، اقتراح موسيقى، وصورة مصغرة تلقائية. و«الكلام كنص» ← «اقتراحات الذكاء» لتنظيف الحشو والتكرار.")
                            .font(.callout)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("استوديو الذكاء")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { env.router.push(.aiSettings) } label: { Label("الإعدادات", systemImage: "gearshape") }
            }
        }
        .task { await AIModelManager.shared.refreshIfStale() }
    }

    private var statusCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: settings.cloudAvailable ? "sparkles" : "iphone")
                    .font(.title2)
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Palette.accentSoft))
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.cloudAvailable ? "Gemini مفعّل" : "على جهازك").font(.headline)
                    Text(settings.cloudAvailable
                         ? AIModelManager.shared.resolvedModel + " • " + Fmt.int(usage.today.requests) + " طلب اليوم"
                         : (settings.keySource == .none ? "أضف مفتاح Gemini المجاني لنتائج أذكى" : "Gemini متوقف من الإعدادات"))
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                if !settings.cloudAvailable {
                    Button("إعداد") { env.router.push(.aiSettings) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func toolCard(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Palette.accentSoft))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.left").foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(Theme.Palette.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.Palette.stroke))
        }
        .contentShape(Rectangle())
    }
}
