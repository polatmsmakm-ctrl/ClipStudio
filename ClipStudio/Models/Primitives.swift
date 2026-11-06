//
//  Primitives.swift
//  ClipStudio — Models
//
//  Codable value types shared by every engine: rational time, time ranges,
//  normalized geometry, colors, and the Interpolatable protocol used by keyframes.
//

import Foundation
import CoreMedia
import CoreGraphics
import CoreImage
import SwiftUI
import UIKit

// MARK: - Interpolation

protocol Interpolatable: Codable, Hashable {
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self
}

extension Double: Interpolatable {
    static func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

// MARK: - Time

/// Frame-accurate rational time (wraps CMTime value/timescale so it can be Codable).
struct TimeValue: Codable, Comparable, Hashable, CustomStringConvertible {
    var value: Int64
    var timescale: Int32

    static let defaultTimescale: Int32 = 60_000
    static let zero = TimeValue(value: 0, timescale: defaultTimescale)

    init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale > 0 ? timescale : TimeValue.defaultTimescale
    }

    init(_ time: CMTime) {
        if time.isValid && time.isNumeric {
            self.init(value: time.value, timescale: time.timescale)
        } else {
            self.init(value: 0, timescale: TimeValue.defaultTimescale)
        }
    }

    init(seconds: Double) {
        let safe = seconds.isFinite ? seconds : 0
        self.init(CMTime(seconds: safe, preferredTimescale: TimeValue.defaultTimescale))
    }

    var cm: CMTime { CMTime(value: value, timescale: timescale) }
    var seconds: Double { Double(value) / Double(timescale) }
    var description: String { Fmt.durationPrecise(seconds) }

    static func == (lhs: TimeValue, rhs: TimeValue) -> Bool { CMTimeCompare(lhs.cm, rhs.cm) == 0 }
    func hash(into hasher: inout Hasher) { hasher.combine(seconds) }
    static func < (lhs: TimeValue, rhs: TimeValue) -> Bool { CMTimeCompare(lhs.cm, rhs.cm) < 0 }
    static func + (lhs: TimeValue, rhs: TimeValue) -> TimeValue { TimeValue(CMTimeAdd(lhs.cm, rhs.cm)) }
    static func - (lhs: TimeValue, rhs: TimeValue) -> TimeValue { TimeValue(CMTimeSubtract(lhs.cm, rhs.cm)) }

    func scaled(by factor: Double) -> TimeValue {
        TimeValue(CMTimeMultiplyByFloat64(cm, multiplier: factor))
    }

    /// Rounds to the nearest frame boundary for the given frame rate.
    func snapped(toFrameRate fps: Double) -> TimeValue {
        guard fps > 0 else { return self }
        return TimeValue(seconds: (seconds * fps).rounded() / fps)
    }

    static func max(_ a: TimeValue, _ b: TimeValue) -> TimeValue { a < b ? b : a }
    static func min(_ a: TimeValue, _ b: TimeValue) -> TimeValue { a < b ? a : b }
}

struct TimeRangeValue: Codable, Hashable {
    var start: TimeValue
    var duration: TimeValue

    init(start: TimeValue, duration: TimeValue) {
        self.start = start
        self.duration = duration
    }

    init(start: TimeValue, end: TimeValue) {
        self.init(start: start, duration: end - start)
    }

    init(startSeconds: Double, endSeconds: Double) {
        self.init(start: TimeValue(seconds: startSeconds), end: TimeValue(seconds: Swift.max(startSeconds, endSeconds)))
    }

    init(_ range: CMTimeRange) {
        self.init(start: TimeValue(range.start), duration: TimeValue(range.duration))
    }

    var end: TimeValue { start + duration }
    var cm: CMTimeRange { CMTimeRange(start: start.cm, duration: duration.cm) }

    func contains(_ time: TimeValue) -> Bool { time >= start && time < end }
    func overlaps(_ other: TimeRangeValue) -> Bool { start < other.end && other.start < end }
}

// MARK: - Geometry

struct Vec2: Interpolatable {
    var x: Double
    var y: Double

    static let zero = Vec2(x: 0, y: 0)
    static let center = Vec2(x: 0.5, y: 0.5)
    static let one = Vec2(x: 1, y: 1)

    static func interpolate(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 {
        Vec2(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// Normalized rectangle (0…1) with a top-left origin, as seen by the user.
struct RectValue: Interpolatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = RectValue(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool {
        abs(x) < 0.0001 && abs(y) < 0.0001 && abs(width - 1) < 0.0001 && abs(height - 1) < 0.0001
    }

    /// Converts to Core Image coordinates (bottom-left origin) inside `extent`.
    func ciRect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + CGFloat(x) * extent.width,
               y: extent.minY + CGFloat(1 - y - height) * extent.height,
               width: CGFloat(width) * extent.width,
               height: CGFloat(height) * extent.height)
    }

    func clamped() -> RectValue {
        let w = Swift.min(Swift.max(width, 0.02), 1)
        let h = Swift.min(Swift.max(height, 0.02), 1)
        return RectValue(x: Swift.min(Swift.max(x, 0), 1 - w), y: Swift.min(Swift.max(y, 0), 1 - h), width: w, height: h)
    }

    static func interpolate(_ a: RectValue, _ b: RectValue, _ t: Double) -> RectValue {
        RectValue(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                  width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

// MARK: - Color

struct RGBAColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255, a: alpha)
    }

    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha))
    }

    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    static let chromaGreen = RGBAColor(r: 0.0, g: 0.85, b: 0.25)

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var uiColor: UIColor { UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var ciColor: CIColor { CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var cgColor: CGColor { uiColor.cgColor }
}

// MARK: - Decoding helpers (forward-compatible JSON)

extension KeyedDecodingContainer {
    /// Decodes a value or falls back to `defaultValue` when the key is missing or invalid.
    /// Keeps old project files readable after new fields are added in later parts.
    func value<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
        if let decoded = try? decodeIfPresent(T.self, forKey: key) {
            return decoded
        }
        return defaultValue
    }
}
