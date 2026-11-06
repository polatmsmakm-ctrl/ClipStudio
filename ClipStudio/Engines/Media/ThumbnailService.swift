//
//  ThumbnailService.swift
//  ClipStudio — Engines/Media
//
//  Memory + disk thumbnail cache. Video frames use AVAssetImageGenerator,
//  images use ImageIO downsampling (never decodes full-size images).
//

import Foundation
import UIKit
import AVFoundation
import ImageIO
import CryptoKit

final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    private let memory = NSCache<NSString, UIImage>()
    private let storage = StorageManager.shared

    private init() {
        memory.countLimit = 400
    }

    func thumbnail(url: URL, kind: MediaKind, cacheKey: String, at seconds: Double = 1, maxPixel: CGFloat = 480) async -> UIImage? {
        let key = cacheKey as NSString
        if let cached = memory.object(forKey: key) { return cached }
        let diskURL = storage.thumbnailsDirectory.appendingPathComponent(Self.fileName(for: cacheKey))
        if let data = try? Data(contentsOf: diskURL), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key)
            return image
        }
        let generated: UIImage?
        switch kind {
        case .image: generated = Self.imageThumbnail(url: url, maxPixel: maxPixel)
        case .video: generated = await Self.videoFrame(url: url, seconds: seconds, maxPixel: maxPixel, precise: false)
        case .audio: generated = nil
        }
        if let generated {
            memory.setObject(generated, forKey: key)
            if let data = generated.jpegData(compressionQuality: 0.8) { try? data.write(to: diskURL, options: .atomic) }
        }
        return generated
    }

    /// Exact frame (zero tolerance) — used by cut-point editors. Not cached.
    func exactFrame(url: URL, seconds: Double, maxPixel: CGFloat = 640) async -> UIImage? {
        await Self.videoFrame(url: url, seconds: seconds, maxPixel: maxPixel, precise: true)
    }

    func removeCached(prefix: String) {
        memory.removeAllObjects()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storage.thumbnailsDirectory, includingPropertiesForKeys: nil) else { return }
        let hashedPrefix = Self.hash(prefix).prefix(8)
        for file in files where file.lastPathComponent.hasPrefix(String(hashedPrefix)) {
            try? fm.removeItem(at: file)
        }
    }

    func clearMemory() { memory.removeAllObjects() }

    // MARK: Generators

    private static func videoFrame(url: URL, seconds: Double, maxPixel: CGFloat, precise: Bool) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var target = max(0, seconds)
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            target = min(target, max(0, duration.seconds - 0.05))
        }
        do {
            let result = try await generator.image(at: CMTime(seconds: target, preferredTimescale: 60_000))
            return UIImage(cgImage: result.image)
        } catch {
            return nil
        }
    }

    private static func imageThumbnail(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Keys

    /// File names start with a hash of the asset id prefix so `removeCached(prefix:)` can find them.
    private static func fileName(for key: String) -> String {
        let idPart = String(key.prefix(36))
        return String(hash(idPart).prefix(8)) + "-" + hash(key) + ".jpg"
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
