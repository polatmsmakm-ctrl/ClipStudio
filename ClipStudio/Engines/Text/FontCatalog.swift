//
//  FontCatalog.swift
//  ClipStudio — Engines/Text (Part 3)
//
//  Lists the fonts installed on the device (families and their faces) and marks
//  which ones contain Arabic letters, so the font picker can put Arabic fonts first.
//  Built once off the main thread and cached.
//

import Foundation
import UIKit
import CoreText

struct FontFace: Identifiable, Hashable {
    /// PostScript name (stored in TextStyle.fontName).
    let id: String
    let displayName: String
}

struct FontFamilyInfo: Identifiable, Hashable {
    let id: String
    let faces: [FontFace]
    let supportsArabic: Bool
}

actor FontCatalog {
    static let shared = FontCatalog()
    private var cached: [FontFamilyInfo]?

    func families() -> [FontFamilyInfo] {
        if let cached { return cached }
        let arabicProbe = "عربي" as CFString
        var result: [FontFamilyInfo] = []
        for family in UIFont.familyNames.sorted() {
            let names = UIFont.fontNames(forFamilyName: family).sorted()
            guard !names.isEmpty else { continue }
            let faces = names.map { name -> FontFace in
                let font = CTFontCreateWithName(name as CFString, 12, nil)
                let display = CTFontCopyDisplayName(font) as String
                return FontFace(id: name, displayName: display)
            }
            let probeFont = CTFontCreateWithName(names[0] as CFString, 12, nil)
            let characters = CTFontCopyCharacterSet(probeFont) as CharacterSet
            let supportsArabic = (arabicProbe as String).unicodeScalars.allSatisfy { characters.contains($0) }
            result.append(FontFamilyInfo(id: family, faces: faces, supportsArabic: supportsArabic))
        }
        let sorted = result.filter(\.supportsArabic) + result.filter { !$0.supportsArabic }
        cached = sorted
        return sorted
    }

    /// Family display name for a stored PostScript name.
    nonisolated static func familyName(of postScriptName: String?) -> String {
        guard let postScriptName, let font = UIFont(name: postScriptName, size: 12) else { return "خط النظام" }
        return font.familyName
    }
}
