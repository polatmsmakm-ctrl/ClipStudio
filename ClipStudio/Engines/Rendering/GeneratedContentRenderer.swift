//
//  GeneratedContentRenderer.swift
//  ClipStudio — Engines/Rendering (SubtitleEngine / text & graphics rendering)
//
//  Renders text (TextKit — correct Arabic shaping and RTL), title designs (lower
//  thirds, frames, underline, banner, quote), dynamic captions with per-word
//  highlighting (color, karaoke, moving box, word-by-word, reveal), shapes and
//  stickers to CIImages. Images are cached per content / canvas / animation step
//  (typewriter progress or active caption word), so playback renders each state once.
//  TextAnimator provides entrance/exit and loop animation states.
//

import Foundation
import UIKit
import CoreImage

final class GeneratedContentRenderer: @unchecked Sendable {
    static let shared = GeneratedContentRenderer()
    private let cache = NSCache<NSString, CIImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for content: GeneratedContent, canvas: CGSize, localTime: Double, clipDuration: Double) -> CIImage? {
        var visibleFraction = 1.0
        var activeWord: Int? = nil
        var variant = "s"
        if case .text(let text) = content {
            if let caption = text.caption, caption.highlight != .none {
                activeWord = caption.activeWordIndex(at: localTime)
                variant = "w" + String(activeWord ?? -1)
            } else if text.animationIn == .typewriter {
                visibleFraction = TextAnimator.typewriterFraction(localTime: localTime, duration: clipDuration)
                variant = "t" + String(Int((visibleFraction * 100).rounded()))
            }
        }
        let key = "\(content.hashValue)|\(Int(canvas.width))x\(Int(canvas.height))|\(variant)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let rendered: UIImage?
        switch content {
        case .text(let text):
            if let caption = text.caption {
                rendered = renderCaption(text, caption: caption, canvas: canvas, activeWord: activeWord)
            } else if text.design == .plain {
                rendered = renderPlain(text, canvas: canvas, visibleFraction: visibleFraction)
            } else {
                rendered = renderTitle(text, canvas: canvas, visibleFraction: visibleFraction)
            }
        case .shape(let shape): rendered = renderShape(shape, canvas: canvas)
        case .sticker(let sticker): rendered = renderSticker(sticker, canvas: canvas)
        }
        guard let cgImage = rendered?.cgImage else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    func clear() { cache.removeAllObjects() }

    // MARK: Text helpers

    private func font(_ style: TextStyle, size: CGFloat, weight: FontWeightOption? = nil) -> UIFont {
        if let name = style.fontName, let custom = UIFont(name: name, size: size) { return custom }
        return UIFont.systemFont(ofSize: size, weight: (weight ?? style.weight).uiWeight)
    }

    private func attributes(_ style: TextStyle, font: UIFont, fontSize: CGFloat, color: RGBAColor? = nil,
                            alignment: NSTextAlignment? = nil, shadow: Bool = true) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment ?? style.alignment.nsAlignment
        paragraph.lineSpacing = CGFloat(style.lineSpacing) * fontSize
        paragraph.baseWritingDirection = .natural
        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (color ?? style.color).uiColor,
            .paragraphStyle: paragraph
        ]
        if abs(style.kerning) > 0.0001 { result[.kern] = CGFloat(style.kerning) * fontSize }
        if let outline = style.outlineColor, style.outlineWidth > 0 {
            result[.strokeColor] = outline.uiColor
            result[.strokeWidth] = -CGFloat(style.outlineWidth)
        }
        if shadow, let shadowColor = style.shadowColor, style.shadowRadius > 0 {
            let value = NSShadow()
            value.shadowColor = shadowColor.uiColor
            value.shadowBlurRadius = CGFloat(style.shadowRadius) * fontSize / 60
            value.shadowOffset = CGSize(width: 0, height: CGFloat(style.shadowOffsetY) * fontSize / 60)
            result[.shadow] = value
        }
        return result
    }

    private func measure(_ attributed: NSAttributedString, maxWidth: CGFloat) -> CGRect {
        attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
    }

    private func visible(_ text: String, fraction: Double) -> String {
        guard fraction < 1 else { return text }
        let count = Int((Double(text.count) * fraction).rounded(.down))
        return String(text.prefix(max(0, count)))
    }

    private func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: max(1, ceil(size.width)), height: max(1, ceil(size.height))), format: format)
    }

    // MARK: Plain text

    private func renderPlain(_ content: TextContent, canvas: CGSize, visibleFraction: Double) -> UIImage? {
        let style = content.style
        let fontSize = max(8, CGFloat(style.sizeRatio) * canvas.height)
        let text = visible(content.text, fraction: visibleFraction)
        guard !text.isEmpty else { return transparentPixel() }
        let attributed = NSAttributedString(string: text, attributes: attributes(style, font: font(style, size: fontSize), fontSize: fontSize))
        let maxWidth = max(40, CGFloat(style.maxWidthRatio) * canvas.width)
        let bounds = measure(attributed, maxWidth: maxWidth)
        let padding = style.backgroundColor != nil ? CGFloat(style.backgroundPadding) * fontSize : fontSize * 0.2
        let size = CGSize(width: bounds.width + padding * 2, height: bounds.height + padding * 2)
        return renderer(size).image { _ in
            if let background = style.backgroundColor {
                background.uiColor.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: CGFloat(style.cornerRadius) * fontSize).fill()
            }
            attributed.draw(with: CGRect(x: padding, y: padding, width: bounds.width, height: bounds.height),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    // MARK: Title designs

    private func renderTitle(_ content: TextContent, canvas: CGSize, visibleFraction: Double) -> UIImage? {
        let style = content.style
        let fontSize = max(8, CGFloat(style.sizeRatio) * canvas.height)
        let rtl = ScriptDirection.isRightToLeft(content.text + content.subtitle)
        let title = visible(content.text, fraction: visibleFraction)
        let subtitle = content.design.usesSubtitle ? content.subtitle.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !title.isEmpty || !subtitle.isEmpty else { return transparentPixel() }
        let accent = content.accentColor.uiColor
        let maxWidth = max(60, CGFloat(style.maxWidthRatio) * canvas.width)

        switch content.design {
        case .plain:
            return renderPlain(content, canvas: canvas, visibleFraction: visibleFraction)

        case .boxed, .underline:
            let main = NSAttributedString(string: title, attributes: attributes(style, font: font(style, size: fontSize), fontSize: fontSize))
            let bounds = measure(main, maxWidth: maxWidth)
            let pad = fontSize * (content.design == .boxed ? 0.5 : 0.2)
            let barHeight = max(2, fontSize * 0.1)
            let gap = fontSize * 0.18
            let extra = content.design == .underline ? gap + barHeight : 0
            let size = CGSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2 + extra)
            return renderer(size).image { _ in
                let frame = CGRect(x: 0, y: 0, width: size.width, height: bounds.height + pad * 2)
                if let background = style.backgroundColor {
                    background.uiColor.setFill()
                    UIBezierPath(roundedRect: frame, cornerRadius: CGFloat(style.cornerRadius) * fontSize).fill()
                }
                if content.design == .boxed {
                    let line = max(2, fontSize * 0.07)
                    accent.setStroke()
                    let path = UIBezierPath(roundedRect: frame.insetBy(dx: line / 2, dy: line / 2),
                                            cornerRadius: CGFloat(style.cornerRadius) * fontSize)
                    path.lineWidth = line
                    path.stroke()
                }
                main.draw(with: CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                if content.design == .underline {
                    accent.setFill()
                    let barWidth = bounds.width
                    UIBezierPath(roundedRect: CGRect(x: pad, y: pad + bounds.height + gap, width: barWidth, height: barHeight),
                                 cornerRadius: barHeight / 2).fill()
                }
            }

        case .banner:
            let main = NSAttributedString(string: title, attributes: attributes(style, font: font(style, size: fontSize), fontSize: fontSize,
                                                                                alignment: .center))
            let subSize = fontSize * 0.55
            let sub = NSAttributedString(string: subtitle, attributes: attributes(style, font: font(style, size: subSize, weight: .medium),
                                                                                 fontSize: subSize, color: style.color.withAlpha(0.88),
                                                                                 alignment: .center))
            let width = canvas.width
            let mainBounds = title.isEmpty ? .zero : measure(main, maxWidth: width * 0.9)
            let subBounds = subtitle.isEmpty ? .zero : measure(sub, maxWidth: width * 0.9)
            let pad = fontSize * 0.5
            let spacing = subtitle.isEmpty || title.isEmpty ? 0 : fontSize * 0.15
            let size = CGSize(width: width, height: mainBounds.height + subBounds.height + spacing + pad * 2)
            return renderer(size).image { _ in
                (style.backgroundColor?.uiColor ?? accent.withAlphaComponent(0.92)).setFill()
                UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
                if !title.isEmpty {
                    main.draw(with: CGRect(x: (width - mainBounds.width) / 2, y: pad, width: mainBounds.width, height: mainBounds.height),
                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
                if !subtitle.isEmpty {
                    sub.draw(with: CGRect(x: (width - subBounds.width) / 2, y: pad + mainBounds.height + spacing,
                                          width: subBounds.width, height: subBounds.height),
                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
            }

        case .lowerThird:
            let alignment: NSTextAlignment = rtl ? .right : .left
            let main = NSAttributedString(string: title, attributes: attributes(style, font: font(style, size: fontSize), fontSize: fontSize,
                                                                                alignment: alignment))
            let subSize = fontSize * 0.6
            let sub = NSAttributedString(string: subtitle, attributes: attributes(style, font: font(style, size: subSize, weight: .regular),
                                                                                 fontSize: subSize, color: style.color.withAlpha(0.85),
                                                                                 alignment: alignment))
            let mainBounds = title.isEmpty ? .zero : measure(main, maxWidth: maxWidth)
            let subBounds = subtitle.isEmpty ? .zero : measure(sub, maxWidth: maxWidth)
            let textWidth = max(mainBounds.width, subBounds.width)
            let spacing = subtitle.isEmpty || title.isEmpty ? 0 : fontSize * 0.12
            let textHeight = mainBounds.height + spacing + subBounds.height
            let pad = fontSize * 0.42
            let barWidth = max(3, fontSize * 0.14)
            let gap = fontSize * 0.35
            let size = CGSize(width: pad * 2 + barWidth + gap + textWidth, height: pad * 2 + textHeight)
            return renderer(size).image { _ in
                (style.backgroundColor?.uiColor ?? UIColor(white: 0, alpha: 0.55)).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: CGFloat(style.cornerRadius) * fontSize * 0.5).fill()
                let barX = rtl ? size.width - pad - barWidth : pad
                accent.setFill()
                UIBezierPath(roundedRect: CGRect(x: barX, y: pad, width: barWidth, height: textHeight), cornerRadius: barWidth / 2).fill()
                let textX = rtl ? pad : pad + barWidth + gap
                if !title.isEmpty {
                    main.draw(with: CGRect(x: textX, y: pad, width: textWidth, height: mainBounds.height),
                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
                if !subtitle.isEmpty {
                    sub.draw(with: CGRect(x: textX, y: pad + mainBounds.height + spacing, width: textWidth, height: subBounds.height),
                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
            }

        case .quote:
            let main = NSAttributedString(string: title, attributes: attributes(style, font: font(style, size: fontSize), fontSize: fontSize))
            let subSize = fontSize * 0.6
            let attribution = subtitle.isEmpty ? "" : "— " + subtitle
            let sub = NSAttributedString(string: attribution, attributes: attributes(style, font: font(style, size: subSize, weight: .medium),
                                                                                    fontSize: subSize, color: content.accentColor))
            let mainBounds = title.isEmpty ? .zero : measure(main, maxWidth: maxWidth)
            let subBounds = attribution.isEmpty ? .zero : measure(sub, maxWidth: maxWidth)
            let markSize = fontSize * 1.4
            let pad = fontSize * 0.3
            let spacing = fontSize * 0.2
            let width = max(mainBounds.width, subBounds.width, markSize)
            let size = CGSize(width: width + pad * 2, height: pad * 2 + markSize + spacing + mainBounds.height
                              + (attribution.isEmpty ? 0 : spacing + subBounds.height))
            let configuration = UIImage.SymbolConfiguration(pointSize: markSize, weight: .heavy)
            let mark = UIImage(systemName: rtl ? "quote.closing" : "quote.opening", withConfiguration: configuration)?
                .withTintColor(accent, renderingMode: .alwaysOriginal)
            return renderer(size).image { _ in
                if let background = style.backgroundColor {
                    background.uiColor.setFill()
                    UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: CGFloat(style.cornerRadius) * fontSize).fill()
                }
                if let mark {
                    let markWidth = mark.size.width * markSize / max(1, mark.size.height)
                    let x = rtl ? size.width - pad - markWidth : pad
                    mark.draw(in: CGRect(x: x, y: pad, width: markWidth, height: markSize))
                }
                var y = pad + markSize + spacing
                let textX = pad + (width - mainBounds.width) * alignmentFactor(style.alignment, rtl: rtl)
                main.draw(with: CGRect(x: textX, y: y, width: mainBounds.width, height: mainBounds.height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += mainBounds.height + spacing
                if !attribution.isEmpty {
                    let subX = pad + (width - subBounds.width) * alignmentFactor(style.alignment, rtl: rtl)
                    sub.draw(with: CGRect(x: subX, y: y, width: subBounds.width, height: subBounds.height),
                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
            }
        }
    }

    /// 0 = left, 0.5 = center, 1 = right placement of a block inside a wider box.
    private func alignmentFactor(_ alignment: TextAlignmentOption, rtl: Bool) -> CGFloat {
        switch alignment {
        case .center: 0.5
        case .leading: rtl ? 1 : 0
        case .trailing: 1
        }
    }

    // MARK: Captions

    private func renderCaption(_ content: TextContent, caption: CaptionInfo, canvas: CGSize, activeWord: Int?) -> UIImage? {
        let style = content.style
        let fontSize = max(8, CGFloat(style.sizeRatio) * canvas.height)
        let baseFont = font(style, size: fontSize)
        var words = caption.words
        var active = caption.highlight == .none ? nil : activeWord
        if caption.highlight == .single {
            guard let index = activeWord, words.indices.contains(index) else { return transparentPixel() }
            words = [CaptionWord(text: words[index].text, start: words[index].start, end: words[index].end)]
            active = 0
        }
        guard !words.isEmpty else { return transparentPixel() }

        let base = attributes(style, font: baseFont, fontSize: fontSize)
        let attributed = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (index, word) in words.enumerated() {
            if index > 0 { attributed.append(NSAttributedString(string: word.breaksLine ? "\n" : " ", attributes: base)) }
            var attrs = base
            switch caption.highlight {
            case .word, .box:
                if index == active { attrs[.foregroundColor] = caption.highlightColor.uiColor }
            case .karaoke:
                if let active, index <= active { attrs[.foregroundColor] = caption.highlightColor.uiColor }
            case .reveal:
                if active == nil || index > (active ?? -1) {
                    attrs[.foregroundColor] = UIColor.clear
                    attrs[.strokeColor] = UIColor.clear
                    attrs.removeValue(forKey: .shadow)
                }
            case .single, .none:
                break
            }
            let location = attributed.length
            attributed.append(NSAttributedString(string: word.text, attributes: attrs))
            ranges.append(NSRange(location: location, length: attributed.length - location))
        }

        let maxWidth = max(40, CGFloat(style.maxWidthRatio) * canvas.width)
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).integral
        let padding = style.backgroundColor != nil ? CGFloat(style.backgroundPadding) * fontSize : fontSize * 0.3
        let size = CGSize(width: used.width + padding * 2, height: used.height + padding * 2)
        let origin = CGPoint(x: padding - used.minX, y: padding - used.minY)

        return renderer(size).image { _ in
            if let background = style.backgroundColor {
                background.uiColor.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: CGFloat(style.cornerRadius) * fontSize).fill()
            }
            if caption.highlight == .box, let active, ranges.indices.contains(active) {
                let glyphs = manager.glyphRange(forCharacterRange: ranges[active], actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: -fontSize * 0.16, dy: -fontSize * 0.06)
                caption.boxColor.uiColor.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: fontSize * 0.18).fill()
            }
            let glyphRange = manager.glyphRange(for: container)
            manager.drawBackground(forGlyphRange: glyphRange, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        }
    }

    // MARK: Shapes

    private func renderShape(_ shape: ShapeContent, canvas: CGSize) -> UIImage? {
        let size = CGSize(width: max(2, CGFloat(shape.size.x) * canvas.width), height: max(2, CGFloat(shape.size.y) * canvas.height))
        let stroke = CGFloat(shape.strokeWidth) * canvas.height
        let inset = shape.stroke != nil ? stroke / 2 : 0
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        return renderer(size).image { _ in
            let path = Self.path(for: shape, in: rect)
            if let fill = shape.fill, shape.kind != .line {
                fill.uiColor.setFill()
                path.fill()
            }
            if let strokeColor = shape.stroke ?? (shape.kind == .line ? shape.fill : nil) {
                strokeColor.uiColor.setStroke()
                path.lineWidth = max(1, stroke)
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
        }
    }

    static func path(for shape: ShapeContent, in rect: CGRect) -> UIBezierPath {
        switch shape.kind {
        case .rectangle:
            return UIBezierPath(rect: rect)
        case .roundedRectangle:
            return UIBezierPath(roundedRect: rect, cornerRadius: CGFloat(shape.cornerRadius) * min(rect.width, rect.height))
        case .ellipse:
            return UIBezierPath(ovalIn: rect)
        case .triangle:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.close()
            return path
        case .line:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        case .star:
            let path = UIBezierPath()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerX = rect.width / 2, outerY = rect.height / 2
            for index in 0..<10 {
                let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / 5
                let factor: CGFloat = index.isMultiple(of: 2) ? 1 : 0.45
                let point = CGPoint(x: center.x + cos(angle) * outerX * factor, y: center.y + sin(angle) * outerY * factor)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close()
            return path
        case .arrow:
            let path = UIBezierPath()
            let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
            path.move(to: CGPoint(x: x, y: y + h * 0.34))
            path.addLine(to: CGPoint(x: x + w * 0.6, y: y + h * 0.34))
            path.addLine(to: CGPoint(x: x + w * 0.6, y: y))
            path.addLine(to: CGPoint(x: x + w, y: y + h * 0.5))
            path.addLine(to: CGPoint(x: x + w * 0.6, y: y + h))
            path.addLine(to: CGPoint(x: x + w * 0.6, y: y + h * 0.66))
            path.addLine(to: CGPoint(x: x, y: y + h * 0.66))
            path.close()
            return path
        case .heart:
            let path = UIBezierPath()
            let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
            path.move(to: CGPoint(x: x + w * 0.5, y: y + h))
            path.addCurve(to: CGPoint(x: x, y: y + h * 0.32),
                          controlPoint1: CGPoint(x: x + w * 0.1, y: y + h * 0.72),
                          controlPoint2: CGPoint(x: x, y: y + h * 0.52))
            path.addArc(withCenter: CGPoint(x: x + w * 0.25, y: y + h * 0.3), radius: w * 0.25,
                        startAngle: .pi, endAngle: 0, clockwise: true)
            path.addArc(withCenter: CGPoint(x: x + w * 0.75, y: y + h * 0.3), radius: w * 0.25,
                        startAngle: .pi, endAngle: 0, clockwise: true)
            path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h),
                          controlPoint1: CGPoint(x: x + w, y: y + h * 0.52),
                          controlPoint2: CGPoint(x: x + w * 0.9, y: y + h * 0.72))
            path.close()
            return path
        case .bubble:
            let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.8)
            let radius = CGFloat(max(0.1, shape.cornerRadius)) * min(body.width, body.height)
            let path = UIBezierPath(roundedRect: body, cornerRadius: radius)
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: body.minX + body.width * 0.18, y: body.maxY - 1))
            tail.addLine(to: CGPoint(x: body.minX + body.width * 0.12, y: rect.maxY))
            tail.addLine(to: CGPoint(x: body.minX + body.width * 0.36, y: body.maxY - 1))
            tail.close()
            path.append(tail)
            return path
        }
    }

    // MARK: Stickers

    private func renderSticker(_ sticker: StickerContent, canvas: CGSize) -> UIImage? {
        let side = max(16, CGFloat(sticker.sizeRatio) * canvas.height)
        if sticker.isEmoji {
            let font = UIFont.systemFont(ofSize: side * 0.8)
            let attributed = NSAttributedString(string: sticker.symbolName, attributes: [.font: font])
            let bounds = attributed.boundingRect(with: CGSize(width: side * 2, height: side * 2), options: [.usesLineFragmentOrigin], context: nil).integral
            return renderer(bounds.size).image { _ in
                attributed.draw(at: .zero)
            }
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: side, weight: .semibold)
        guard let symbol = UIImage(systemName: sticker.symbolName, withConfiguration: configuration)?
            .withTintColor(sticker.color.uiColor, renderingMode: .alwaysOriginal) else { return nil }
        return renderer(symbol.size).image { _ in
            symbol.draw(at: .zero)
        }
    }

    private func transparentPixel() -> UIImage {
        renderer(CGSize(width: 1, height: 1)).image { _ in }
    }
}

extension RGBAColor {
    func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: a * alpha) }
}

// MARK: - Text animation

enum TextAnimator {
    struct State {
        var opacity: Double
        var scale: Double
        var offset: Vec2
        /// Degrees.
        var rotation: Double = 0
        /// 0…1 blur amount.
        var blur: Double = 0
        /// 0…1 visible width fraction (wipe).
        var reveal: Double = 1

        static let identity = State(opacity: 1, scale: 1, offset: .zero)

        var isIdentity: Bool {
            abs(opacity - 1) < 0.0001 && abs(scale - 1) < 0.0001 && abs(offset.x) < 0.00001 && abs(offset.y) < 0.00001
                && abs(rotation) < 0.001 && blur < 0.001 && reveal > 0.999
        }
    }

    static let inDuration = 0.45
    static let outDuration = 0.35

    static func typewriterFraction(localTime: Double, duration: Double) -> Double {
        let span = min(max(0.4, duration * 0.5), 2.5)
        return min(1, max(0, localTime / span))
    }

    /// Entrance/exit plus loop animation of a generated clip (text and stickers).
    static func state(for clip: Clip, localTime t: Double, duration: Double) -> State {
        switch clip.source {
        case .text(let content):
            var state = Self.state(in: content.animationIn, out: content.animationOut, localTime: t, duration: duration)
            applyLoop(content.loop, time: t, to: &state)
            return state
        case .sticker(let content):
            var state = State.identity
            applyLoop(content.loop, time: t, to: &state)
            return state
        default:
            return .identity
        }
    }

    static func state(in animIn: TextAnimation, out animOut: TextAnimation, localTime t: Double, duration: Double) -> State {
        var state = State.identity
        let inProgress = min(1, max(0, t / inDuration))
        let outProgress = min(1, max(0, (duration - t) / outDuration))
        apply(animIn, progress: inProgress, to: &state, entering: true)
        apply(animOut, progress: outProgress, to: &state, entering: false)
        return state
    }

    private static func apply(_ animation: TextAnimation, progress raw: Double, to state: inout State, entering: Bool) {
        let p = entering ? Easing.easeOut.apply(raw) : Easing.easeIn.apply(raw)
        switch animation {
        case .none, .typewriter:
            break
        case .fade:
            state.opacity *= p
        case .slideUp:
            state.opacity *= p
            state.offset.y += (1 - p) * (entering ? 0.05 : -0.05)
        case .slideDown:
            state.opacity *= p
            state.offset.y += (1 - p) * (entering ? -0.05 : 0.05)
        case .pop:
            state.opacity *= min(1, p * 1.5)
            let overshoot = p < 1 ? 1 + 0.12 * sin(p * .pi) : 1
            state.scale *= max(0.01, (0.6 + 0.4 * p) * overshoot)
        case .zoomIn:
            state.opacity *= p
            state.scale *= max(0.01, 0.5 + 0.5 * p)
        case .blur:
            state.opacity *= min(1, 0.2 + p)
            state.blur = max(state.blur, 1 - p)
        case .wipe:
            state.reveal = min(state.reveal, max(0, min(1, raw)))
        case .bounce:
            let b = bounce(raw)
            state.opacity *= min(1, raw * 3)
            state.offset.y += (1 - b) * (entering ? -0.12 : 0.12)
        case .spin:
            state.opacity *= p
            state.rotation += (1 - p) * (entering ? -180 : 180)
            state.scale *= max(0.01, 0.3 + 0.7 * p)
        }
    }

    static func applyLoop(_ loop: LoopAnimation, time t: Double, to state: inout State) {
        switch loop {
        case .none:
            break
        case .pulse:
            state.scale *= 1 + 0.06 * sin(2 * .pi * t / 1.2)
        case .float:
            state.offset.y += 0.012 * sin(2 * .pi * t / 2.4)
        case .shake:
            state.offset.x += 0.005 * sin(2 * .pi * t * 7) * (0.6 + 0.4 * sin(2 * .pi * t * 1.3))
            state.rotation += 1.5 * sin(2 * .pi * t * 5)
        case .swing:
            state.rotation += 8 * sin(2 * .pi * t / 1.6)
        case .blink:
            state.opacity *= 0.55 + 0.45 * (0.5 + 0.5 * cos(2 * .pi * t / 1.0))
        case .rotate:
            state.rotation += 360 * t / 3.0
        }
    }

    /// Ease-out bounce (0…1).
    static func bounce(_ x: Double) -> Double {
        let n1 = 7.5625, d1 = 2.75
        var t = min(max(x, 0), 1)
        if t < 1 / d1 { return n1 * t * t }
        if t < 2 / d1 { t -= 1.5 / d1; return n1 * t * t + 0.75 }
        if t < 2.5 / d1 { t -= 2.25 / d1; return n1 * t * t + 0.9375 }
        t -= 2.625 / d1
        return n1 * t * t + 0.984375
    }
}
