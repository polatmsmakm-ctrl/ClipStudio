//
//  BackupArchive.swift
//  ClipStudio — Engines/Storage
//
//  Dependency-free streaming archive format (.csbackup). Files are streamed in
//  1 MB chunks, so multi-GB media never loads into memory.
//
//  Layout (little-endian):
//    "CSBK" (4 bytes) | version UInt32 | entryCount UInt32
//    repeated: pathLength UInt32 | path UTF-8 | size UInt64 | bytes
//

import Foundation

enum BackupArchiveError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(UInt32)
    case unsafePath(String)
    case truncated
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "الملف ليس نسخة احتياطية من ClipStudio."
        case .unsupportedVersion(let v): "إصدار النسخة الاحتياطية (\(v)) غير مدعوم."
        case .unsafePath(let p): "مسار غير آمن داخل النسخة الاحتياطية: \(p)"
        case .truncated: "النسخة الاحتياطية ناقصة أو تالفة."
        case .cancelled: "أُلغيت العملية."
        }
    }
}

enum BackupArchive {
    static let magic = Data("CSBK".utf8)
    static let version: UInt32 = 1
    static let chunkSize = 1_048_576

    struct Entry {
        let relativePath: String
        let fileURL: URL
    }

    // MARK: Write

    static func write(entries: [Entry], to destination: URL,
                      progress: (Int64, Int64) -> Void,
                      isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        let total = entries.reduce(Int64(0)) { $0 + StorageManager.shared.fileSize($1.fileURL) }
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        try out.write(contentsOf: magic)
        try out.write(contentsOf: le(version))
        try out.write(contentsOf: le(UInt32(entries.count)))

        var written: Int64 = 0
        for entry in entries {
            if isCancelled() { throw BackupArchiveError.cancelled }
            let pathData = Data(entry.relativePath.utf8)
            let size = UInt64(StorageManager.shared.fileSize(entry.fileURL))
            try out.write(contentsOf: le(UInt32(pathData.count)))
            try out.write(contentsOf: pathData)
            try out.write(contentsOf: le(size))

            let input = try FileHandle(forReadingFrom: entry.fileURL)
            var remaining = size
            while remaining > 0 {
                if isCancelled() { try? input.close(); throw BackupArchiveError.cancelled }
                let count = Int(min(UInt64(chunkSize), remaining))
                guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else { break }
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
                written += Int64(chunk.count)
                progress(written, total)
            }
            try input.close()
            if remaining > 0 { throw BackupArchiveError.truncated }
        }
    }

    // MARK: Read

    /// Extracts every entry into `directory`. Returns the relative paths written.
    @discardableResult
    static func extract(from source: URL, into directory: URL,
                        progress: (Int64, Int64) -> Void,
                        isCancelled: () -> Bool) throws -> [String] {
        let fm = FileManager.default
        let totalSize = StorageManager.shared.fileSize(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        guard try readExactly(input, 4) == magic else { throw BackupArchiveError.invalidFormat }
        let fileVersion: UInt32 = try readInt(input)
        guard fileVersion <= version else { throw BackupArchiveError.unsupportedVersion(fileVersion) }
        let count: UInt32 = try readInt(input)

        var processed: Int64 = 12
        var paths: [String] = []
        for _ in 0..<count {
            if isCancelled() { throw BackupArchiveError.cancelled }
            let pathLength: UInt32 = try readInt(input)
            guard pathLength > 0, pathLength < 4096 else { throw BackupArchiveError.invalidFormat }
            guard let path = String(data: try readExactly(input, Int(pathLength)), encoding: .utf8) else {
                throw BackupArchiveError.invalidFormat
            }
            guard isSafe(path) else { throw BackupArchiveError.unsafePath(path) }
            let size: UInt64 = try readInt(input)

            let target = directory.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            var remaining = size
            while remaining > 0 {
                if isCancelled() { try? out.close(); throw BackupArchiveError.cancelled }
                let chunk = try readExactly(input, Int(min(UInt64(chunkSize), remaining)))
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
                processed += Int64(chunk.count)
                progress(processed, totalSize)
            }
            try out.close()
            paths.append(path)
        }
        return paths
    }

    // MARK: Helpers

    static func isSafe(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/")
        return !components.isEmpty && !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func readExactly(_ handle: FileHandle, _ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw BackupArchiveError.truncated
            }
            data.append(chunk)
        }
        return data
    }

    private static func readInt<T: FixedWidthInteger>(_ handle: FileHandle) throws -> T {
        let data = try readExactly(handle, MemoryLayout<T>.size)
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        return T(littleEndian: value)
    }
}
