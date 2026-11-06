//
//  StudioViewModel+AI.swift
//  ClipStudio — Features/ProStudio (Part 5)
//
//  The editor side of the AI layer:
//  • the editing assistant — builds a compact description of the timeline
//    (clips c1…, tracks t1…), asks the model (or the on-device parser), turns
//    the answer into a validated, editable plan and applies it as one undo step
//    (analysis-based steps follow as their own steps);
//  • AI help for text-based editing (suggested words / pauses to remove);
//  • silence removal, automatic ducking and beat cutting used by plans.
//

import Foundation
import SwiftUI

extension StudioViewModel {

    // MARK: Assistant context

    func assistantContext() -> AssistantContext {
        var clips: [AssistantContext.ClipRef] = []
        var tracks: [AssistantContext.TrackRef] = []
        let order = timeline.tracks.indices
        let mainTrack = timeline.tracks.firstIndex { $0.kind == .video }
        var clipNumber = 0
        for t in order {
            let track = timeline.tracks[t]
            let trackRef = "t" + String(t + 1)
            tracks.append(AssistantContext.TrackRef(ref: trackRef, trackID: track.id, kind: track.kind, name: track.name))
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                clipNumber += 1
                var text: String?
                if case .text(let content) = clip.source { text = content.caption?.composedText ?? content.text }
                let kind: String
                switch clip.source {
                case .media(let id): kind = env.library.asset(id)?.kind == .audio ? "صوت" : "فيديو"
                case .image: kind = "صورة"
                case .text(let content): kind = content.isCaption ? "ترجمة" : "نص"
                case .freezeFrame: kind = "إطار ثابت"
                case .sticker: kind = "ملصق"
                case .shape: kind = "شكل"
                case .solidColor: kind = "لون"
                case .adjustment: kind = "طبقة تعديل"
                }
                clips.append(AssistantContext.ClipRef(ref: "c" + String(clipNumber), clipID: clip.id, trackRef: trackRef, kind: kind,
                                                      name: clip.name, start: clip.start.seconds, end: clip.end.seconds,
                                                      text: text, speed: clip.speed.rate,
                                                      isPicture: track.kind.isVisual && clip.source.isPicture,
                                                      onMainTrack: t == mainTrack))
            }
        }
        let selected = clips.filter { selection.contains($0.clipID) }.map(\.ref)
        return AssistantContext(clips: clips, tracks: tracks, duration: timeline.duration.seconds, playhead: currentTime,
                                selectedRefs: selected, styleNames: EditingDNAStore.shared.all.map(\.name), frameRate: frameRate)
    }

    /// Sends a command; returns a validated plan (possibly empty with an answer text).
    func askAssistant(_ command: String, history: [AIMessage], forceLocal: Bool,
                      onText: @escaping (String) -> Void) async throws -> (plan: AIPlan, response: AIResponse) {
        var context = assistantContext()
        // Part 6: assistant memory — learned preferences and the user's notes.
        let memory = AssistantMemory.shared
        context.preferredTransition = memory.preferredTransition
        let styles = EditingDNAStore.shared.all
        var prompt = AIPromptManager.assistantContext(context)
        if !memory.promptSummary.isEmpty { prompt += "\n\n" + memory.promptSummary }
        prompt += "\n\nطلب المستخدم: " + command
        var messages = Array(history.suffix(8))
        messages.append(AIMessage(role: .user, parts: [.text(prompt)]))
        let request = AIRequest(task: .assistant,
                                systemInstruction: AIPromptManager.system(for: .assistant, language: AISettings.shared.language),
                                messages: messages, responseSchema: nil,
                                functions: AIPromptManager.assistantFunctions(styleNames: styles.map(\.name)),
                                temperature: 0.2, localInput: .assistant(command: command, context: context))
        let response = try await AIRequestRouter.shared.perform(request, forceLocal: forceLocal, stream: true, onText: onText)
        let plan = AIResponseValidator.plan(calls: response.functionCalls, text: response.text, context: context, styles: styles)
        return (plan: plan, response: response)
    }

    /// Applies the enabled steps. Returns a short Arabic summary.
    @discardableResult
    func applyPlan(_ plan: AIPlan) async -> String {
        let steps = plan.steps.filter(\.isEnabled)
        guard !steps.isEmpty else { return "لا توجد خطوات مفعلة." }
        var styles: [UUID: EditingDNA] = [:]
        for style in EditingDNAStore.shared.all { styles[style.id] = style }
        var outcome = AIPlanOutcome()
        let pure = steps.filter { !$0.operation.isDeferred }
        if !pure.isEmpty {
            _ = edit("المساعد: " + (pure.count == 1 ? pure[0].summary : Fmt.int(pure.count) + " خطوات")) { timeline, context in
                outcome = AIPlanExecutor.apply(pure, to: &timeline, styles: styles, context: context)
            }
            if !outcome.markers.isEmpty, editingCompoundID == nil {
                let markers = outcome.markers
                editProject("المساعد: علامات") { project in
                    project.markers += markers
                    project.markers.sort { $0.time < $1.time }
                }
            }
            let touched = outcome.touched.filter { TimelineEngine.clip($0, in: timeline) != nil }
            if !touched.isEmpty { selection = touched }
        }
        var deferredDone = 0
        for step in steps where step.operation.isDeferred {
            switch step.operation {
            case .removeSilences(let minimum):
                if await removeSilences(minimumPause: minimum) { deferredDone += 1 }
            case .normalizeAudio:
                normalizeLoudness(target: .social)
                deferredDone += 1
            case .duckMusic:
                if autoDuck() { deferredDone += 1 }
            case .stabilize(let id):
                stabilize(clipID: id, strength: 0.6)
                deferredDone += 1
            case .cutToBeat(let beats):
                if await assistantCutToBeat(beats: beats) { deferredDone += 1 }
            case .openTool(let tool):
                open(tool)
                deferredDone += 1
            default:
                break
            }
        }
        var summary = "نُفذت " + Fmt.int(outcome.applied + deferredDone) + " من " + Fmt.int(steps.count) + " خطوة"
        if !outcome.failed.isEmpty { summary += " — تعذر: " + outcome.failed.prefix(2).joined(separator: "؛ ") }
        if outcome.applied + deferredDone > 0 { Haptics.success() }
        return summary
    }

    func open(_ tool: AssistantTool) {
        switch tool {
        case .captions: activeSheet = .captions
        case .music: activeSheet = .music
        case .quality: activeSheet = .quality
        case .outputs: activeSheet = .outputs
        case .smartTools:
            if let id = primaryVideoClipID { activeSheet = .smartTools(id) } else { env.toasts.show("اختر مقطع فيديو أولاً.", style: .info) }
        case .editingStyle: activeSheet = .editingDNA
        case .export: activeSheet = .export
        }
    }

    // MARK: Plan helpers (analysis-based)

    /// Removes silent pauses longer than `minimumPause` from every sound-carrying media clip, all tracks in sync.
    func removeSilences(minimumPause: Double) async -> Bool {
        var jobs: [(clip: Clip, url: URL, assetID: UUID)] = []
        for track in timeline.tracks where track.carriesAudio && !track.isMuted {
            for clip in track.clips {
                guard case .media(let id) = clip.source, let asset = env.library.asset(id), asset.kind == .audio || asset.hasAudio,
                      let url = env.library.url(forID: id), !clip.audio.isMuted else { continue }
                jobs.append((clip: clip, url: url, assetID: id))
            }
        }
        guard !jobs.isEmpty else {
            env.toasts.show("لا يوجد صوت لتحليل الصمت.", style: .info)
            return false
        }
        let (control, relay) = startBusy("البحث عن الصمت", detail: Fmt.int(jobs.count) + " مقطع")
        var spans: [TimeSpan] = []
        var sound: [TimeSpan] = []
        for (index, job) in jobs.enumerated() {
            if control.isCancelled { break }
            var ranges = AnalysisCache.loadSilences(job.assetID)
            if ranges == nil {
                let base = Double(index), total = Double(jobs.count)
                ranges = try? await SilenceDetector.detect(url: job.url, progress: { relay.send((base + $0) / total) })
                if let ranges { AnalysisCache.saveSilences(ranges, assetID: job.assetID) }
            }
            var silent: [TimeSpan] = []
            for range in ranges ?? [] where range.duration >= minimumPause {
                // Keep a little air on both sides so speech doesn't sound cut.
                let a = range.start + 0.12, b = range.end - 0.12
                guard b - a >= 0.2, let la = SpeedMapping.localTime(of: job.clip, sourceTime: a),
                      let lb = SpeedMapping.localTime(of: job.clip, sourceTime: b) else { continue }
                let start = job.clip.start.seconds + min(la, lb), end = job.clip.start.seconds + max(la, lb)
                silent.append(TimeSpan(start: start, end: end))
            }
            spans += silent
            sound += Self.subtract([TimeSpan(start: job.clip.start.seconds, end: job.clip.end.seconds)], mergeSpans(silent))
        }
        busy = nil
        if control.isCancelled { return false }
        // Only pauses where every sound-carrying clip is quiet.
        let merged = Self.subtract(mergeSpans(spans), mergeSpans(sound)).filter { $0.end - $0.start >= 0.2 }
        guard !merged.isEmpty else {
            env.toasts.show("لا توجد وقفات أطول من " + Fmt.seconds(minimumPause, digits: 1) + ".", style: .info)
            return false
        }
        removeTimelineRanges(merged, name: "حذف الصمت")
        return true
    }

    /// `a` minus `b` (both sorted, non-overlapping).
    nonisolated static func subtract(_ a: [TimeSpan], _ b: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in a {
            var pieces = [span]
            for cut in b where cut.end > span.start && cut.start < span.end {
                pieces = pieces.flatMap { piece -> [TimeSpan] in
                    guard cut.end > piece.start, cut.start < piece.end else { return [piece] }
                    var parts: [TimeSpan] = []
                    if cut.start > piece.start { parts.append(TimeSpan(start: piece.start, end: cut.start)) }
                    if cut.end < piece.end { parts.append(TimeSpan(start: cut.end, end: piece.end)) }
                    return parts
                }
            }
            result += pieces.filter { $0.end - $0.start > 1e-6 }
        }
        return result
    }

    private func mergeSpans(_ spans: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Ducking with voice = video tracks + voice-named audio tracks, music = other audio tracks.
    @discardableResult
    func autoDuck() -> Bool {
        var triggers = Set<UUID>()
        var targets = Set<UUID>()
        for track in timeline.tracks where track.carriesAudio && !track.clips.isEmpty {
            let lower = track.name.lowercased()
            if track.kind == .video || EditingDNAAnalyzer.voiceWords.contains(where: { lower.contains($0) }) {
                triggers.insert(track.id)
            } else if track.kind == .audio {
                targets.insert(track.id)
            }
        }
        guard !triggers.isEmpty, !targets.isEmpty else {
            env.toasts.show("يلزم مسار كلام ومسار موسيقى لخفض الموسيقى تلقائيًا.", style: .info)
            return false
        }
        var settings = DuckingSettings()
        settings.triggerTrackIDs = triggers
        settings.targetTrackIDs = targets
        applyDucking(settings)
        return true
    }

    func assistantCutToBeat(beats: Int) async -> Bool {
        guard let music = musicCandidates.first, let target = beatSyncTargets.first else {
            env.toasts.show("أضف موسيقى ومقاطع صورة أولاً.", style: .info)
            return false
        }
        var analysis = cachedMusic(for: music)
        if analysis == nil { analysis = await analyzeMusic(clipID: music.id) }
        guard let analysis else { return false }
        var options = BeatSyncOptions()
        options.grid = beats <= 1 ? .every1 : beats == 2 ? .every2 : beats <= 4 ? .every4 : .every8
        cutToBeats(musicClipID: music.id, analysis: analysis, trackIndex: target.index, options: options)
        return true
    }

    // MARK: Transcript clean-up

    func transcriptSuggestions(words: [TimelineWord], forceLocal: Bool) async throws -> (suggestions: [TranscriptSuggestion], response: AIResponse) {
        let texts = words.map(\.text)
        let gaps = words.indices.map { index -> Double in
            index + 1 < words.count ? max(0, words[index + 1].start - words[index].end) : 0
        }
        let request = AIRequest(task: .transcriptCleanup,
                                systemInstruction: AIPromptManager.system(for: .transcriptCleanup, language: AISettings.shared.language),
                                messages: [AIMessage(role: .user, parts: [.text(AIPromptManager.transcriptPrompt(words: texts, gaps: gaps))])],
                                responseSchema: AIPromptManager.transcriptSchema, temperature: 0.2,
                                localInput: .transcript(words: texts, gaps: gaps))
        let response = try await AIRequestRouter.shared.perform(request, forceLocal: forceLocal)
        let raw = try AIResponseValidator.decode(TranscriptCleanupResult.self, from: response.text)
        var suggestions = AIResponseValidator.transcript(raw.suggestions, wordCount: words.count)
        // Pauses are always measured locally (the model can't hear timing).
        if response.provider == .gemini {
            suggestions += LocalAIProvider.transcript(words: texts, gaps: gaps).filter { $0.kind == .pause }
        }
        return (suggestions: suggestions.sorted { $0.startWord < $1.startWord }, response: response)
    }
}
