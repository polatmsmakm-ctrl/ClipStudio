//
//  Cards.swift
//  ClipStudio — Components
//
//  Glass cards, section titles, stat badges and progress bars.
//

import SwiftUI

struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.md
    var cornerRadius: CGFloat = Theme.Radius.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.Palette.surface.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.stroke, lineWidth: 1))
            }
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(Theme.Palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typo.section).foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct StatBadge: View {
    let title: String
    let value: String
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.caption2) }
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.Palette.surfaceRaised.opacity(0.8)))
        .accessibilityElement(children: .combine)
    }
}

struct ProgressBarView: View {
    let progress: Double
    var tint: Color = Theme.Palette.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * CGFloat(min(max(progress, 0), 1))))
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
        }
        .frame(height: height)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityValue(Fmt.percent(progress))
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = Theme.Palette.accent
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}
