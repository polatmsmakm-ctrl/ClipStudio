//
//  StyleSharing.swift
//  ClipStudio — Engines/Presets (Part 4 suggestions)
//
//  Share editing styles (.csstyle) and templates (.cstemplate) with friends as
//  small JSON files, and import them back with new identifiers (nothing local is
//  ever overwritten). Template files carry the timeline and slots, not media:
//  slots are filled with the importer's own photos / videos, and template music
//  that isn't in the importer's library is dropped when the template is used.
//

import Foundation
import UniformTypeIdentifiers

struct SharedStyleFile: Codable {
    var kind = "clipstudio.style"
    var version = 1
    var style: EditingDNA
}

struct SharedTemplateFile: Codable {
    var kind = "clipstudio.template"
    var version = 1
    var template: StudioTemplate
}

enum SharedItem {
    case style(EditingDNA)
    case template(StudioTemplate)
}

enum StyleSharingError: LocalizedError {
    case unreadable
    case unknownKind

    var errorDescription: String? {
        switch self {
        case .unreadable: "تعذرت قراءة الملف."
        case .unknownKind: "هذا الملف ليس أسلوبًا ولا قالبًا من ClipStudio."
        }
    }
}

enum StyleSharing {
    static let styleExtension = "csstyle"
    static let templateExtension = "cstemplate"

    static var importTypes: [UTType] {
        var types: [UTType] = [.json]
        if let style = UTType(filenameExtension: styleExtension) { types.append(style) }
        if let template = UTType(filenameExtension: templateExtension) { types.append(template) }
        types.append(.data)
        return types
    }

    private static func outputURL(name: String, ext: String) -> URL {
        let folder = StorageManager.shared.stagingDirectory.appendingPathComponent("share-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(StorageManager.shared.sanitizedFileName(name)).appendingPathExtension(ext)
    }

    static func exportStyle(_ dna: EditingDNA) throws -> URL {
        var copy = dna
        copy.isBuiltIn = false
        let url = outputURL(name: dna.name, ext: styleExtension)
        try JSONStore.save(SharedStyleFile(style: copy), to: url)
        return url
    }

    static func exportTemplate(_ template: StudioTemplate) throws -> URL {
        let url = outputURL(name: template.name, ext: templateExtension)
        try JSONStore.save(SharedTemplateFile(template: template), to: url)
        return url
    }

    /// Reads a shared file; returned items get fresh identifiers.
    static func read(_ url: URL) throws -> SharedItem {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw StyleSharingError.unreadable }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> SharedItem {
        let decoder = JSONStore.makeDecoder()
        if let file = try? decoder.decode(SharedStyleFile.self, from: data), file.kind == "clipstudio.style" {
            var style = file.style
            style.id = UUID()
            style.isBuiltIn = false
            style.createdAt = Date()
            return .style(style)
        }
        if let file = try? decoder.decode(SharedTemplateFile.self, from: data), file.kind == "clipstudio.template" {
            var template = file.template
            template.id = UUID()
            template.createdAt = Date()
            return .template(template)
        }
        throw StyleSharingError.unknownKind
    }
}
