# CLIPSTUDIO — Handoff for the implementation agent

This repository contains **generated source code only** (all 6 parts). It has **not** been compiled, run or tested. Your job:
1. Put the files in the repository exactly as laid out below (for an update, copy the new/changed files listed in `docs/PART6_CHANGES.md` — and the earlier `PART5_CHANGES.md` … `PART2_CHANGES.md` if the repo is behind).
2. Run the GitHub Actions workflow, fix compile errors **in place**, and produce the IPA.
3. Test on device and update `docs/FEATURE_STATUS.md`.

## 1. Rules for whoever applies this code
- **Do not remove or stub features** to make the build pass. Fix the exact error (types, imports, availability, actor isolation) and keep the behaviour.
- **Do not change the architecture** (XcodeGen, Swift 5 language mode, iOS 17, SwiftUI + `@Observable`, no third-party packages).
- **Never commit API keys.** The Gemini key comes from the `GEMINI_API_KEY` Actions secret (written into `ClipStudio/Generated/BuildSecrets.swift` at build time) or from the user's Settings (Keychain, Part 5). The committed `BuildSecrets.swift` must keep an empty string.
- **Never fake progress**, never delete or modify the user's original media, never overwrite existing files (`StorageManager.uniqueURL` is used for every output). Reversed clips and nested sequences are *new* generated library assets.
- UI language is Arabic (RTL) with **English digits** everywhere — format numbers with `Fmt` (`Components/Formatting.swift`). Timelines, sliders, curves and the viewer are deliberately forced left → right.
- Every new file must start with the standard header and live under the folders below (XcodeGen picks up everything inside `ClipStudio/`, `Shared/`, `ClipStudioWidget/`, `ClipStudioTests/` automatically — no project.yml change is needed for new files; Part 6 only adds `-weak_framework Translation` to the app target).

## 2. Repository setup
| ZIP path | Repo path |
|---|---|
| `github-workflows/build.yml` | **`.github/workflows/build.yml`** (create on GitHub's website; the iOS Files app cannot store dot-folders) |
| `gitignore.txt` | **`.gitignore`** (optional, same reason) |
| everything else | same path |

`ClipStudio.xcodeproj` is **generated** by `xcodegen generate` in CI and must never be committed.

## 3. Secrets (GitHub → Settings → Secrets and variables → Actions)
| Secret | Required | Used for |
|---|---|---|
| `GEMINI_API_KEY` | optional | Default Gemini key compiled into `BuildSecrets.geminiDefaultKey`. `AISettings.effectiveKey` uses the key the user saved in Settings (Keychain) first, then this one. Without either, every AI tool runs on device. |
| `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `BUILD_PROVISION_PROFILE_BASE64`, `WIDGET_PROVISION_PROFILE_BASE64`, `APPLE_TEAM_ID` | optional | Extra **signed** IPA. All five must exist or the signed steps are skipped. |
| `EXPORT_METHOD` | optional | `release-testing` (default), `development`, `ad-hoc`. |

The unsigned IPA (`build-<run number>` release) is always produced and is what the user installs with Sideloadly.

## 4. Targets & identifiers
| Target | Type | Bundle ID |
|---|---|---|
| ClipStudio | application | `com.rashid.clipstudio` |
| ClipStudioWidget | app-extension (WidgetKit) | `com.rashid.clipstudio.widget` |
| ClipStudioTests | unit-test bundle | `com.rashid.clipstudio.tests` |

App Group: `group.com.rashid.clipstudio` (both entitlements files). **Optional**: if the App Group is not enabled on the App ID when Sideloadly signs, `AppGroup.isAvailable` is false, the app works normally and the widget shows its empty state. To enable it: developer.apple.com → Identifiers → `com.rashid.clipstudio` and `com.rashid.clipstudio.widget` → App Groups → add `group.com.rashid.clipstudio`. The workflow embeds both entitlements files into the unsigned binaries with `ldid`, so Sideloadly can carry the App Group over when it re-signs with the user's Apple ID.

Info.plist usage strings present: Photo Library (read + add), Microphone, Speech Recognition. Camera is not used. Parts 2–6 add no new permission keys (Part 6 voice commands reuse Microphone + Speech Recognition) (Part 5 uses plain HTTPS to `generativelanguage.googleapis.com`, allowed by ATS; the Keychain needs no entitlement) (Part 3 starts *using* the existing Microphone and Speech Recognition strings for voiceover and captions). Document type + exported UTI `com.rashid.clipstudio.backup` (`.csbackup`), URL scheme `clipstudio://` (hosts: `exports`, `projects`, `stories`, `studio`).

## 5. File tree (Parts 1–6)
```
project.yml                                  XcodeGen spec (3 targets, scheme ClipStudio with tests)
github-workflows/build.yml                   → .github/workflows/build.yml
gitignore.txt                                → .gitignore
Scripts/generate_app_icon.swift              CoreGraphics 1024×1024 icon (CI runs it if AppIcon.png is missing)
docs/HANDOFF.md  IMPLEMENTATION_PLAN.md  FEATURE_STATUS.md  PART2_CHANGES.md  PART3_CHANGES.md  PART4_CHANGES.md  PART5_CHANGES.md  PART6_CHANGES.md
README.md                                    Arabic user guide (GitHub clicks, Sideloadly)

Shared/                                      compiled into app AND widget
  AppGroup.swift  WidgetSnapshot.swift

ClipStudio/
  Info.plist  ClipStudio.entitlements
  Generated/BuildSecrets.swift               placeholder; overwritten by CI from GEMINI_API_KEY
  Resources/Assets.xcassets/                 AppIcon (generated in CI), AccentColor #E3B04B, LaunchBackground #0B0B0E
  App/
    ClipStudioApp.swift                      @main, RTL + English-digit locale, appearance, URL opening, scene phase
    AppEnvironment.swift                     composition root (Part 2: studioPrefs, colorPresets, lutLibrary)
    AppRouter.swift                          AppSection (9 incl. Studio), Route enum, full-screen editor presentation
    ContentView.swift                        iPad split / iPhone tabs, route destinations, Studio fullScreenCover
  Models/
    Primitives.swift  Animation.swift (Part 3: stretch/aspect lock)  Effects.swift
    Content.swift (Part 3: title designs, loops, captions)  Timeline.swift (Part 3: track color/solo/pan, audio effects;
                                             Part 4: clip stabilization)
    Project.swift                            EditProject (schema 3): CompoundClip, StudioState, watermark in ProjectSettings
    (Part 3) AudioEffects.swift  Captions.swift  Watermark.swift  MotionPreset.swift
    (Part 4) Intelligence.swift              subject tracks, stabilization, music analysis, EditingDNA, templates, output formats
                                             (Part 5: HorizonSettings / HorizonData, PrivacyStyle)
    (Part 5) AI.swift                        AIRequest / AIResponse / parts, storyboard, highlights, content, assistant plan, transcript, enrichment
                                             (Part 6: translation / hookCheck / shorten tasks, Codable plans, preferredTransition)
    (Part 6) AIExtras.swift                  translation targets, hook input / report, shortening, plan records, memory, voiceover options
    Stories.swift  Export.swift  Media.swift
  Components/
    Theme.swift  AppBackground.swift  Cards.swift  Controls.swift  Feedback.swift
    Formatting.swift  Player.swift  MediaThumbnailView.swift
    PrecisionSlider.swift                    fine-drag slider, typed values, ◆ keyframe toggle, InspectorSection/Row
    AccessibilityPrefs.swift (Part 6)        large trim handles key, VoiceOver clip descriptions
    TimecodeField.swift                      TimecodeParser + GoToTimecodeSheet
  Engines/
    Storage/   StorageManager, BackupArchive, BackupManager, WidgetBridge
    Project/   ProjectManager
    Media/     MediaInspector, MediaLibrary, MediaImportManager, ThumbnailService,
               WaveformService (Part 2), ReverseRenderer + ReverseLibrary (Part 2)
    Analysis/  SceneDetector, AudioAnalysis
    Stories/   SegmentPlanner, TimelineFactories
    Timeline/  (Part 2) TimelineEngine, ClipKeyframes, UndoStack, Snapping, StudioClipboard
               (Part 3) TimelineEngine+Organize (close gaps, remove ranges, same source, inverse speed)
    Audio/     (Part 3) AudioDSP, AudioTapProcessor, LoudnessAnalyzer, DuckingEngine, AudioExtractor,
               VoiceoverRecorder, SoundEffectsLibrary, (Part 4) SourceSeparator (+ optional Core ML model store)
    Vision/    (Part 4) FrameSampler, SubjectTracker (+ReframeEngine), Stabilizer (+StabilizationStore)
               (Part 5) FaceTracker (+SubjectMaskPath, ReframeEngine.maskPath), HorizonLeveler (HorizonAnalyzer + HorizonStore)
    Music/     (Part 4) MusicAnalyzer (+MusicFeatureExtractor), BeatSync, (Part 5) MusicFit, AutoEditBuilder,
               (Part 6) MusicRecommender (+MusicMood)
    Intelligence/ (Part 4) EditingDNAEngine (analyzer + applier), ReferenceAnalyzer, QualityInspector, OutputVariants,
               (Part 5) ColorMatchBatch, (Part 6) ThumbnailMaker, SeriesBuilder
    AI/        (Part 5) KeychainStore, AISettings, AIModelManager, GeminiClient (+GeminiError, UploadProgressDelegate),
               LocalAIProvider (+AIProvider protocol, GeminiProvider, LocalCommandParser), AIRequestRouter,
               AIUsageManager, AICacheManager, AIPromptManager, AIResponseValidator, AIMediaPreparer,
               AIPlanExecutor, AIFeatureService, ContentStore,
               (Part 6) SmartShortener, HookAnalyzer, CaptionTranslator, AssistantMemory (+PlanHistoryStore),
               SpeechSynthesis (+DeviceSpeechWriter, AIModelManager.bestTTS)
    Performance/ (Part 6) ProxyManager (+ProxyPolicy), PerformanceMonitor
    Captions/  (Part 3) TranscriptionService, TranscriptStore, CaptionBuilder, SubtitleFormats, (Part 6) LiveDictation
    Text/      (Part 3) FontCatalog
    Rendering/ RenderTypes, CompositionBuilder (Part 2: fast refresh), ClipCompositor, LayerRenderer,
               ColorPipeline, EffectRenderer, TransitionRenderer, GeneratedContentRenderer,
               (Part 2) NestedSequenceRenderer, FramePreviewRenderer, ColorMatcher, (Part 3) WatermarkRenderer
    Export/    ExportEngine, ExportQueue, ExportHistoryStore, (Part 3) FrameSnapshot
    Presets/   PresetManager (+AppSettings), (Part 2) StudioPreferences, ColorPresetStore, LUTLibrary,
               (Part 3) MotionPresetStore, TextStyleLibrary, ProjectTemplates,
               (Part 4) EditingDNAStore (+ built-in styles), StudioTemplateLibrary, (Part 5) StyleSharing
  Features/
    Shared/ProjectActions.swift              (Part 2: new Pro project, convert story/merge → Pro)
    Dashboard/  Media/  Stories/  Merge/  Batch/  Export/  Projects/  Settings/
    ProStudio/  (Part 2)
      StudioView.swift                       editor root & layouts, top bar, banners, busy overlay, panel dividers, iPhone action bar
      StudioViewModel.swift                  state, preview build/refresh, playback, shuttle, zoom, selection, in/out
      StudioViewModel+Editing.swift          commands (split, delete, clipboard, media, tracks, markers, keyframes…)
      StudioViewModel+Gestures.swift         move / trim / blade gesture state
      StudioViewModel+Operations.swift       reverse, nested sequences, export, frame grabbing
      StudioViewer.swift                     viewer, ClipGeometry, canvas handles, guides, transport
      StudioTimelineView.swift               timeline, lanes, track headers, ruler, drag & drop target
      TimelineClipView.swift                 clip view, FilmstripView, WaveformStripView
      StudioToolbar.swift  StudioMediaPanel.swift  StudioKeyCommands.swift  StudioSheets.swift  StudioHubView.swift
      (Part 3) StudioViewModel+Organize / +Audio / +Text / +Captions, StudioOrganizeViews
      (Part 4) StudioViewModel+Intelligence
      (Part 5) StudioViewModel+SmartExtras (faces, privacy blur, subject masks, horizon, music fit, batch color, voice ducking),
               StudioViewModel+AI (assistant context / plans, silences common to all sound, auto duck, transcript suggestions)
      (Part 6) StudioViewModel+Part6 (voiceover, translated captions, suggested music, thumbnail, hook check, shortening)
      Inspector/ InspectorView, TransformInspector, CropMaskChromaInspectors, SpeedInspector,
                 EffectsInspector (+TransitionInspector), AudioInfoInspectors (clip info), KeyframeEditorView
    Color/      (Part 2) ColorWorkspaceView (+ColorQuickInspector), ColorControls, ColorLibraryPanels (+LUTLibraryView)
    AudioStudio/ (Part 3) AudioStudioInspector (+EQGraphView), AudioStudioSheets (mixer, voiceover, SFX, ducking),
                 VolumeAutomationOverlay
    TextStudio/  (Part 3) TextInspector (+FontPickerView), GraphicsInspector (+SymbolPickerSheet), TextLibrarySheets
    Captions/    (Part 3) CaptionsSheet (+CaptionCueList), TranscriptEditorSheet
    Intelligence/ (Part 4) SmartToolsSheet (+ObjectSelectionView), MusicSyncSheet (+MusicEnergyView), EditingDNASheet
                 (+EditingStylesView), QualityInspectorSheet, OutputVariantsSheet, AudioSeparationSheet
                 (+VoiceSeparationModelView), IntelligenceShared (busy overlay inside sheets)
                 (Part 5) SmartToolsExtras (subject mask, privacy blur, horizon sections, BeforeAfterCompareView),
                 BeatAutoEditSheet, (Part 6) ThumbnailSheet, SeriesBuilderView
    Templates/   (Part 4) TemplatesWorkspaceView (+TemplateFillSheet, SaveTemplateSheet; Part 5: share / import)
    AI/          (Part 5) AISettingsView (+consent sheet, AIProviderBadge), AIStudioView, StoryboardView, HighlightsView,
                 ContentStudioView, AssistantSheet (+TypingIndicator, FlowChips), TranscriptAISuggestionsSheet,
                 (Part 6) VoiceoverGeneratorSheet (+VoiceoverOptionsSection), CaptionTranslateSheet (+Apple Translation runner),
                 MusicSuggestSheet, HookCheckSheet, ShortenSheet, AssistantExtrasViews (PlanHistorySheet, AssistantMemoryView)
    Settings/    (Part 6) PerformanceSettingsView (proxies, performance, memory, accessibility)

ClipStudioWidget/  Info.plist  ClipStudioWidget.entitlements  ClipStudioWidget.swift
ClipStudioTests/   SegmentPlannerTests  CoreModelTests  StorageTests  StudioEngineTests (Part 2)  Part3Tests (Part 3)
                   Part4Tests (Part 4)  Part5Tests (Part 5)  Part6Tests (Part 6)
```

## 6. Architecture in one page
- **State**: `@Observable @MainActor` managers created once in `AppEnvironment`, injected with `.environment(...)`. Heavy work runs off the main actor (`Task.detached`, actors, dedicated `Thread`s for the export pump and the reverse renderer).
- **Storage**: `Application Support/ClipStudio/` → `Media/`, `Projects/<id>/project.json` + `versions/`, `Presets/` (+`LUTs/`, `color-presets.json`), `State/` (library, queue, history, settings, `reversed.json`). `Documents/` → `Exports/`, `Backups/`. `Caches/ClipStudio/` → `Thumbnails/`, `Analysis/` (waveforms), `Render/` (blank base video, nested-sequence renders before registration).
- **Render path (preview == export)**: `Timeline` → `CompositionBuilder.build` → AVMutableComposition + custom-compositor video composition + audio mix → `ClipCompositor` (Core Image on Metal).
- **Pro Studio preview**: `StudioViewModel.schedulePreview()` compares a `PreviewStructureKey` (clip ids, timing, sources, speed, audio, track flags, canvas, preview quality). Same key → `BuiltComposition.refreshedVideoComposition(with:)` swaps the current item's `videoComposition` (instant). Different key → debounced full rebuild that keeps the playhead.
- **Editing**: every command builds a draft `Timeline`, runs a pure `TimelineEngine` function and commits through `StudioViewModel.edit(...)` → undo snapshot (`UndoStack`), autosave (`ProjectManager.scheduleAutosave`), preview refresh. Gestures update live state (`MoveDragState`, `TrimDragState`) and commit once on release.
- **Magnetic storyline**: the first video track packs clips with no gaps (`TimelineEngine.compact`); transitions are real overlaps (incoming clip starts `transition.duration` before the previous clip ends). Other tracks use overwrite semantics (`carve`).
- **Nested sequences**: selection → `CompoundClip` (inner timeline) → rendered once by `NestedSequenceRenderer` (export pipeline, HEVC .mov, canvas size) → registered as a generated media asset → a normal `.media(asset)` clip. Opening edits the inner timeline; closing re-renders and `repointCompound` updates every instance.
- **Reverse**: `ReverseRenderer` writes a reversed copy (video + reversed audio) once per source asset; `ReverseLibrary` maps source → reversed asset; clips set `speed.isReversed` + `speed.reversedAssetID` (CompositionBuilder already plays reversed ranges).
- **Audio Studio (Part 3)**: every clip has `ClipAudio.effects` (gain to +24 dB, balance, high-pass, 5-band EQ, spectral noise reduction, compressor, voice enhancement, limiter). `CompositionBuilder` attaches an `MTAudioProcessingTap` (`AudioTapFactory`) to each composition audio track — always in the Studio preview, only where needed for exports. A composition track can carry several timeline clips, so `AudioTapContext` maps each buffer's composition time to the playing clip (`AudioTapSegment`) and runs that clip's `AudioEffectChain`. Parameters come from `AudioParameterStore` (lock-protected); `StudioViewModel.schedulePreview()` pushes edits into it, so effect changes are heard without a rebuild (effects are excluded from `PreviewStructureKey` via `ClipAudio.mixSignature`). Taps also feed `AudioMeterStore` for the mixer meters. Solo is resolved in `build` (non-solo tracks get no audio placements). Volume automation stays in `AVAudioMix` ramps (applied after the tap: PreEffects).
- **Captions (Part 3)**: `TranscriptionService` (Speech) transcribes only the untranscribed source spans (`AssetTranscript.missing`) in ≤ 50 s chunks cut at quiet points; transcripts are cached per asset + language in `State/Transcripts/`. `CaptionBuilder` maps words through each clip's trim/speed (`SpeedMapping.localTime`) and groups them into `CaptionCue`s; caption clips are `.text` clips with `TextContent.caption` (word timing, clip-local). `GeneratedContentRenderer` renders the active-word highlight (cache keyed by active word). `ClipKeyframes` keeps word timing through split/join/retime. Server recognition is used only when the user enables it for a language without on-device support (shown in the sheet).
- **Text-based editing (Part 3)**: `TranscriptEditorSheet` → `StudioViewModel.removeTimelineRanges` → `TimelineEngine.removeRanges` (carve + shift on every unlocked track; markers follow on the main timeline) as one undo step.
- **Watermark (Part 3)**: `ProjectSettings.watermark` → `WatermarkResolver` (once per build) → `RenderInstruction.watermark` → drawn last by `ClipCompositor`. Excluded from nested-sequence renders.
- **Smart reframe & tracking (Part 4)**: `FrameSampler` (batch `AVAssetImageGenerator.images(for:)`) feeds Vision. `SubjectTracker.detect` (faces → humans → attention saliency, 8 fps) or `trackObject` (`VNTrackObjectRequest`, 15 fps) produce a `SubjectTrack` in source time, cached per asset + range + mode. `ReframeEngine.cropKeyframes` turns it into crop keyframes for the canvas aspect (two-pass exponential smoothing, hold through gaps); `followPositions` maps the subject through crop + `ClipGeometry.corners` into overlay position keyframes.
- **Stabilization (Part 4)**: `StabilizationAnalyzer` (translational registration between consecutive 480 px frames at 15 fps) → cumulative camera path per file, cached. `StabilizationStore` (lock-protected, preloaded in `CompositionBuilder.build`) returns `raw − boxSmoothed` at any source time; `LayerRenderer.stabilized` shifts + zooms the source frame before the crop.
- **Music (Part 4)**: `MusicAnalyzer` streams 22.05 kHz mono → STFT 1024/512 → log spectral flux (+ low band, loudness) → tempo (autocorrelation with a 120 BPM log-normal prior) → beats (Ellis DP; links only when they improve the score) → downbeats (strongest low-band phase mod 4) → energy (10/s), sections (energy novelty, snapped to downbeats) and the drop. `BeatSync` maps beats through the music clip's speed and re-times a track with `TimelineEngine.trimmedEnd/trimmedStart`.
- **Editing DNA (Part 4)**: `EditingDNAAnalyzer.extract(project)` / `ReferenceAnalyzer.analyze(url)` → `EditingDNA` (stored by `EditingDNAStore` in Presets/editing-dna.json). `EditingDNAApplier.matchColors` (async, `ColorMatcher` vs the DNA's reference JPEG) then `EditingDNAApplier.apply` (pure) inside one `edit(...)`.
- **Separation (Part 4)**: `SpectralVoiceSeparator` (STFT 2048/512, √Hann, perfect reconstruction) computes a voice mask per bin (stereo coherence, noise-floor Wiener for mono, or a Core ML mask in batches of T frames) and writes voice + (original − voice) to two AAC files via `AVAudioFile`.
- **Quality / variants / templates (Part 4)**: `QualityInspector.inspect` (pure) + `deepScan` (LoudnessAnalyzer + graded source frames) + `apply(fix)` (pure). `OutputVariants.makeVariant` copies a project for another `OutputFormat`. `StudioTemplateLibrary` (Presets/Templates/<id>.json) `makeTemplate` / `fill` are pure and `nonisolated`.
- **AI (Part 5)**: features build an `AIRequest` (+ `AILocalInput`) → `AIRequestRouter.perform(_:forceLocal:stream:onText:)` → `GeminiProvider` (`GeminiClient.generate` / `stream`, REST + `x-goog-api-key`) or `LocalAIProvider` (same JSON / function calls on device). The router checks `AIUsageManager` (daily limit, 429 cool-down), `AICacheManager` (7-day answers, 46 h uploads), records usage and falls back on device when `GeminiError.allowsLocalFallback`. `AIResponseValidator` turns replies into safe values; `AIPlanExecutor` applies pure assistant steps on a draft (each step on its own copy); deferred steps run in `StudioViewModel+AI` after the edit. Consent: `withAIConsent(task:sendsMedia:summary:present:action:)` + `.aiConsent($)`. The key: `KeychainStore` (account `gemini.apiKey`), never in backups.
- **Suggestions (Part 5)**: tracked masks are `MaskSettings.centerTrack / sizeTrack` (clip-local keyframes; `ClipKeyframes` splits / flattens them; `LayerRenderer` resolves them per frame). Horizon: `HorizonStore` (preloaded in `CompositionBuilder.build`) → `LayerRenderer` rotates by −angle × strength with `HorizonAnalyzer.coverScale`. Privacy blur: silent overlay copy + effect + tracked ellipse mask whose size goes to 0 outside the detection span. `MusicFit.fit` / `AutoEditBuilder.build` are pure.
- **Proxies (Part 6)**: `MediaLibrary.onAssetAdded / onAssetRemoved` → `ProxyManager` (queue, one `AVAssetExportSession` at a time, paused when `PerformanceMonitor.shouldPauseBackgroundWork`). `StudioViewModel.rebuildPreview` uses `env.proxies.previewMap(env.library.urlMap())`; `StudioView` rebuilds on `proxies.version`. Every other render path keeps `library.urlMap()` (originals).
- **Performance (Part 6)**: `PerformanceMonitor.shared` (thermal / power / memory notifications) → `previewCap` is folded into `previewShortSide` (part of `PreviewStructureKey`); `reducesEffects` stops `AppBackground` animation; `purgeCaches()` on memory warnings (replaces the Part 1 observer in `AppEnvironment`).
- **Part 6 AI additions**: `AITask.translation / hookCheck / shorten`; `AILocalInput.hook / .shorten` answered by `HookAnalyzer.local` / `SmartShortener.local`; `AIRequestRouter.speech` (Gemini TTS, PCM → WAV); `AssistantMemory.promptSummary` appended to assistant prompts and `preferredTransition` fed to `LocalCommandParser` / `AIResponseValidator`; `PlanHistoryStore` records applied plans from `AssistantSheet`.
- **Color**: `FramePreviewRenderer` grabs the clip's real frame (or the composite under an adjustment layer via the current preview build) and grades it with `ColorPipeline` for the workspace preview, histogram, LUT/look thumbnails and `ColorMatcher`.

## 7. Places most likely to need compile fixes (fix, don't remove)
| Area | File | What to watch |
|---|---|---|
| Custom compositor | `Engines/Rendering/ClipCompositor.swift` | `AVVideoCompositing` signatures on the newest SDK. |
| Core Image keys | `ColorPipeline`, `EffectRenderer`, `TransitionRenderer`, `FramePreviewRenderer` (`CIAreaHistogram`), `CropMaskChromaInspectors` (`CICheckerboardGenerator`) | String keys fail at runtime, not compile time — verify visually. |
| Photos import | `MediaImportManager`, `MediaImportControls` | `Transferable` / `FileRepresentation`. |
| Passthrough export | `ExportEngine` | `AVAssetExportSession.export()` deprecated on iOS 18 SDK → warning only. |
| Reverse renderer | `Engines/Media/ReverseRenderer.swift` | CoreMedia C APIs (`CMSampleBufferCreateCopyWithNewTiming`, `CMAudioSampleBufferCreateReadyWithPacketDescriptions`, `CMBlockBufferReplaceDataBytes`) — argument labels; runs on its own `Thread`. |
| Keyboard | `StudioKeyCommands.swift` | `focusable()`, `onKeyPress(phases:)`, `KeyEquivalent` cases (iOS 17). If `View` extension isolation complains, keep the explicit `@MainActor`. |
| Apple Pencil | `StudioKeyCommands.swift` (`PencilDoubleTapView`) | `pencilInteractionDidTap` is deprecated in iOS 17.5 (warning); the iOS 17.5 `pencilInteraction(_:didReceiveTap:)` is also implemented. |
| Gestures | `StudioViewer.swift`, `StudioTimelineView.swift`, `TimelineClipView.swift` | `MagnifyGesture`, `RotateGesture`, `SpatialTapGesture`, `highPriorityGesture(_:including:)`, `onContinuousHover`, `dropDestination`. |
| Swift concurrency | `StudioViewModel+Operations.swift` | Tasks capture only `let` values; progress goes through `ProgressRelay` (`@unchecked Sendable`). |
| Result builders | Inspector / Color views | Local `let` declarations inside `if`/`switch` in view builders; if the type-checker times out, split the view into a sub-`View`. |
| Widget | `ClipStudioWidget.swift` | `containerBackground(for: .widget)` required on iOS 17. |
| Tests | `ClipStudioTests/*` | `@testable import ClipStudio`; `testUndoCoalescingAndRedo` is `@MainActor`. |
| Audio tap (Part 3) | `Engines/Audio/AudioTapProcessor.swift` | `MTAudioProcessingTapCallbacks` field labels (`init:` …), `MTAudioProcessingTapCreate` out-parameter type (`MTAudioProcessingTap?` on current SDKs), the integer types of `kMTAudioProcessingTapCallbacksVersion_0` / `kMTAudioProcessingTapCreationFlag_PreEffects` (wrapped in `Int32(...)` / `MTAudioProcessingTapCreationFlags(...)`). Callbacks must stay capture-free globals. |
| vDSP (Part 3) | `Engines/Audio/AudioDSP.swift` | `vDSP_ctoz` / `vDSP_ztoc` / `vDSP_fft_zrip` pointer arguments; `UnsafeMutablePointer.update(...)` (Swift 5.8+). |
| Speech (Part 3) | `Engines/Captions/TranscriptionService.swift` | `SFSpeechURLRecognitionRequest.addsPunctuation` (iOS 16), recognition handler called more than once (guarded by `ResumeGate`). |
| Locks (Part 3) | `AudioTapProcessor.swift` | `OSAllocatedUnfairLock(uncheckedState:)` + `withLockUnchecked` (iOS 16). |
| Recorder (Part 3) | `Engines/Audio/VoiceoverRecorder.swift` | `AVAudioApplication.requestRecordPermission()` (iOS 17). |
| Context menu preview (Part 3) | `TimelineClipView.swift` | `.contextMenu(menuItems:preview:)` (iOS 16). |
| Vision (Part 4) | `Engines/Vision/*`, `ReferenceAnalyzer.swift` | `VNDetectHumanRectanglesRequest`, `VNGenerateAttentionBasedSaliencyImageRequest.results?.first?.salientObjects`, `VNTrackObjectRequest(detectedObjectObservation:)` + `VNSequenceRequestHandler.perform(_:on: CGImage)`, `VNTranslationalImageRegistrationRequest(targetedCGImage:options:)` → `VNImageTranslationAlignmentObservation.alignmentTransform`, `VNRecognizeTextRequest`. |
| Batch frames (Part 4) | `FrameSampler.swift` | `AVAssetImageGenerator.images(for:)` async sequence and its `.success(requestedTime:image:actualTime:)` / `.failure` cases (iOS 16). |
| vDSP (Part 4) | `MusicAnalyzer.swift`, `SourceSeparator.swift` | same `vDSP_ctoz` / `vDSP_fft_zrip` / `vDSP_ztoc` pointer patterns as Part 3; `vDSP_measqv`. |
| Core ML (Part 4) | `SourceSeparator.swift` | `MLModel.compileModel(at:)` async (iOS 16), `MLMultiArray.dataPointer` / `strides`, `MLDictionaryFeatureProvider`. |
| Audio files (Part 4) | `SourceSeparator.swift` | `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`, `AVAudioPCMBuffer.floatChannelData`, `UnsafeMutablePointer.update(from:count:)`. |
| Gemini REST (Part 5) | `Engines/AI/GeminiClient.swift` | `URLSession.bytes(for:)` + `AsyncBytes.lines` for SSE; `URLSession.upload(for:fromFile:delegate:)` for the Files API; `UploadProgressDelegate` is `@unchecked Sendable`. Request keys are camelCase (`systemInstruction`, `generationConfig`, `responseSchema`, `functionDeclarations`, `inlineData`, `fileData`). The `Task { [self] in … }` inside `stream` must keep the explicit capture. |
| AI isolation (Part 5) | `AIFeatureService.swift`, `AIModelManager.swift`, `StudioViewModel+AI.swift` | `@MainActor` types expose pure helpers as `nonisolated static` (tests call them directly: `timeline(for:)`, `reel`, `contentInput`, `bestFlash`, `subtract`). `AISettings.shared` is read on the main actor only. |
| Proxy export (Part 5) | `AIMediaPreparer.proxyVideo` | `AVAssetExportSession.export()` is deprecated on the iOS 18 SDK (warning only); keep it (iOS 17 target). |
| Keychain (Part 5) | `KeychainStore.swift` | `SecItemCopyMatching` result cast (`CFTypeRef?` → `Data`), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. |
| NaturalLanguage (Part 5) | `LocalAIProvider.keywords` | `NLTagger.enumerateTags(in:unit:scheme:options:)` closure returns `Bool`; falls back to plain word counts when the language has no tagger. |
| Horizon (Part 5) | `HorizonLeveler.swift` | `VNDetectHorizonRequest` → `VNHorizonObservation.angle`; `OSAllocatedUnfairLock(uncheckedState:)`. |
| Translation (Part 6) | `Features/AI/CaptionTranslateSheet.swift` | `.translationTask(_:action:)`, `TranslationSession.Configuration(source:target:)`, `.invalidate()`, `TranslationSession.Request(sourceText:clientIdentifier:)`, `translations(from:)` — all iOS 18, behind `#available` and `#if canImport(Translation)`; the framework is weak-linked in project.yml. |
| Speech synthesis (Part 6) | `Engines/AI/SpeechSynthesis.swift` | `AVSpeechSynthesizer.write(_:toBufferCallback:)` buffer type (`AVAudioBuffer` → `AVAudioPCMBuffer`), `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`, `withTaskCancellationHandler`. The writer must stay retained until finished (it is, by the awaiting call). |
| Dictation (Part 6) | `Engines/Captions/LiveDictation.swift` | `AVAudioEngine.inputNode.installTap` closure (audio thread → hop to MainActor), `SFSpeechAudioBufferRecognitionRequest.requiresOnDeviceRecognition / addsPunctuation`, audio session restored to `.playback` after. |
| Memory (Part 6) | `Engines/Performance/PerformanceMonitor.swift` | `task_info(mach_task_self_, TASK_VM_INFO, …)` pointer rebinding, `os_proc_available_memory()` (`import os`), `MainActor.assumeIsolated` in notification blocks (queue `.main`). |
| Proxies (Part 6) | `Engines/Performance/ProxyManager.swift` | `AVAssetExportPreset960x540 / 1280x720`, `AVAssetExportSession.export()` (deprecated on iOS 18 SDK — warning only). |
| Vision (Part 6) | `ThumbnailMaker.swift` | `VNDetectFaceCaptureQualityRequest` → `faceCaptureQuality` (Float?); `AVAssetImageGenerator.image(at:)` async (iOS 16). |
| Isolation (Part 4) | `StudioTemplateLibrary.swift` | pure helpers are `nonisolated static` on a `@MainActor` class (tests call them directly). Engine progress callbacks are `@Sendable`. |

## 8. Manual QA checklist
Part 1:
1. First launch opens on الرئيسية, Arabic RTL, English digits, no login.
2. Media import (Photos + Files), duplicate warning, relink.
3. Smart Stories split/export; Merge with transitions + music; Batch pause/resume/cancel/recovery.
4. Backup → restore round trip; widget with App Group.

Part 2 (الاستوديو):
5. New project from the Studio tab with 3 videos + 1 photo + 1 song → clips land on the primary/audio tracks; preview plays; export 1080p.
6. Scrub (drag), fling, pinch zoom, zoom to fit; ruler tap seeks; timecode "go to".
7. Select a clip → drag to move (snapping guide + haptic), drag to the overlay track (ghost), trim both edges, blade cut, split at playhead, join, ripple delete, duplicate, copy/paste, paste attributes, undo/redo every step.
8. Magnetic on/off; transitions (apply, change duration, remove, apply to all cuts) — following clips shift correctly.
9. Canvas handles: move/pinch/rotate, PiP preset, keyframes on position/scale/opacity (◆), keyframe editor easing/retime.
10. Crop editor with aspect lock + animated crop; mask (ellipse) drag/resize/feather/invert; chroma key with eyedropper on green screen footage.
11. Speed 0.25×/4×, ramp preset + drag points; reverse (progress, cancel, then again → instant reuse); freeze frame; detach audio.
12. Effects add/reorder/disable/keyframe; adjustment layer graded over two clips.
13. Color workspace: sliders, curve, wheels, before/after split drag, histogram, import a .cube LUT, save a look, match one clip to another.
14. Nested sequence: select 3 clips → ⌘G (or toolbar) → open (double tap) → edit → back (re-render progress) → change visible in the main timeline → break apart.
15. iPad: resize panels, layout presets, save custom layout; hardware keyboard J/K/L, Space, I/O, M, S, B, ⌘Z; Pencil double-tap toggles blade; Pencil hover scrubs the viewer.
16. Kill the app mid-edit → relaunch → recovery banner → reopens the editor with the latest autosave.

Part 3:
17. New project from a template (Reels / YouTube / slideshow) → colored, named tracks; slideshow photos get crossfades and slow zoom.
18. Drag a marker on the ruler; color a track; "select all clips of this file"; close gaps on a track; long-press a clip → looping preview; project summary.
19. Aspect lock off → edge handles stretch width/height; motion presets (Ken Burns, fades, pop) applied to several clips; save your own motion.
20. Snapshot (⇧⌘S) → PNG in Photos and in Files → ClipStudio → Exports, at full canvas resolution.
21. Audio inspector: gain +12 dB (no clipping with limiter), EQ graph drag, noise reduction on a noisy clip (heard live while playing), voice enhance, compressor; presets.
22. Mixer: meters move during playback, solo / mute / balance per track; export M4A and share.
23. Volume automation: draw points on a music clip, drag them, double-tap to delete. Ducking: music dips under the voice track.
24. Normalize loudness to −14 LUFS; extract audio to a file (appears in the media library).
25. Voiceover: count-in, record while the timeline plays (muted), stop → clip on the voiceover track at the start position.
26. Sound effects: preview, add at playhead (second use reuses the same library file).
27. Titles: type Arabic text → add lower third / banner / quote; edit font (Arabic fonts first), outline, shadow, background, kerning, animations (blur / wipe / bounce / spin) and loops; save a text style.
28. Shapes (star, arrow, heart, bubble), emoji and SF-symbol stickers with loop animation; image overlay.
29. Watermark (text and logo) visible in preview and export, not doubled inside nested sequences.
30. Captions: Arabic on-device (or server after consent) → captions on the captions track with word highlight styles; edit text, split, merge, sync ±0.1 s, restyle all; export SRT/VTT; import SRT.
31. Text-based editing: mark filler words and long pauses → delete → all tracks cut in sync, markers move, one undo restores.

Part 4 (الذكاء على الجهاز):
32. 16:9 interview in a 9:16 project → long-press → «تتبع وإعادة تأطير وتثبيت» → analyze faces → the crop follows the face smoothly; change smoothing / zoom and re-apply; undo.
33. Object tracking: draw a box around a moving object → track (progress + cancel) → «إعادة التأطير على العنصر»; add a title and make it follow the object.
34. Shaky handheld clip → stabilize → playback is steady; change strength / zoom (instant), suggested zoom, disable, remove; export shows the same result.
35. Music clip → «الموسيقى والإيقاع» → analyze (BPM, beats, energy view, drop) → cut a photo/video track every 2 beats with crossfades on every cut → cuts land on beats; add beat markers; remove them.
36. «أسلوب المونتاج»: apply «ريلز سريع» to a project (pacing, transitions, look, captions restyled, stills animated) → one undo restores; learn the current project's style; learn a reference video from Files (progress, no import) → apply with color matching.
37. Save a project as a template (keep music) → Dashboard → القوالب → fill slots (one + several in order, a short video) → new project opens with the template timing.
38. Song or stereo video → «فصل الكلام عن الخلفية» → two new tracks (الكلام / الخلفية), original muted; solo each stem; mono recording → voice-vs-noise; import a compatible Core ML model in Settings → method appears.
39. «فحص الجودة»: create a gap, a 1-frame clip, a title near the edge, a hidden track → each is listed → fixes work (gap closes on all tracks) → deep scan reports loud / dark clips with fixes.
40. «نسخ بمقاسات أخرى»: 16:9 project → 9:16 + 1:1 smart → new projects appear (original unchanged), titles inside the safe area, captions re-wrapped; "export all" queues both.
41. Backup → restore on a clean install: editing styles and templates come back.

Part 5 — suggestions:
42. Interview clip → «الأدوات الذكية» → «تمويه الوجوه للخصوصية» → «ابحث عن الوجوه» → choose one face → blur / pixelate / black box follows the face; the box disappears outside the detection span; undo.
43. «قناع يتبع العنصر» → spotlight darkens everything but the subject; remove the mask.
44. Tilted horizon clip → «ضبط الأفق» → «اضبط الأفق» (progress) → horizon straight, no black corners; change strength / smoothing; export matches.
45. Music longer / shorter than the picture → «الموسيقى والإيقاع» → ملاءمة النهاية: end on bar, keep ending, loop → listen to the joins.
46. Dashboard → «مونتاج تلقائي على الإيقاع»: 8 photos + 3 videos + a song + «ريلز سريع» → new project, cuts on beats, music fades at the end.
47. Match all shots to the current frame (one undo); duck music under a chosen voice track; before / after compare in the color tools.
48. Export with a problem (gap, hidden track) → quality check dialog → «مراجعة المشاكل» / «تصدير على أي حال»; turn the check off in studio preferences.
49. Share an editing style and a template (.csstyle / .cstemplate) via the share sheet → import on another device → appears with a new ID.

Part 5 — AI:
50. Settings → الذكاء الاصطناعي: paste a key → test connection → model list loads, newest flash selected; key masked; remove key → tools show «على الجهاز».
51. No internet → Arabic "no connection" + on-device fallback note; wrong key → Arabic invalid-key error (no fallback); many fast requests → 429 message with wait time; daily limit reached → blocked with a message.
52. AI Studio → القصة المصورة: idea + 30 s + 5 media → consent (frames listed) → scenes stream in; edit / reorder / delete a scene → create project → shots, titles, scene markers.
53. أفضل اللقطات: 10-minute video → frames mode and "whole video" mode (consent shows the upload size; upload progress; cancel) → moments with scores → reel and one project per moment.
54. استوديو المحتوى: project with captions → TikTok / Instagram / X → per-platform posts within limits (counter), edit, copy, share; reopen → saved.
55. Studio → المساعد: "احذف الصمت وأضف عنوان «مرحبا» فوق" → streamed answer + plan; untick a step; preview → keep / undo; apply → one undo restores; offline toggle → same request works with the on-device parser.
56. Transcript editor → «اقتراحات الذكاء» → fillers / repetitions / pauses suggested → «حدّد في النص» → marked words → delete → tracks cut in sync.
57. «أسلوب المونتاج» → learn from a reference video → with a key, the consent sheet offers AI refinement (8 frames) → toast «حُسّن الأسلوب…»; «استخدم المعالج على الجهاز بدلًا» keeps the local result; without a key no offer appears.
58. Usage screen counts requests / tokens; clear cache; backup → restore keeps Content Studio posts but never the key.

Part 6 — suggestions:
59. Studio → الذكاء الاصطناعي → «تعليق صوتي من نص»: Arabic text, device voice (and an enhanced voice if installed) → listen → add → clip on the voiceover track at the playhead; with a key, Gemini voice "Kore" with a style → add.
60. Storyboard with voice-over lines → toggle «تعليق صوتي مولّد» → create → each line on the "تعليق صوتي" track at its scene; overlapping lines move later.
61. Captions in Arabic → «ترجمة الترجمة النصية» → English via Gemini (fix a line) → new captions track, original hidden; on iOS 18 without a key → Apple Translation (language download prompt) → same result; undo removes the new track.
62. Assistant: mic → say "احذف الصمت" → text appears live → auto-sends after a pause; language without on-device support → consent dialog; audio session returns to playback (Studio sound works after).
63. Apply plans with "تلاشي للأسود" twice → «ذاكرة المساعد» shows it → "أضف انتقالات" (offline) uses fade to black; write a note → forget / clear.
64. «سجل الخطط»: applied plans listed with search; apply one again (deleted clips reported); delete; clear; project deletion removes its history.
65. «اقتراح موسيقى»: 5+ songs in the library → analyze (progress, cancel) → mood chips re-rank instantly → listen → add → music fitted to the picture end.
66. «صورة مصغرة تلقائية» → best frames (sharp, faces) first → text in Arabic at bottom / top, gold / white → save to Photos + Files; share.
67. «فحص الخطّاف قبل النشر»: project starting with 2 s of black and late speech → low score, fixes "حذف البداية" / "عنوان" work and undo; with a key, consent lists 6 frames.
68. «اختصار ذكي»: 2-minute talking video (transcribed) → 30 s → sentences chosen, toggle, resulting length updates → «اختصر» → all tracks cut in sync, one undo restores.
69. Dashboard → «سلسلة حلقات»: 3 videos, name, style, song, outro, "add to export" → 3 projects "… — الحلقة 1/2/3" and 3 export jobs.

Part 6 — performance & accessibility:
70. Import a 4K video → proxy is created automatically (Settings › الأداء… shows progress) → Studio preview plays smoothly; export is still 4K quality; delete proxies → preview uses the original.
71. Turn on Low Power Mode with the Studio open → banner "وضع توفير الطاقة — المعاينة مؤقتًا 540p", background stops; turn off → back to chosen quality.
72. Simulate a memory warning (Xcode Debug › Simulate Memory Warning) → counter increments, thumbnails reload, nothing lost.
73. VoiceOver: swipe through timeline clips (kind, times, speed read), use the rotor actions (split, move ±1 s, delete); adjust the playhead by swiping up/down; toasts are spoken. Larger trim handles option makes handles wider.
74. Backup → restore: plan history and assistant memory come back (merged); proxies are not in the backup and are rebuilt.

## 9. After Part 6
All six parts are written. Compile with GitHub Actions, fix errors in place (§7), run `ClipStudioTests`, walk the QA checklist on device, and update `docs/FEATURE_STATUS.md`.
