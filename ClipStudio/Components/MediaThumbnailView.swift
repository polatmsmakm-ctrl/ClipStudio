//
//  MediaThumbnailView.swift
//  ClipStudio — Components
//
//  Async thumbnail for library assets, exported files and story segments.
//

import SwiftUI

struct MediaThumbnailView: View {
    enum Source: Hashable {
        case asset(MediaAsset, URL, Double)
        case file(URL, Double)
    }

    let source: Source
    var cornerRadius: CGFloat = Theme.Radius.sm
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.Palette.surfaceRaised
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: source) { await load() }
    }

    private var placeholderSymbol: String {
        if case .asset(let asset, _, _) = source { return asset.kind.symbol }
        return "film"
    }

    private func load() async {
        let result: UIImage?
        switch source {
        case .asset(let asset, let url, let seconds):
            result = await ThumbnailService.shared.thumbnail(url: url, kind: asset.kind,
                                                             cacheKey: "\(asset.id.uuidString)-\(Int(seconds * 10))",
                                                             at: seconds)
        case .file(let url, let seconds):
            result = await ThumbnailService.shared.thumbnail(url: url, kind: .video,
                                                             cacheKey: "\(url.lastPathComponent)-\(Int(seconds * 10))",
                                                             at: seconds)
        }
        withAnimation(.easeOut(duration: 0.2)) { image = result }
    }
}
