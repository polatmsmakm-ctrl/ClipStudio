# Part 6 — files to add / replace

Apply on top of Part 5. Paths are repo paths. **Nothing to delete.**

- **One build-setting change:** `project.yml` weak-links Apple's Translation framework (`OTHER_LDFLAGS: -weak_framework Translation`). That framework is only used on iOS 18+, so the app still launches on iOS 17.
- No change to Info.plist or the workflow. No new permissions: voice commands use the Microphone and Speech Recognition strings that already exist (Part 3).

This part contains two things:
1. **The 10 Part-5 suggestions:**
   - generated voiceover (device voices or Gemini TTS), including from the storyboard;
   - caption translation (Gemini, or Apple on-device on iOS 18+);
   - voice commands for the assistant;
   - assistant memory;
   - music suggestions from your library;
   - automatic thumbnail;
   - pre-publish hook check;
   - assistant plan history;
   - smart shortening ("make it 30 seconds");
   - episode series builder.
2. **Part 6:**
   - proxy media for a smooth preview;
   - performance monitor (heat, Low Power Mode, memory warnings, adaptive preview);
   - accessibility pass (VoiceOver clip actions, playhead adjustable, spoken toasts, larger trim handles, still background in Low Power / heat);
   - performance & accessibility settings screen;
   - tests;
   - final docs.

## Add (24 new files)
```
ClipStudio/Components/AccessibilityPrefs.swift
ClipStudio/Engines/AI/AssistantMemory.swift
ClipStudio/Engines/AI/CaptionTranslator.swift
ClipStudio/Engines/AI/HookAnalyzer.swift
ClipStudio/Engines/AI/SmartShortener.swift
ClipStudio/Engines/AI/SpeechSynthesis.swift
ClipStudio/Engines/Captions/LiveDictation.swift
ClipStudio/Engines/Intelligence/SeriesBuilder.swift
ClipStudio/Engines/Intelligence/ThumbnailMaker.swift
ClipStudio/Engines/Music/MusicRecommender.swift
ClipStudio/Engines/Performance/PerformanceMonitor.swift
ClipStudio/Engines/Performance/ProxyManager.swift
ClipStudio/Features/AI/AssistantExtrasViews.swift
ClipStudio/Features/AI/CaptionTranslateSheet.swift
ClipStudio/Features/AI/HookCheckSheet.swift
ClipStudio/Features/AI/MusicSuggestSheet.swift
ClipStudio/Features/AI/ShortenSheet.swift
ClipStudio/Features/AI/VoiceoverGeneratorSheet.swift
ClipStudio/Features/Intelligence/SeriesBuilderView.swift
ClipStudio/Features/Intelligence/ThumbnailSheet.swift
ClipStudio/Features/ProStudio/StudioViewModel+Part6.swift
ClipStudio/Features/Settings/PerformanceSettingsView.swift
ClipStudio/Models/AIExtras.swift
ClipStudioTests/Part6Tests.swift
```

## Replace (27 changed files — full new versions)
```
project.yml
ClipStudio/App/AppEnvironment.swift
ClipStudio/App/AppRouter.swift
ClipStudio/App/ContentView.swift
ClipStudio/Components/AppBackground.swift
ClipStudio/Components/Feedback.swift
ClipStudio/Engines/AI/AIPromptManager.swift
ClipStudio/Engines/AI/AIRequestRouter.swift
ClipStudio/Engines/AI/AIResponseValidator.swift
ClipStudio/Engines/AI/GeminiClient.swift
ClipStudio/Engines/AI/LocalAIProvider.swift
ClipStudio/Engines/Media/MediaLibrary.swift
ClipStudio/Engines/Project/ProjectManager.swift
ClipStudio/Engines/Storage/BackupManager.swift
ClipStudio/Features/AI/AIStudioView.swift
ClipStudio/Features/AI/AssistantSheet.swift
ClipStudio/Features/AI/StoryboardView.swift
ClipStudio/Features/Dashboard/DashboardView.swift
ClipStudio/Features/ProStudio/StudioSheets.swift
ClipStudio/Features/ProStudio/StudioView.swift
ClipStudio/Features/ProStudio/StudioViewModel+AI.swift
ClipStudio/Features/ProStudio/StudioViewModel.swift
ClipStudio/Features/ProStudio/StudioViewer.swift
ClipStudio/Features/ProStudio/TimelineClipView.swift
ClipStudio/Features/Settings/SettingsView.swift
ClipStudio/Models/AI.swift
ClipStudioTests/Part5Tests.swift
```
`ClipStudioTests/Part5Tests.swift` only changes how two JSON fixtures are typed (explicit `[String: Any]`), the assertions are the same.

Docs replaced:
- `README.md`
- `docs/FEATURE_STATUS.md`
- `docs/IMPLEMENTATION_PLAN.md`
- `docs/HANDOFF.md`

Docs added: `docs/PART6_CHANGES.md` (this file).

## Delete
Nothing.

## Data / compatibility
- Old projects open unchanged. Assistant plans saved by Part 5 had no history; `AIPlan` is now Codable, and plan history starts from this version.
- New app-data files, all created on first use:
  - `Caches/ClipStudio/Proxies/<asset>-p540|p720.mp4` — proxy videos. iOS may purge them; they are rebuilt. Never backed up.
  - `State/proxies.json` — proxy registry, tied to each original's fingerprint. Excluded from backups.
  - `State/AIPlans/<projectID>.json` — assistant plan history (last 50). Backed up, restored for missing projects, deleted with the project.
  - `State/assistant-memory.json` — learned preferences + the user's notes. Backed up and merged on restore.
- Generated voiceovers and the storyboard voiceover are normal audio assets in the media library.
- Thumbnails are JPEG files in Exports, and in Photos when allowed.
- Exports, frame snapshots, analyses and AI tools always read **original** media — proxies are used only by the Studio preview.
