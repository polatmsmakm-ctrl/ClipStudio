//
//  AssistantMemory.swift
//  ClipStudio — Engines/AI (Part 6 suggestions)
//
//  • AssistantMemory: the editing assistant learns the user's preferences from
//    the plans they apply (transitions, title placement, speeds, color moves) and
//    from notes the user writes. A short summary is added to every assistant
//    request; the on-device parser uses the preferred transition. Local only,
//    can be switched off or cleared.
//  • PlanHistoryStore: every applied assistant plan, per project (last 50), so a
//    plan can be reviewed and applied again.
//

import Foundation

@MainActor
@Observable
final class AssistantMemory {
    static let shared = AssistantMemory()

    private(set) var data: AssistantMemoryData

    private static var url: URL { StorageManager.shared.stateDirectory.appendingPathComponent("assistant-memory.json") }

    private init() {
        data = JSONStore.load(AssistantMemoryData.self, from: Self.url) ?? AssistantMemoryData()
    }

    var isEnabled: Bool {
        get { data.isEnabled }
        set { data.isEnabled = newValue; save() }
    }

    var notes: String {
        get { data.notes }
        set { data.notes = String(newValue.prefix(800)); save() }
    }

    func reload() {
        data = JSONStore.load(AssistantMemoryData.self, from: Self.url) ?? AssistantMemoryData()
    }

    private func save() {
        try? JSONStore.save(data, to: Self.url)
    }

    /// Learns from the enabled steps of an applied plan.
    func learn(from plan: AIPlan) {
        guard data.isEnabled else { return }
        for step in plan.steps where step.isEnabled {
            for key in Self.keys(for: step.operation) { data.counts[key, default: 0] += 1 }
        }
        save()
    }

    func forget(_ key: String) {
        data.counts.removeValue(forKey: key)
        save()
    }

    func reset() {
        data.counts = [:]
        data.notes = ""
        save()
    }

    var preferredTransition: TransitionKind? {
        guard data.isEnabled else { return nil }
        return Self.preferredTransition(data.counts)
    }

    /// Text added to assistant requests (empty when off or nothing learned).
    var promptSummary: String {
        guard data.isEnabled else { return "" }
        return Self.summary(data)
    }

    // MARK: Pure

    nonisolated static func keys(for operation: AIEditOperation) -> [String] {
        switch operation {
        case .transition(_, let kind, let duration):
            return ["transition:" + kind.rawValue, "transitionLength:" + (duration < 0.4 ? "short" : duration > 0.8 ? "long" : "medium")]
        case .addTitle(_, _, _, let placement):
            return ["placement:" + placement.rawValue]
        case .speed(_, let rate):
            return ["speed:" + Fmt.number(rate, digits: 2)]
        case .color(_, let exposure, let contrast, let saturation, let temperature):
            var keys: [String] = []
            if temperature > 0 { keys.append("color:warm") } else if temperature < 0 { keys.append("color:cool") }
            if saturation > 0 { keys.append("color:vivid") } else if saturation < 0 { keys.append("color:muted") }
            if contrast > 0 { keys.append("color:contrast") }
            if exposure > 0 { keys.append("color:bright") } else if exposure < 0 { keys.append("color:dark") }
            return keys
        case .style(let id):
            return ["style:" + id.uuidString]
        case .removeSilences(let minimum):
            return ["silence:" + Fmt.number(minimum, digits: 1)]
        case .cutToBeat(let beats):
            return ["beats:" + String(beats)]
        case .duckMusic:
            return ["duckMusic"]
        case .normalizeAudio:
            return ["normalize"]
        default:
            return []
        }
    }

    nonisolated static func preferredTransition(_ counts: [String: Int]) -> TransitionKind? {
        let best = counts.filter { $0.key.hasPrefix("transition:") && $0.value >= 2 }
            .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
        return best.flatMap { TransitionKind(rawValue: String($0.key.dropFirst("transition:".count))) }
    }

    /// Human-readable line for one learned key (nil for keys not worth showing).
    nonisolated static func describe(_ key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "transition": return TransitionKind(rawValue: value).map { "الانتقال المفضل: " + $0.title }
        case "transitionLength": return "طول الانتقال: " + (value == "short" ? "قصير" : value == "long" ? "طويل" : "متوسط")
        case "placement":
            let title = value == "top" ? "أعلى الشاشة" : value == "center" ? "وسط الشاشة" : "أسفل الشاشة"
            return "مكان العناوين: " + title
        case "speed": return "سرعة مستخدمة: ×" + value
        case "color":
            switch value {
            case "warm": return "ألوان دافئة"
            case "cool": return "ألوان باردة"
            case "vivid": return "ألوان مشبعة"
            case "muted": return "ألوان هادئة"
            case "contrast": return "تباين أعلى"
            case "bright": return "صورة أفتح"
            case "dark": return "صورة أغمق"
            default: return nil
            }
        case "silence": return "حذف الوقفات الأطول من " + value + " ث"
        case "beats": return "القص على الإيقاع كل " + value + " ضربات"
        case "duckMusic": return "خفض الموسيقى تحت الكلام"
        case "normalize": return "تسوية مستوى الصوت"
        case "style":
            guard let id = UUID(uuidString: value) else { return nil }
            return EditingDNA.builtIns.first(where: { $0.id == id }).map { "أسلوب مفضل: " + $0.name } ?? "أسلوب مونتاج محفوظ"
        default: return nil
        }
    }

    /// Learned preferences used at least twice (most used first), plus the user's notes.
    nonisolated static func summary(_ data: AssistantMemoryData, limit: Int = 8) -> String {
        let learned = data.counts.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { entry in describe(entry.key).map { $0 + " (" + String(entry.value) + " مرات)" } }
            .prefix(limit)
        var lines: [String] = []
        if !learned.isEmpty { lines.append("تفضيلات تعلّمتها من تعديلاته السابقة: " + learned.joined(separator: "، ") + ".") }
        let notes = data.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append("ملاحظات المستخدم عن أسلوبه: " + notes) }
        guard !lines.isEmpty else { return "" }
        return "معلومات عن المستخدم (استخدمها عندما لا يحدد الطلب التفاصيل):\n" + lines.joined(separator: "\n")
    }

    /// Learned entries for the settings list.
    var entries: [AssistantMemoryEntry] {
        data.counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { entry in Self.describe(entry.key).map { AssistantMemoryEntry(key: entry.key, title: $0, count: entry.value) } }
    }
}

struct AssistantMemoryEntry: Identifiable, Hashable {
    let key: String
    let title: String
    let count: Int

    var id: String { key }
}

// MARK: - Plan history

enum PlanHistoryStore {
    static let limit = 50

    static var directory: URL { StorageManager.shared.stateDirectory.appendingPathComponent("AIPlans", isDirectory: true) }

    static func url(_ projectID: UUID) -> URL { directory.appendingPathComponent(projectID.uuidString + ".json") }

    static func load(_ projectID: UUID) -> [PlanRecord] {
        (JSONStore.load([PlanRecord].self, from: url(projectID)) ?? []).sorted { $0.date > $1.date }
    }

    static func add(_ record: PlanRecord, projectID: UUID) {
        var records = load(projectID)
        records.insert(record, at: 0)
        save(Array(records.prefix(limit)), projectID: projectID)
    }

    static func remove(_ id: UUID, projectID: UUID) {
        save(load(projectID).filter { $0.id != id }, projectID: projectID)
    }

    static func clear(_ projectID: UUID) {
        try? FileManager.default.removeItem(at: url(projectID))
    }

    private static func save(_ records: [PlanRecord], projectID: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if records.isEmpty {
            try? FileManager.default.removeItem(at: url(projectID))
        } else {
            try? JSONStore.save(records, to: url(projectID))
        }
    }
}
