//
//  Theme.swift
//  ClipStudio — Components (UIComponents)
//
//  Design tokens: deep charcoal surfaces, one "studio gold" accent,
//  spacing, radii and typography.
//

import SwiftUI

enum Theme {
    enum Palette {
        static let background = Color(hex: 0x0B0B0E)
        static let surface = Color(hex: 0x15161B)
        static let surfaceRaised = Color(hex: 0x1D1F25)
        static let surfaceHighlight = Color(hex: 0x262931)
        static let stroke = Color.white.opacity(0.08)
        static let textPrimary = Color(hex: 0xF2EFEA)
        static let textSecondary = Color(hex: 0xA39F99)
        static let textTertiary = Color(hex: 0x6E6A65)
        static let accent = Color(hex: 0xE3B04B)
        static let accentSoft = Color(hex: 0xE3B04B, opacity: 0.16)
        static let accentDeep = Color(hex: 0xB9862B)
        static let success = Color(hex: 0x5FC48F)
        static let warning = Color(hex: 0xE58F4A)
        static let danger = Color(hex: 0xE25C55)
        static let segmentA = Color(hex: 0xE3B04B, opacity: 0.85)
        static let segmentB = Color(hex: 0xC48F33, opacity: 0.85)
    }

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    enum Space {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Typo {
        static let hero = Font.system(size: 30, weight: .bold)
        static let title = Font.title2.weight(.bold)
        static let section = Font.headline.weight(.semibold)
        static let body = Font.body
        static let callout = Font.callout
        static let caption = Font.caption.weight(.medium)
        static let mono = Font.system(.caption, design: .monospaced).weight(.medium)
        static let monoLarge = Font.system(.title3, design: .monospaced).weight(.semibold)
    }

    static let accentGradient = LinearGradient(colors: [Color(hex: 0xF4CE7A), Palette.accent, Palette.accentDeep],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
