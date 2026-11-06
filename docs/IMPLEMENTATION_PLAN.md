# CLIPSTUDIO — Implementation Plan (all parts)

Code is delivered in numbered parts. **Every part builds on its own** (the app compiles and runs after each part), and later parts only *add* files or replace listed files with complete new versions. No completed module is redesigned.

Constraints applied everywhere (user's standing rules): iOS 17+, Swift 5 language mode, XcodeGen, unsigned IPA via GitHub Actions + Sideloadly, Arabic RTL UI with English digits, local-first (no accounts, no servers), Gemini key in Settings (Keychain) with optional default injected from the `GEMINI_API_KEY` GitHub secret, no third-party dependencies.

## Requirement → part matrix

| Spec section | Part |
|---|---|
| Project setup, XcodeGen, CI, icon, widget | **1** ✓ |
| Premium dark UI, dashboard, design system (UIComponents) | **1** ✓ (extended in every part) |
| Media import, library, thumbnails, metadata, duplicates, relink, storage management | **1** ✓ |
| Project management: autosave, versions, restore, duplicate, crash recovery, missing media | **1** ✓ |
| Smart Stories, Smart Merger, Batch processing, Export engine | **1** ✓ |
| GPU render engine (multi-track, transforms + keyframes, crop, color, LUT, chroma, masks, blend, effects, transitions, generated layers, adjustment layers) | **1** ✓ engine / **2** ✓ UI |
| Pro Studio timeline: multi-track UI, drag/drop, trim, split/join, ripple delete, duplicate, replace, snapping, zoom, playhead, lock/hide/mute, multi-select, clipboard, magnetic mode, timecode nav, markers, undo/redo | **2** ✓ |
| Advanced editing UI: keyframe editor, transform/anchor, crop, masks, PiP, chroma key, reverse, freeze frame, slow-mo, speed ramp editor, blend modes, transitions browser, effects browser | **2** ✓ |
| Color workspace: sliders, curves, wheels, LUT import, presets, before/after, color match | **2** ✓ |
| JKL, keyboard shortcuts, precision sliders, numeric input, copy/paste effects, multi-clip apply, adjustment layers UI, nested sequences, custom workspace layouts, iPad multi-panel, Apple Pencil | **2** ✓ |
| Waveforms, multiple audio tracks UI | **2** ✓ |
| Audio Studio: recording, voiceover, volume automation UI, fades, noise reduction, enhancement, EQ, ducking, extraction, mixing, SFX library | **3** ✓ |
| Text, titles & graphics: text layers editor, fonts, animations, lower thirds, stickers, shapes, images, watermarks, presets | **3** ✓ |
| Dynamic captions + transcription (Speech, Arabic/English), SRT import/export, text-based editing foundation | **3** ✓ |
| Studio suggestions after Part 2 (marker drag, track colors, same-source select, templates, snapshot, motion presets, close gaps, clip preview, aspect lock, project summary) | **3** ✓ |
| Smart reframe & subject tracking (Vision), stabilization | **4** ✓ |
| Music intelligence & beat sync | **4** ✓ |
| Editing DNA (style presets), templates workspace | **4** ✓ |
| Editing by reference (local analysis) | **4** ✓ (AI enrichment **5** ✓) |
| Audio separation (local + optional Core ML model) | **4** ✓ |
| Quality Inspector | **4** ✓ |
| Multiple content outputs (9:16 / 16:9 / 1:1 / 4:5 variants) | **4** ✓ |
| AI architecture: AIProviderProtocol, GeminiProvider, LocalAIProvider, AIModelManager, AIRequestRouter, AIUsageManager, AICacheManager, AIResponseValidator, AIPromptManager | **5** ✓ |
| Gemini: settings (key + model picker), Files API upload for video, structured output, streaming, function calling, Arabic errors, privacy notice | **5** ✓ |
| AI Storyboard, Smart Highlights, Content Studio, AI Editing Assistant (editable plans, preview/apply/undo), text-based editing with AI help, titles/descriptions | **5** ✓ |
| Suggestions after Part 4 (face blur, subject masks, horizon, music fit, beat auto-edit, batch color match, voice ducking, before/after, export check, style sharing) | **5** ✓ |
| Suggestions after Part 5 (generated voiceover, caption translation, voice commands, assistant memory, music suggestions, auto thumbnail, hook check, plan history, smart shortening, episode series) | **6** ✓ |
| Proxy media, memory/thermal tuning, accessibility pass, final feature-status, expanded tests | **6** ✓ |

## Part 1 — Foundation (delivered)
See `docs/HANDOFF.md` for the file tree.

## Part 2 — Pro Studio (delivered)

New files:
```
ClipStudio/Components/PrecisionSlider.swift              pro slider (fine drag, double-tap reset, typed value, ◆ keyframe)
ClipStudio/Components/TimecodeField.swift                timecode parser + "go to" sheet
ClipStudio/Engines/Timeline/TimelineEngine.swift         all edit operations (pure, unit-tested)
ClipStudio/Engines/Timeline/ClipKeyframes.swift          keyframe split/join/retime/easing helpers
ClipStudio/Engines/Timeline/UndoStack.swift              snapshot undo/redo with gesture coalescing
ClipStudio/Engines/Timeline/Snapping.swift               snap targets & snapping
ClipStudio/Engines/Timeline/StudioClipboard.swift        clips + attribute clipboard
ClipStudio/Engines/Media/WaveformService.swift           cached waveform peaks
ClipStudio/Engines/Media/ReverseRenderer.swift           reversed video+audio renders (+ registry)
ClipStudio/Engines/Rendering/NestedSequenceRenderer.swift compound clip renders
ClipStudio/Engines/Rendering/FramePreviewRenderer.swift  still frames, grading previews, histogram, statistics
ClipStudio/Engines/Rendering/ColorMatcher.swift          shot matching
ClipStudio/Engines/Presets/StudioPreferences.swift       Pro Studio preferences + workspace layouts
ClipStudio/Engines/Presets/ColorPresetStore.swift        saved looks + built-in looks
ClipStudio/Engines/Presets/LUTLibrary.swift              observable LUT library
ClipStudio/Features/ProStudio/StudioView.swift           editor root, layouts, top bar, busy overlay, dividers, iPhone action bar
ClipStudio/Features/ProStudio/StudioViewModel.swift      state, preview, playback, undo plumbing
ClipStudio/Features/ProStudio/StudioViewModel+Editing.swift
ClipStudio/Features/ProStudio/StudioViewModel+Gestures.swift
ClipStudio/Features/ProStudio/StudioViewModel+Operations.swift
ClipStudio/Features/ProStudio/StudioViewer.swift         viewer, canvas handles, guides, transport
ClipStudio/Features/ProStudio/StudioTimelineView.swift   timeline, lanes, headers, ruler
ClipStudio/Features/ProStudio/TimelineClipView.swift     clip view, filmstrip, waveform
ClipStudio/Features/ProStudio/StudioToolbar.swift
ClipStudio/Features/ProStudio/StudioMediaPanel.swift
ClipStudio/Features/ProStudio/StudioKeyCommands.swift    keyboard, Pencil, shortcuts sheet
ClipStudio/Features/ProStudio/StudioSheets.swift         export, project settings, markers, paste attributes, nested sequences, preferences
ClipStudio/Features/ProStudio/StudioHubView.swift        Studio section + new project
ClipStudio/Features/ProStudio/Inspector/InspectorView.swift
ClipStudio/Features/ProStudio/Inspector/TransformInspector.swift
ClipStudio/Features/ProStudio/Inspector/CropMaskChromaInspectors.swift
ClipStudio/Features/ProStudio/Inspector/SpeedInspector.swift
ClipStudio/Features/ProStudio/Inspector/EffectsInspector.swift   (+ transitions inspector)
ClipStudio/Features/ProStudio/Inspector/AudioInfoInspectors.swift
ClipStudio/Features/ProStudio/Inspector/KeyframeEditorView.swift
ClipStudio/Features/Color/ColorWorkspaceView.swift       (+ inspector color tab)
ClipStudio/Features/Color/ColorControls.swift            curve, wheels, histogram
ClipStudio/Features/Color/ColorLibraryPanels.swift       LUTs, looks, matching, LUT library screen
ClipStudioTests/StudioEngineTests.swift
```

Replaced files (complete new versions):
```
ClipStudio/Models/Project.swift                        + CompoundClip, StudioState, schema 2 (old files decode)
ClipStudio/Engines/Rendering/CompositionBuilder.swift  + fast attribute refresh, per-clip pitch mode
ClipStudio/Engines/Storage/BackupManager.swift         + merges LUT index, looks, reversed registry
ClipStudio/App/AppEnvironment.swift                    + studioPrefs, colorPresets, lutLibrary
ClipStudio/App/AppRouter.swift                         + Studio section/routes, full-screen editor
ClipStudio/App/ContentView.swift                       + Studio root, fullScreenCover, new routes
ClipStudio/Features/Dashboard/DashboardView.swift      + Studio and LUT tiles
ClipStudio/Features/Shared/ProjectActions.swift        + new Pro project, convert story/merge → Pro
ClipStudio/Features/Settings/SettingsView.swift        + Studio preferences, LUT library
```
Deleted files: none.

## Part 3 — Audio Studio, text & graphics, captions (delivered)
The complete list of new and replaced files (with what changed in each) is in `docs/PART3_CHANGES.md`.

New folders: `Engines/Audio`, `Engines/Captions`, `Engines/Text`, `Features/AudioStudio`, `Features/TextStudio`, `Features/Captions`.
Key decisions:
- Audio effects run in an `MTAudioProcessingTap` per composition audio track, so the same processing is used for preview, video export and audio-only export; parameters update live through a lock-protected store.
- Captions are ordinary text clips (with word timing) on a captions track — editable, movable, exportable to SRT/VTT, and burned in by the normal compositor.
- Transcripts are cached per media file and language; only untranscribed source ranges are recognized.
- Text-based editing removes time ranges with one pure engine function (`TimelineEngine.removeRanges`) — Part 5 adds AI suggestions on top of it.

## Part 4 — On-device intelligence (delivered)
The complete list of new and replaced files is in `docs/PART4_CHANGES.md`.

New folders: `Engines/Vision`, `Engines/Music`, `Engines/Intelligence`, `Features/Intelligence`, `Features/Templates`.
Key decisions:
- **Everything runs on device** (Vision, AVFoundation, Accelerate, optional Core ML). No network, no new permissions.
- **Analyses are cached per media file** in Caches/Analysis (subject tracks per range + mode, stabilization path per file, music analysis per file), so changing settings never re-analyzes.
- **Smart reframe = crop keyframes.** The subject track becomes ordinary crop keyframes (+ fill), so the result is visible in the crop inspector, editable, undoable, and rendered by the existing pipeline. Object tracking reuses the same path; "follow" writes position keyframes on titles / stickers.
- **Stabilization is a render-time correction.** The camera path (Vision translational registration, 15 fps) is analyzed once per file; `LayerRenderer` applies `raw − smoothed` at the clip's source time, so trims, splits and strength / zoom changes are instant.
- **Beat sync is a pure engine** (`BeatSync.cutToBeats`) on top of `TimelineEngine` trims; transitions are centred on the beat by extending both sides by half the transition.
- **Editing DNA** is a small Codable style (rhythm, transitions, look or reference frame, caption / title styles, still motion, music level) learned from a project or a reference video; applying it is one undo step.
- **Separation** keeps `voice + background = original` exactly (background = original − voice), places stems on new tracks and only mutes the original.
- **Variants** are new projects (the source project is never modified); "export all" queues them in the normal export queue.

## Part 5 — AI layer + Part 4 suggestions (delivered)
The complete list of new and replaced files is in `docs/PART5_CHANGES.md`.

New folders: `Engines/AI`, `Features/AI`.
Key decisions:
- **One request shape for every provider.** Features build an `AIRequest` (system instruction, messages with text / inline images / uploaded files, JSON schema or function declarations) plus an `AILocalInput`. `GeminiProvider` sends it over REST; `LocalAIProvider` answers the same request on device with the same JSON / function calls, so every feature has one code path for parsing and validation.
- **`AIRequestRouter` decides**: cloud when a key exists and "use Gemini" is on, otherwise on device; enforces the daily limit and the 429 cool-down; serves cached answers (7 days, keyed by a stable FNV hash of the whole request + model); streams text deltas; falls back to the on-device provider on network / quota / server errors with an Arabic note (never on an invalid key — the user must fix it).
- **Privacy first.** Before media leaves the device a consent sheet says exactly what is sent (frames, a compressed copy and its size); "on device instead" is always offered. The assistant only receives a text description of the timeline (clip refs `c1…`, track refs `t1…`, names, texts, times).
- **Validation is separate from transport.** `AIResponseValidator` clamps every number the model returns (times, durations, rates, color values), drops unknown references with a warning, removes overlapping highlights, enforces platform caption / hashtag limits and merges transcript ranges.
- **Plans, not direct edits.** Function calls become an `AIPlan` of steps the user can switch off. Timeline steps run in one `edit(name)` (one undo step, each step on its own draft so one failure doesn't break the rest); analysis steps (silences, loudness, ducking, stabilize, cut to beat, open tool) run after it. "Preview" applies the plan and offers keep / undo.
- **Video upload** uses the Files API resumable protocol with a 640×480 proxy, waits until the file is ACTIVE, and is reused for 46 h.
- **Suggestions**: tracked masks are keyframes on `MaskSettings` (split / flatten aware), privacy blur is an effect on a silent overlay copy with a tracked ellipse mask, horizon leveling is a render-time rotation (like stabilization), music fit and beat auto-edit are pure engines that return clips / timelines.

## Part 6 — Performance, proxies, accessibility + Part 5 suggestions (delivered)
The complete list of new and replaced files is in `docs/PART6_CHANGES.md`.

New folder: `Engines/Performance`.

Key decisions:
- **Proxies are a preview-only substitution.** `ProxyManager.previewMap(_:)` swaps ready proxy URLs into the `MediaURLMap` that `StudioViewModel.rebuildPreview` hands to `CompositionBuilder`. Nothing else changes, because every render step works in normalized coordinates (crop, masks, stabilization, horizon). Exports, snapshots, analyses and AI calls keep using `MediaLibrary.urlMap()` and the originals.
- **Proxies are keyed by the original's fingerprint.** A relinked or replaced file invalidates its proxy. They live in Caches, which iOS may purge; missing ones are simply rebuilt.
- **One monitor, simple policies.** `PerformanceMonitor` publishes thermal state and Low Power Mode. Pure policies decide what to do: the preview cap (540p / 360p) joins the preview structure key, so a change triggers a normal rebuild; proxy generation waits while the device is hot; the decorative background stops. Memory warnings purge in-memory caches in one place.
- **Accessibility through the existing model.** VoiceOver actions on clips call the same commands as the UI (select, split, nudge, delete). The playhead is an adjustable element. Toasts are announced. Nothing gesture-only was removed.
- **Suggestions reuse the AI layer.**
  - Hook check and smart shortening are new `AITask`s with on-device equivalents (`AILocalInput.hook` / `.shorten`), validated like every other answer.
  - Translation is Gemini-only in the router; the on-device path is Apple Translation in the sheet.
  - TTS is a separate router call (audio output) with the same limits and usage accounting.
  - Plans are Codable for the history. The assistant memory only adds a short text summary and a preferred transition.
- **Every timeline change is still one undoable edit**: translated captions, suggested music, hook fixes, shortening, re-applied plans.

## After Part 6
All six parts are written. The implementation agent compiles, fixes compile errors in place (see `docs/HANDOFF.md` §7), runs the unit tests and the QA checklist on device, and updates `FEATURE_STATUS.md` from "Code written" to tested states.
