//
//  StorageTests.swift
//  ClipStudioTests
//
//  Backup archive round-trip & path safety, LUT parsing, unique file names.
//

import XCTest
@testable import ClipStudio

final class StorageTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testBackupArchiveRoundTrip() throws {
        let fileA = workDir.appendingPathComponent("a.txt")
        let fileB = workDir.appendingPathComponent("b.bin")
        try Data("مرحبا ClipStudio".utf8).write(to: fileA)
        try Data((0..<3_000_000).map { UInt8($0 % 251) }).write(to: fileB)
        let archive = workDir.appendingPathComponent("test.csbackup")
        try BackupArchive.write(entries: [
            .init(relativePath: "data/State/a.txt", fileURL: fileA),
            .init(relativePath: "data/Media/b.bin", fileURL: fileB)
        ], to: archive, progress: { _, _ in }, isCancelled: { false })

        let out = workDir.appendingPathComponent("out", isDirectory: true)
        let paths = try BackupArchive.extract(from: archive, into: out, progress: { _, _ in }, isCancelled: { false })
        XCTAssertEqual(paths, ["data/State/a.txt", "data/Media/b.bin"])
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("data/State/a.txt")), try Data(contentsOf: fileA))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("data/Media/b.bin")), try Data(contentsOf: fileB))
    }

    func testUnsafePathsRejected() {
        XCTAssertFalse(BackupArchive.isSafe("../etc/passwd"))
        XCTAssertFalse(BackupArchive.isSafe("/abs/path"))
        XCTAssertFalse(BackupArchive.isSafe("a//b"))
        XCTAssertTrue(BackupArchive.isSafe("data/Projects/x/project.json"))
    }

    func testInvalidArchiveRejected() throws {
        let bogus = workDir.appendingPathComponent("bogus.csbackup")
        try Data("NOTABACKUP".utf8).write(to: bogus)
        XCTAssertThrowsError(try BackupArchive.extract(from: bogus, into: workDir, progress: { _, _ in }, isCancelled: { false }))
    }

    func testLUTParserIdentity() throws {
        var lines = ["TITLE \"identity\"", "LUT_3D_SIZE 2"]
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lines.append("\(r) \(g) \(b)") } } }
        let cube = try LUTParser.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(cube.size, 2)
        XCTAssertEqual(cube.data.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
    }

    func testLUTParserRejects1D() {
        XCTAssertThrowsError(try LUTParser.parse("LUT_1D_SIZE 4\n0 0 0"))
    }

    func testUniqueURLNeverOverwrites() throws {
        let storage = StorageManager.shared
        let first = storage.uniqueURL(in: workDir, baseName: "clip", ext: "mp4")
        try Data().write(to: first)
        let second = storage.uniqueURL(in: workDir, baseName: "clip", ext: "mp4")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "clip (2).mp4")
    }

    func testSanitizedFileName() {
        XCTAssertEqual(StorageManager.shared.sanitizedFileName("a/b:c"), "a-b-c")
        XCTAssertEqual(StorageManager.shared.sanitizedFileName("..hidden"), "hidden")
        XCTAssertEqual(StorageManager.shared.sanitizedFileName("   "), "ClipStudio")
    }
}
