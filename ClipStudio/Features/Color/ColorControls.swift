//
//  ColorControls.swift
//  ClipStudio — Features/Color
//
//  Grading controls: 5-point tone curve editor, lift/gamma/gain color wheels
//  (hue + strength puck with a master slider) and an RGB + luma histogram.
//  All drawn left → right regardless of the Arabic layout.
//

import SwiftUI

// MARK: - Tone curve

struct CurveEditor: View {
    let points: [Double]
    let onChange: ([Double]) -> Void
    let onCommit: () -> Void

    @State private var dragging: Int?

    private static let inputs: [Double] = [0, 0.25, 0.5, 0.75, 1]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.surfaceHighlight.opacity(0.7))
                Canvas { context, canvasSize in
                    var grid = Path()
                    for i in 1..<4 {
                        let x = canvasSize.width * CGFloat(i) / 4
                        let y = canvasSize.height * CGFloat(i) / 4
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: canvasSize.height))
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    }
                    context.stroke(grid, with: .color(Theme.Palette.stroke), lineWidth: 1)
                    var diagonal = Path()
                    diagonal.move(to: CGPoint(x: 0, y: canvasSize.height))
                    diagonal.addLine(to: CGPoint(x: canvasSize.width, y: 0))
                    context.stroke(diagonal, with: .color(Theme.Palette.textTertiary.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    context.stroke(smoothCurve(in: canvasSize), with: .color(Theme.Palette.accent), lineWidth: 2.2)
                }
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(dragging == index ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle().inset(by: -12))
                        .position(point(index, in: size))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    dragging = index
                                    var updated = points
                                    updated[index] = Double(1 - min(max(value.location.y / max(size.height, 1), 0), 1))
                                    onChange(updated)
                                }
                                .onEnded { _ in
                                    dragging = nil
                                    onCommit()
                                }
                        )
                        .onTapGesture(count: 2) {
                            var updated = points
                            updated[index] = Self.inputs[index]
                            onChange(updated)
                            onCommit()
                        }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityLabel("منحنى الدرجات اللونية")
    }

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(Self.inputs[index]) * size.width, y: (1 - CGFloat(points[safe: index] ?? Self.inputs[index])) * size.height)
    }

    /// Catmull-Rom spline through the five control points.
    private func smoothCurve(in size: CGSize) -> Path {
        let pts = (0..<5).map { point($0, in: size) }
        var path = Path()
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Color wheels

/// Maps RGB offsets to a 2D chroma puck (hue angle + strength) and a master level.
enum WheelMath {
    static let maxChroma = 0.25

    static func master(_ offset: RGBOffset) -> Double { (offset.r + offset.g + offset.b) / 3 }

    /// Puck position in -1…1 (y up) from an offset.
    static func puck(_ offset: RGBOffset) -> CGPoint {
        let m = master(offset)
        let r = offset.r - m, g = offset.g - m, b = offset.b - m
        let x = (2 * r - g - b) / 2
        let y = (g - b) * sqrt(3) / 2
        return CGPoint(x: x / maxChroma, y: y / maxChroma)
    }

    static func offset(puck: CGPoint, master m: Double) -> RGBOffset {
        let x = Double(puck.x) * maxChroma
        let y = Double(puck.y) * maxChroma
        return RGBOffset(r: m + 2 * x / 3, g: m - x / 3 + y / sqrt(3), b: m - x / 3 - y / sqrt(3))
    }
}

struct ColorWheelView: View {
    let title: String
    let offset: RGBOffset
    let onChange: (RGBOffset) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let radius = side / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let puck = WheelMath.puck(offset)
                let clamped = clampedPuck(puck)
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: [.red, Color(red: 1, green: 0, blue: 1), .blue, .cyan, .green, .yellow, .red],
                                              center: .center))
                        .frame(width: side, height: side)
                        .opacity(0.85)
                    Circle()
                        .fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)], center: .center,
                                             startRadius: 0, endRadius: radius))
                        .frame(width: side, height: side)
                    Circle().strokeBorder(Theme.Palette.stroke, lineWidth: 1).frame(width: side, height: side)
                    Circle()
                        .fill(Theme.Palette.textPrimary)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .position(x: center.x + clamped.x * radius, y: center.y - clamped.y * radius)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let raw = CGPoint(x: (value.location.x - center.x) / max(radius, 1),
                                              y: -(value.location.y - center.y) / max(radius, 1))
                            onChange(WheelMath.offset(puck: clampedPuck(raw), master: WheelMath.master(offset)))
                        }
                        .onEnded { _ in onCommit() }
                )
                .onTapGesture(count: 2) {
                    onChange(WheelMath.offset(puck: .zero, master: WheelMath.master(offset)))
                    onCommit()
                }
            }
            .aspectRatio(1, contentMode: .fit)
            PrecisionSlider(title: "المستوى", value: Binding(get: { WheelMath.master(offset) }, set: { value in
                onChange(WheelMath.offset(puck: WheelMath.puck(offset), master: value))
            }), range: -0.5...0.5, defaultValue: 0, format: { Fmt.number($0 * 100, digits: 0) }) { editing in
                if !editing { onCommit() }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func clampedPuck(_ point: CGPoint) -> CGPoint {
        let length = sqrt(point.x * point.x + point.y * point.y)
        guard length > 1 else { return point }
        return CGPoint(x: point.x / length, y: point.y / length)
    }
}

// MARK: - Histogram

struct HistogramView: View {
    let histogram: RGBHistogram

    var body: some View {
        Canvas { context, size in
            func draw(_ values: [Float], _ color: Color) {
                guard values.count > 1 else { return }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) / CGFloat(values.count - 1) * size.width
                    path.addLine(to: CGPoint(x: x, y: size.height - CGFloat(sqrt(value)) * size.height))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.32)))
                context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 0.8)
            }
            draw(histogram.red, .red)
            draw(histogram.green, .green)
            draw(histogram.blue, .blue)
            draw(histogram.luma, .white)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityLabel("المدرج التكراري للألوان")
    }
}
