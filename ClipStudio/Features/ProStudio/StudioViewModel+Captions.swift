//
//  StudioViewModel+Captions.swift
//  ClipStudio — Features/ProStudio (Dynamic captions & transcription, Part 3)
//
//  Transcription of the chosen audio tracks (cached per file and language),
//  automatic captions on a captions track, caption editing (text, merge, split,
//  delete, sync offset, restyle), SRT/VTT import and export, and the text-based
//  editing foundation (removing words, fillers and pauses from the timeline).
//

import Foundation
import SwiftUI

struct CaptionGenerationOptions {
    var localeID: String
    var allowServer: Bool
    var sourceTrackIDs: Set<UUID>
    var preset: CaptionStylePreset
    var layout: CaptionLayoutOptions
    var onlyInOut: Bool
    var replaceExisting: Bool
}

/// A track with its index (for lists of tracks).
struct IndexedTrack: Identifiable {
    let index: Int
    let track: Track
    var id: UUID { track.id }
}

struct CaptionEntry: Identifiable {
    var id: UUID { clip.id }
    let clip: Clip
    let trackIndex: Int
    var caption: CaptionInfo? {
        if case .text(let content) = clip.source { return content.caption }
        return nil
    }
    var text: String {
        if case .text(let content) = clip.source { return content.caption?.composedText ?? content.text }
        return ""
    }
}

extension StudioViewModel {

    // MARK: Sources

    /// Tracks that can be transcribed (carry sound and have clips).
    var captionSourceTracks: [IndexedTrack] {
        timeline.tracks.enumerated().compactMap { index, track -> IndexedTrack? in
            guard track.carriesAudio, track.kind != .adjustment, !track.clips.isEmpty else { return nil }
            let hasSound = track.clips.contains { clip in
                guard case .media(let id) = clip.source, let asset = env.library.asset(id) else { return false }
                return asset.kind == .audio || asset.hasAudio
            }
            return hasSound ? IndexedTrack(index: index, track: track) : nil
        }
    }

    /// Default: voice-like audio tracks plus the primary video track (music tracks excluded).
    func defaultCaptionSources() -> Set<UUID> {
        let candidates = captionSourceTracks
        let musicWords = ["موسيقى", "music", "مؤثر"]
        var ids = Set(candidates.filter { pair in
            let name = pair.track.name.lowercased()
            return !musicWords.contains { name.contains($0) } && !pair.track.isMuted
        }.map { $0.track.id })
        if ids.isEmpty, let first = candidates.first { ids.insert(first.track.id) }
        return ids
    }

    private struct SourceClip {
        let clip: Clip
        let assetID: UUID
        let url: URL
    }

    private func sourceClips(tracks ids: Set<UUID>, range: TimeSpan?) -> [SourceClip] {
        var result: [SourceClip] = []
        for track in timeline.tracks where ids.contains(track.id) {
            for clip in track.clips where clip.isEnabled && !clip.speed.isReversed {
                guard case .media(let assetID) = clip.source, let asset = env.library.asset(assetID),
                      asset.kind == .audio || asset.hasAudio, let url = env.library.url(forID: assetID) else { continue }
                if let range, clip.end.seconds <= range.start || clip.start.seconds >= range.end { continue }
                result.append(SourceClip(clip: clip, assetID: assetID, url: url))
            }
        }
        return result
    }

    /// Words already transcribed for the given tracks (no recognition), in timeline time.
    func cachedTimelineWords(localeID: String, sourceTrackIDs: Set<UUID>, range: TimeSpan? = nil) -> [TimelineWord] {
        var transcripts: [UUID: AssetTranscript] = [:]
        var words: [TimelineWord] = []
        for source in sourceClips(tracks: sourceTrackIDs, range: range) {
            if transcripts[source.assetID] == nil {
                transcripts[source.assetID] = TranscriptStore.load(assetID: source.assetID, localeID: localeID)
            }
            guard let transcript = transcripts[source.assetID] else { continue }
            words += CaptionBuilder.timelineWords(for: source.clip, transcript: transcript)
        }
        if let range { words = words.filter { $0.end > range.start && $0.start < range.end } }
        return words.sorted { $0.start < $1.start }
    }

    /// Seconds of audio in the given tracks that still need transcribing.
    func untranscribedSeconds(localeID: String, sourceTrackIDs: Set<UUID>) -> Double {
        var needs: [UUID: [TimeSpan]] = [:]
        for source in sourceClips(tracks: sourceTrackIDs, range: nil) {
            guard let range = source.clip.sourceRange else { continue }
            needs[source.assetID, default: []].append(TimeSpan(start: range.start.seconds, end: range.end.seconds))
        }
        var total = 0.0
        for (assetID, spans) in needs {
            let transcript = TranscriptStore.load(assetID: assetID, localeID: localeID) ?? AssetTranscript(assetID: assetID, localeID: localeID)
            for span in TimelineEngine.mergedSpans(spans) {
                total += transcript.missing(in: span).reduce(0) { $0 + $1.duration }
            }
        }
        return total
    }

    // MARK: Transcription

    /// Transcribes whatever is missing for the chosen tracks, then returns the timeline words.
    func transcribeSources(localeID: String, allowServer: Bool, sourceTrackIDs: Set<UUID>, range: TimeSpan?,
                           completion: @escaping ([TimelineWord]) -> Void) {
        let sources = sourceClips(tracks: sourceTrackIDs, range: range)
        guard !sources.isEmpty else {
            env.toasts.show("لا يوجد صوت في المسارات المختارة.", style: .info)
            return
        }
        Task { [weak self] in
            guard await TranscriptionService.requestAuthorization() else {
                self?.report(TranscriptionError.notAuthorized)
                return
            }
            guard let self else { return }
            // Source spans to cover per file.
            var needs: [UUID: (url: URL, spans: [TimeSpan])] = [:]
            for source in sources {
                guard let sourceRange = source.clip.sourceRange else { continue }
                var entry: (url: URL, spans: [TimeSpan]) = needs[source.assetID] ?? (url: source.url, spans: [])
                entry.spans.append(TimeSpan(start: sourceRange.start.seconds, end: sourceRange.end.seconds))
                needs[source.assetID] = entry
            }
            var transcripts: [UUID: AssetTranscript] = [:]
            var work: [(assetID: UUID, url: URL, span: TimeSpan)] = []
            for (assetID, entry) in needs {
                let transcript = TranscriptStore.load(assetID: assetID, localeID: localeID) ?? AssetTranscript(assetID: assetID, localeID: localeID)
                transcripts[assetID] = transcript
                for span in TimelineEngine.mergedSpans(entry.spans) {
                    for missing in transcript.missing(in: span) { work.append((assetID: assetID, url: entry.url, span: missing)) }
                }
            }
            let total = work.reduce(0.0) { $0 + $1.span.duration }
            if total > 0 {
                let onDevice = TranscriptionService.supportsOnDevice(localeID)
                let (control, relay) = self.startBusy("تفريغ الكلام",
                                                      detail: onDevice ? "على جهازك — " + Fmt.durationPrecise(total)
                                                                       : "عبر خوادم Apple — " + Fmt.durationPrecise(total))
                var done = 0.0
                do {
                    for item in work {
                        if control.isCancelled { throw TranscriptionError.cancelled }
                        let waveform = await WaveformService.shared.waveform(assetID: item.assetID, url: item.url)
                        let base = done
                        let length = item.span.duration
                        let result = try await TranscriptionService.transcribe(
                            url: item.url, span: item.span, localeID: localeID, allowServer: allowServer, waveform: waveform,
                            control: control, progress: { relay.send(min(1, (base + $0 * length) / total)) })
                        var transcript = transcripts[item.assetID] ?? AssetTranscript(assetID: item.assetID, localeID: localeID)
                        transcript.merge(result.words, span: item.span, server: result.usedServer)
                        transcripts[item.assetID] = transcript
                        try? TranscriptStore.save(transcript)
                        done += length
                    }
                } catch {
                    self.busy = nil
                    if case TranscriptionError.cancelled = error {
                        self.env.toasts.show("تم إلغاء التفريغ (ما تم تفريغه محفوظ)", style: .info)
                    } else {
                        self.report(error)
                    }
                    return
                }
                self.busy = nil
            }
            var words: [TimelineWord] = []
            for source in sources {
                if let transcript = transcripts[source.assetID] {
                    words += CaptionBuilder.timelineWords(for: source.clip, transcript: transcript)
                }
            }
            if let range { words = words.filter { $0.end > range.start && $0.start < range.end } }
            completion(words.sorted { $0.start < $1.start })
        }
    }

    // MARK: Captions

    func generateCaptions(_ options: CaptionGenerationOptions) {
        let range = options.onlyInOut ? inOutRange.map { TimeSpan(start: $0.0, end: $0.1) } : nil
        transcribeSources(localeID: options.localeID, allowServer: options.allowServer,
                          sourceTrackIDs: options.sourceTrackIDs, range: range) { [weak self] words in
            guard let self else { return }
            guard !words.isEmpty else {
                self.env.toasts.show("لم يُتعرّف على كلام في المقاطع المختارة.", style: .info)
                return
            }
            let cues = CaptionBuilder.cues(from: words, options: options.layout)
            var created = 0
            self.edit("ترجمة تلقائية") { timeline, context in
                if options.replaceExisting {
                    for t in timeline.tracks.indices where timeline.tracks[t].kind == .subtitle && !timeline.tracks[t].isLocked {
                        timeline.tracks[t].clips.removeAll { clip in
                            guard case .text(let content) = clip.source, content.isCaption else { return false }
                            guard let range else { return true }
                            return clip.end.seconds > range.start && clip.start.seconds < range.end
                        }
                    }
                }
                let target = Self.captionTrack(in: &timeline)
                for cue in cues {
                    let clip = CaptionBuilder.makeClip(cue, preset: options.preset)
                    TimelineEngine.carve(&timeline, track: target, from: cue.start, to: cue.end, context: context)
                    timeline.tracks[target].clips.append(clip)
                    created += 1
                }
                TimelineEngine.finalize(&timeline, tracks: [target], context: context)
            }
            UserDefaults.standard.set(options.preset.id, forKey: "captions.lastStyle")
            self.env.toasts.show("تمت إضافة " + Fmt.int(created) + " ترجمة", style: .success)
        }
    }

    /// First unlocked captions track (created and colored when missing).
    static func captionTrack(in timeline: inout Timeline) -> Int {
        if let index = timeline.tracks.firstIndex(where: { $0.kind == .subtitle && !$0.isLocked }) { return index }
        let index = TimelineEngine.addTrack(.subtitle, to: &timeline)
        timeline.tracks[index].name = "الترجمة"
        timeline.tracks[index].color = RGBAColor(hex: 0xE58F4A)
        return index
    }

    /// Every caption clip, in time order.
    var captionEntries: [CaptionEntry] {
        var entries: [CaptionEntry] = []
        for (index, track) in timeline.tracks.enumerated() {
            for clip in track.clips {
                guard case .text(let content) = clip.source else { continue }
                if content.isCaption || track.kind == .subtitle {
                    entries.append(CaptionEntry(clip: clip, trackIndex: index))
                }
            }
        }
        return entries.sorted { $0.clip.start < $1.clip.start }
    }

    func updateCaptionText(_ clipID: UUID, text: String) {
        updateText(clipID, name: "تعديل الترجمة", coalesce: "caption-text-" + clipID.uuidString) { content in
            if var info = content.caption {
                info.retext(text, duration: 3600)
                content.caption = info
                content.text = info.composedText
            } else {
                content.text = text
            }
        }
    }

    func deleteCaption(_ clipID: UUID) {
        edit("حذف ترجمة") { timeline, context in
            try TimelineEngine.delete([clipID], ripple: false, in: &timeline, context: context)
        }
    }

    /// Joins a caption with the next caption on the same track.
    func mergeCaptionWithNext(_ clipID: UUID) {
        guard let t = TimelineEngine.trackIndex(of: clipID, in: timeline) else { return }
        let clips = timeline.tracks[t].clips.sorted { $0.start < $1.start }
        guard let index = clips.firstIndex(where: { $0.id == clipID }), index + 1 < clips.count,
              case .text(var content) = clips[index].source, case .text(let nextContent) = clips[index + 1].source else {
            env.toasts.show("لا توجد ترجمة بعدها للدمج.", style: .info)
            return
        }
        let first = clips[index], second = clips[index + 1]
        let offset = second.start.seconds - first.start.seconds
        var info = content.caption ?? CaptionInfo(words: [])
        let nextWords = nextContent.caption?.words ?? [CaptionWord(text: nextContent.text, start: 0, end: second.duration.seconds)]
        info.words += nextWords.map { word in
            var copy = word
            copy.start += offset
            copy.end += offset
            copy.breaksLine = false
            return copy
        }
        content.caption = info
        content.text = info.composedText
        let merged = content
        let newDuration = second.end.seconds - first.start.seconds
        edit("دمج الترجمة") { timeline, _ in
            guard let ti = TimelineEngine.trackIndex(of: clipID, in: timeline),
                  let ci = timeline.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
            timeline.tracks[ti].clips[ci].source = .text(merged)
            timeline.tracks[ti].clips[ci].duration = TimeValue(seconds: newDuration)
            timeline.tracks[ti].clips.removeAll { $0.id == second.id }
        }
    }

    /// Splits a caption before word `wordIndex`.
    func splitCaption(_ clipID: UUID, beforeWord wordIndex: Int) {
        guard let clip = TimelineEngine.clip(clipID, in: timeline), case .text(let content) = clip.source,
              let words = content.caption?.words, words.indices.contains(wordIndex), wordIndex > 0 else { return }
        let time = clip.start.seconds + words[wordIndex].start
        edit("تقسيم الترجمة") { timeline, context in
            _ = try TimelineEngine.split([clipID], at: time, in: &timeline, context: context)
        }
    }

    /// Moves every caption earlier/later (sync offset).
    func shiftCaptions(by delta: Double) {
        let ids = Set(captionEntries.map(\.id))
        guard !ids.isEmpty else { return }
        edit("مزامنة الترجمة", coalesce: "caption-shift") { timeline, context in
            for t in timeline.tracks.indices where !timeline.tracks[t].isLocked {
                for c in timeline.tracks[t].clips.indices where ids.contains(timeline.tracks[t].clips[c].id) {
                    let moved = max(0, timeline.tracks[t].clips[c].start.seconds + delta)
                    timeline.tracks[t].clips[c].start = TimeValue(seconds: context.snap(moved))
                }
                TimelineEngine.normalize(&timeline, track: t, context: context)
            }
        }
    }

    func restyleCaptions(_ preset: CaptionStylePreset, resetPosition: Bool) {
        let ids = Set(captionEntries.map(\.id))
        guard !ids.isEmpty else {
            env.toasts.show("لا توجد ترجمة بعد.", style: .info)
            return
        }
        edit("نمط الترجمة: " + preset.title) { timeline, _ in
            TimelineEngine.updateClips(ids, in: &timeline) { CaptionBuilder.restyle(&$0, preset: preset, resetPosition: resetPosition) }
        }
        UserDefaults.standard.set(preset.id, forKey: "captions.lastStyle")
    }

    func setCaptionHighlightColor(_ color: RGBAColor) {
        let ids = Set(captionEntries.map(\.id))
        edit("لون التمييز", coalesce: "caption-highlight") { timeline, _ in
            TimelineEngine.updateClips(ids, in: &timeline) { clip in
                guard case .text(var content) = clip.source, var info = content.caption else { return }
                info.highlightColor = color
                info.boxColor = color
                content.caption = info
                clip.source = .text(content)
            }
        }
    }

    // MARK: SRT / VTT

    func importSubtitles(from url: URL, preset: CaptionStylePreset) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            env.toasts.show("تعذّرت قراءة الملف.", style: .error)
            return
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
        let cues = SubtitleCodec.parse(text)
        guard !cues.isEmpty else {
            env.toasts.show("الملف لا يحتوي ترجمة بصيغة SRT أو VTT.", style: .error)
            return
        }
        edit("استيراد ترجمة") { timeline, context in
            let index = TimelineEngine.addTrack(.subtitle, to: &timeline)
            timeline.tracks[index].name = "ترجمة مستوردة"
            timeline.tracks[index].color = RGBAColor(hex: 0xE58F4A)
            var reach = 0.0
            for cue in cues {
                let start = max(cue.start, reach)
                guard cue.end - start > 0.05 else { continue }
                timeline.tracks[index].clips.append(CaptionBuilder.estimatedClip(text: cue.text, start: context.snap(start),
                                                                                end: cue.end, preset: preset))
                reach = cue.end
            }
            TimelineEngine.finalize(&timeline, tracks: [index], context: context)
        }
        env.toasts.show("تم استيراد " + Fmt.int(cues.count) + " ترجمة", style: .success)
    }

    /// Writes the captions to a subtitle file in the Exports folder.
    func exportSubtitles(format: SubtitleFormat) -> URL? {
        let cues = captionEntries.map { entry in
            SubtitleCue(start: entry.clip.start.seconds, end: entry.clip.end.seconds, text: entry.text)
        }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cues.isEmpty else {
            env.toasts.show("لا توجد ترجمة للتصدير.", style: .info)
            return nil
        }
        let storage = StorageManager.shared
        storage.ensureDirectories()
        let url = storage.uniqueURL(in: storage.exportsDirectory, baseName: storage.sanitizedFileName(project.name), ext: format.fileExtension)
        do {
            try SubtitleCodec.encode(cues, format: format).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: Text-based editing

    /// Ripple-removes time ranges from every unlocked track (markers follow on the main timeline).
    func removeTimelineRanges(_ spans: [TimeSpan], name: String) {
        let merged = TimelineEngine.mergedSpans(spans.filter { $0.duration > frameDuration / 2 })
        guard !merged.isEmpty else { return }
        let context = editContext
        if editingCompoundID == nil {
            editProject(name) { project in
                TimelineEngine.removeRanges(merged, in: &project.timeline, context: context)
                for index in project.markers.indices {
                    let time = project.markers[index].time.seconds
                    let removed = merged.reduce(0.0) { $0 + min(max(0, time - $1.start), $1.duration) }
                    project.markers[index].time = TimeValue(seconds: max(0, time - removed))
                }
            }
        } else {
            edit(name) { timeline, ctx in
                TimelineEngine.removeRanges(merged, in: &timeline, context: ctx)
            }
        }
        let total = merged.reduce(0) { $0 + $1.duration }
        env.toasts.show("تم حذف " + Fmt.durationPrecise(total) + " من الخط الزمني", style: .success)
    }
}
