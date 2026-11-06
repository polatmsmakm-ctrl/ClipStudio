//
//  PrecisionSlider.swift
//  ClipStudio — Components
//
//  Pro value slider used by every inspector:
//  • drag horizontally to change; drag the finger down/up away from the track for
//    fine adjustment (×1 → ×0.5 → ×0.25 → ×0.1), like iOS scrubbing;
//  • double tap resets to the default value;
//  • tap the value to type an exact number (Arabic or English digits);
//  • optional keyframe diamond (add/remove at the playhead).
//  The track always runs left → right with English digits.
//

import SwiftUI

struct KeyframeControl {
    /// A keyframe exists at the playhead.
    var isOnKeyframe: Bool
    /// The property is animated.
    var isAnimated: Bool
    var toggle: () -> Void
}

struct PrecisionSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    /// Snaps to multiples of `step` (0 = continuous).
    var step: Double = 0
    var format: (Double) -> String = { Fmt.number($0, digits: 0) }
    /// Value shown/typed = value × displayScale (e.g. 100 for percentages).
    var displayScale: Double = 1
    var keyframe: KeyframeControl? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragStartValue: Double?
    @State private var fineFactor: Double = 1
    @State private var showEntry = false
    @State private var entryText = ""

    private var span: Double { max(range.upperBound - range.lowerBound, 0.000001) }

    private func fraction(_ v: Double) -> Double { (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer(minLength: 4)
                if fineFactor < 1 {
                    Text("دقيق ×" + Fmt.number(fineFactor, digits: fineFactor < 0.2 ? 1 : 2))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .transition(.opacity)
                }
                Button {
                    entryText = Fmt.number(value * displayScale, digits: step >= 1 ? 0 : 2)
                    showEntry = true
                } label: {
                    Text(format(value))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.Palette.surfaceHighlight))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + " " + format(value))
                if let keyframe {
                    Button(action: keyframe.toggle) {
                        Image(systemName: keyframe.isOnKeyframe ? "diamond.fill" : "diamond")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(keyframe.isAnimated ? Theme.Palette.accent : Theme.Palette.textTertiary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(keyframe.isOnKeyframe ? "إزالة الإطار المفتاحي" : "إضافة إطار مفتاحي")
                }
            }
            track
                .frame(height: 30)
                .environment(\.layoutDirection, .leftToRight)
        }
        .alert(title, isPresented: $showEntry) {
            TextField(title, text: $entryText)
                .keyboardType(.numbersAndPunctuation)
            Button("تم") { commitEntry() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("القيمة بين " + format(range.lowerBound) + " و " + format(range.upperBound))
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let thumbX = CGFloat(fraction(value)) * width
            let zeroX = CGFloat(fraction(defaultValue)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09)).frame(height: 4)
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: abs(thumbX - zeroX), height: 4)
                    .offset(x: min(thumbX, zeroX))
                Rectangle()
                    .fill(Theme.Palette.textTertiary)
                    .frame(width: 1.5, height: 10)
                    .offset(x: zeroX - 0.75)
                Circle()
                    .fill(Theme.Palette.textPrimary)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: dragStartValue == nil ? 0 : 2))
                    .offset(x: thumbX - 11)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            onEditingChanged(true)
                            let nearThumb = abs(gesture.startLocation.x - thumbX) < 26
                            if nearThumb {
                                dragStartValue = value
                            } else {
                                let jumped = range.lowerBound + Double(gesture.startLocation.x / width) * span
                                dragStartValue = quantized(jumped)
                                setValue(quantized(jumped))
                            }
                        }
                        let vertical = abs(gesture.translation.height)
                        let factor: Double = vertical < 40 ? 1 : vertical < 90 ? 0.5 : vertical < 150 ? 0.25 : 0.1
                        if factor != fineFactor {
                            withAnimation(.easeOut(duration: 0.15)) { fineFactor = factor }
                            Haptics.selection()
                        }
                        let delta = Double(gesture.translation.width / width) * span * factor
                        setValue(quantized((dragStartValue ?? value) + delta))
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        withAnimation(.easeOut(duration: 0.2)) { fineFactor = 1 }
                        onEditingChanged(false)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    setValue(defaultValue)
                    Haptics.tap()
                    onEditingChanged(false)
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let increment = step > 0 ? step : span / 100
            switch direction {
            case .increment: setValue(value + increment)
            case .decrement: setValue(value - increment)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }

    private func quantized(_ raw: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        return min(max((clamped / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    private func setValue(_ newValue: Double) {
        let q = quantized(newValue)
        let crossedDefault = (value - defaultValue) * (q - defaultValue) < 0 || (q == defaultValue && value != defaultValue)
        if crossedDefault { Haptics.selection() }
        if q != value { value = q }
    }

    private func commitEntry() {
        guard let parsed = Fmt.parseNumber(entryText) else { return }
        setValue(parsed / max(displayScale, 0.000001))
        onEditingChanged(false)
    }
}

/// A compact labeled row with a trailing control (toggle, picker…).
struct InspectorRow<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 22)
            }
            Text(title).font(.subheadline).foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 6)
            trailing
        }
        .frame(minHeight: 36)
    }
}

/// Grouped card used by inspectors.
struct InspectorSection<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.Palette.accent) }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.Palette.surfaceRaised.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.Palette.stroke))
    }
}
