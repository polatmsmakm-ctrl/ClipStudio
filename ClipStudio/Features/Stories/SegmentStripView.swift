//
//  SegmentStripView.swift
//  ClipStudio — Features/Stories
//
//  Overview strip of the whole source: segments, scene/pause markers and the
//  playhead. Time always flows left → right, even in the Arabic RTL UI.
//

import SwiftUI

struct SegmentStripView: View {
    let duration: Double
    let segments: [StorySegment]
    let scenes: [Double]
    let pauses: [Double]
    let playhead: Double
    let selectedID: UUID?
    let onSelect: (StorySegment) -> Void
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let scale = duration > 0 ? width / CGFloat(duration) : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))

                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let x = CGFloat(segment.range.start.seconds) * scale
                    let w = max(2, CGFloat(segment.range.duration.seconds) * scale - 2)
                    let isSelected = segment.id == selectedID
                    RoundedRectangle(cornerRadius: 6)
                        .fill(segment.isIncluded
                              ? (index.isMultiple(of: 2) ? Theme.Palette.segmentA : Theme.Palette.segmentB)
                              : Color.white.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
                        .overlay {
                            if w > 22 {
                                Text(Fmt.int(index + 1))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(segment.isIncluded ? Color(hex: 0x1A1408) : Theme.Palette.textSecondary)
                            }
                        }
                        .frame(width: w, height: 34)
                        .offset(x: x + 1, y: 7)
                        .onTapGesture { onSelect(segment) }
                }

                ForEach(Array(scenes.enumerated()), id: \.offset) { _, time in
                    Rectangle().fill(Color.white.opacity(0.7))
                        .frame(width: 1, height: 8)
                        .offset(x: CGFloat(time) * scale, y: 0)
                }
                ForEach(Array(pauses.enumerated()), id: \.offset) { _, time in
                    Circle().fill(Theme.Palette.success.opacity(0.9))
                        .frame(width: 4, height: 4)
                        .offset(x: CGFloat(time) * scale - 2, y: 43)
                }

                Rectangle().fill(Color.white)
                    .frame(width: 2, height: 48)
                    .offset(x: min(width - 2, max(0, CGFloat(playhead) * scale - 1)))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6).onChanged { value in
                guard scale > 0 else { return }
                onSeek(Double(min(max(0, value.location.x), width) / scale))
            })
        }
        .frame(height: 48)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("شريط المقاطع: " + Fmt.int(segments.count) + " مقطع")
    }
}
