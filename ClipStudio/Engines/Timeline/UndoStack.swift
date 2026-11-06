//
//  UndoStack.swift
//  ClipStudio — Engines/Timeline
//
//  Snapshot-based undo/redo for Pro Studio. Every edit records the project as it
//  was before the change. Continuous edits (slider drags, handle drags) share a
//  coalescing key so one gesture becomes one undo step.
//

import Foundation

struct UndoEntry {
    let name: String
    let snapshot: EditProject
}

@MainActor
@Observable
final class UndoStack {
    private(set) var undoEntries: [UndoEntry] = []
    private(set) var redoEntries: [UndoEntry] = []
    private var lastCoalesceKey: String?
    private var lastRecordDate = Date.distantPast

    static let limit = 150
    static let coalesceWindow: TimeInterval = 1.2

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoName: String? { undoEntries.last?.name }
    var redoName: String? { redoEntries.last?.name }

    /// Records the state before an edit. Returns false when the edit was coalesced
    /// into the previous step.
    @discardableResult
    func record(before snapshot: EditProject, name: String, coalesceKey: String? = nil) -> Bool {
        let now = Date()
        if let coalesceKey, coalesceKey == lastCoalesceKey, now.timeIntervalSince(lastRecordDate) < Self.coalesceWindow {
            lastRecordDate = now
            return false
        }
        undoEntries.append(UndoEntry(name: name, snapshot: snapshot))
        if undoEntries.count > Self.limit { undoEntries.removeFirst(undoEntries.count - Self.limit) }
        redoEntries.removeAll()
        lastCoalesceKey = coalesceKey
        lastRecordDate = now
        return true
    }

    /// Ends the current coalescing run (call when a gesture finishes).
    func breakCoalescing() {
        lastCoalesceKey = nil
    }

    func undo(current: EditProject) -> UndoEntry? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(UndoEntry(name: entry.name, snapshot: current))
        lastCoalesceKey = nil
        return entry
    }

    func redo(current: EditProject) -> UndoEntry? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(UndoEntry(name: entry.name, snapshot: current))
        lastCoalesceKey = nil
        return entry
    }

    func reset() {
        undoEntries.removeAll()
        redoEntries.removeAll()
        lastCoalesceKey = nil
    }
}
