// =============================================================================
// ClipStudio — App icon generator (runs on the GitHub macOS runner).
// Usage: swift Scripts/generate_app_icon.swift <output.png>
// Draws a 1024×1024 opaque icon: charcoal gradient, soft gold glow, a gold
// rounded "frame" with a play triangle and three timeline bars.
// The workflow only runs this when AppIcon.png is missing, so a custom icon
// placed in the asset catalog always wins.
// =============================================================================

import Foundation
import CoreGraphics
import ImageIO

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    FileHandle.standardError.write("Could not create context\n".data(using: .utf8)!)
    exit(1)
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha
    ])!
}

let full = CGRect(x: 0, y: 0, width: size, height: size)

// Background gradient (top lighter charcoal → bottom near black). CG origin is bottom-left.
let bg = CGGradient(colorsSpace: colorSpace, colors: [rgb(0x0A0A0C), rgb(0x1B1C22)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

// Warm glow
let glow = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xE3B04B, 0.32), rgb(0xE3B04B, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 700), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 700), endRadius: 620, options: [])

// Frame
let frameRect = CGRect(x: 212, y: 300, width: 600, height: 470)
let framePath = CGPath(roundedRect: frameRect, cornerWidth: 96, cornerHeight: 96, transform: nil)
ctx.addPath(framePath)
ctx.setStrokeColor(rgb(0xE3B04B))
ctx.setLineWidth(34)
ctx.strokePath()

// Play triangle with gold gradient
let triangle = CGMutablePath()
triangle.move(to: CGPoint(x: 452, y: 418))
triangle.addLine(to: CGPoint(x: 452, y: 652))
triangle.addLine(to: CGPoint(x: 640, y: 535))
triangle.closeSubpath()
ctx.saveGState()
ctx.addPath(triangle)
ctx.clip()
let gold = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xF4CE7A), rgb(0xB9862B)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gold, start: CGPoint(x: 452, y: 652), end: CGPoint(x: 640, y: 418), options: [])
ctx.restoreGState()

// Timeline bars
let bars: [(CGFloat, CGFloat, CGFloat)] = [(212, 600, 1.0), (212, 420, 0.7), (212, 250, 0.45)]
for (index, bar) in bars.enumerated() {
    let y = 212 - CGFloat(index) * 54
    let rect = CGRect(x: bar.0, y: y, width: bar.1, height: 30)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.setFillColor(rgb(0xE3B04B, bar.2))
    ctx.fillPath()
}

guard let image = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
if !CGImageDestinationFinalize(destination) { exit(1) }
print("Wrote \(outputPath) (\(full.width)x\(full.height))")
