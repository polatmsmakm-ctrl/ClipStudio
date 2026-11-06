//
//  Controls.swift
//  ClipStudio — Components
//
//  Buttons, chips, tool tiles, precise numeric input and the keyboard "تم" bar.
//

import SwiftUI
import UIKit

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(hex: 0x1A1408))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Palette.surfaceHighlight))
            }
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(color: Theme.Palette.accent.opacity(isEnabled ? 0.28 : 0), radius: 12, y: 6)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Theme.Space.sm)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.surfaceHighlight.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.Palette.stroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var csPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var csSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Chips & tiles

struct ChipButton: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? Color(hex: 0x1A1408) : Theme.Palette.textPrimary)
            .background(Capsule().fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Palette.surfaceHighlight)))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.Palette.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ToolTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Palette.accentSoft))
                    Spacer()
                    if let badge { StatusPill(text: badge) }
                }
                Text(title).font(.headline).foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(Theme.Palette.surface.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.Palette.stroke))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Numeric input

/// Precise numeric field with −/+ steppers; accepts Arabic or English digits.
struct DecimalField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...10_000
    var step: Double = 1
    var digits: Int = 1
    var unit: String = ""

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 4)
            Button { adjust(-step) } label: { Image(systemName: "minus") }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.Palette.surfaceHighlight))
                .accessibilityLabel("إنقاص " + title)
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .frame(width: 76)
                .focused($focused)
                .onSubmit(commit)
                .environment(\.layoutDirection, .leftToRight)
            Button { adjust(step) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.Palette.surfaceHighlight))
                .accessibilityLabel("زيادة " + title)
            if !unit.isEmpty {
                Text(unit).font(.caption).foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .onAppear { text = format(value) }
        .onChange(of: value) { _, newValue in
            if !focused { text = format(newValue) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func adjust(_ delta: Double) {
        Haptics.selection()
        value = min(max(value + delta, range.lowerBound), range.upperBound)
        text = format(value)
    }

    private func commit() {
        if let parsed = Fmt.parseNumber(text) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        text = format(value)
    }

    private func format(_ v: Double) -> String { Fmt.number(v, digits: digits) }
}

// MARK: - Keyboard

extension View {
    /// Adds a "تم" button above the keyboard. Apply once per screen/sheet root.
    func keyboardDoneToolbar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("تم") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Haptics

enum Haptics {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.Keys.haptics) as? Bool ?? true
    }

    static func tap() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func selection() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
