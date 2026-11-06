# Part 5 — files to add / replace

Apply on top of Part 4. Paths are repo paths. **Nothing to delete. No change to project.yml, Info.plist or the workflow**:
- XcodeGen picks up the new folders (`Engines/AI`, `Features/AI`) automatically (the target uses the `ClipStudio` folder as its source).
- The workflow already writes `ClipStudio/Generated/BuildSecrets.swift` from the optional `GEMINI_API_KEY` repository secret (Part 1). Nothing else is needed for Gemini.
- No new permissions: Gemini calls are plain HTTPS (allowed by App Transport Security), and the Keychain needs no entitlement.

This part contains two things:
1. **The 10 Part-4 suggestions** (face blur, subject masks, horizon leveling, music ending fit, beat auto-edit, batch color match, ducking under a chosen voice, before/after compare, export quality check, style / template sharing).
2. **Part 5 — AI layer**: provider architecture, Gemini over REST (structured output, streaming, Files API, function calling), AI Storyboard, Smart Highlights, Content Studio, the AI Editing Assistant, AI suggestions for text-based editing, and AI enrichment of reference styles.

## Add (33 new files)
```
ClipStudio/Engines/AI/AICacheManager.swift
ClipStudio/Engines/AI/AIFeatureService.swift
ClipStudio/Engines/AI/AIMediaPreparer.swift
ClipStudio/Engines/AI/AIModelManager.swift
ClipStudio/Engines/AI/AIPlanExecutor.swift
ClipStudio/Engines/AI/AIPromptManager.swift
ClipStudio/Engines/AI/AIRequestRouter.swift
ClipStudio/Engines/AI/AIResponseValidator.swift
ClipStudio/Engines/AI/AISettings.swift
ClipStudio/Engines/AI/AIUsageManager.swift
ClipStudio/Engines/AI/ContentStore.swift
ClipStudio/Engines/AI/GeminiClient.swift
ClipStudio/Engines/AI/KeychainStore.swift
ClipStudio/Engines/AI/LocalAIProvider.swift
ClipStudio/Engines/Intelligence/ColorMatchBatch.swift
ClipStudio/Engines/Music/AutoEditBuilder.swift
ClipStudio/Engines/Music/MusicFit.swift
ClipStudio/Engines/Presets/StyleSharing.swift
ClipStudio/Engines/Vision/FaceTracker.swift
ClipStudio/Engines/Vision/HorizonLeveler.swift
ClipStudio/Features/AI/AISettingsView.swift
ClipStudio/Features/AI/AIStudioView.swift
ClipStudio/Features/AI/AssistantSheet.swift
ClipStudio/Features/AI/ContentStudioView.swift
ClipStudio/Features/AI/HighlightsView.swift
ClipStudio/Features/AI/StoryboardView.swift
ClipStudio/Features/AI/TranscriptAISuggestionsSheet.swift
ClipStudio/Features/Intelligence/BeatAutoEditSheet.swift
ClipStudio/Features/Intelligence/SmartToolsExtras.swift
ClipStudio/Features/ProStudio/StudioViewModel+AI.swift
ClipStudio/Features/ProStudio/StudioViewModel+SmartExtras.swift
ClipStudio/Models/AI.swift
ClipStudioTests/Part5Tests.swift
```

## Replace (28 changed code files — full new versions)
```
ClipStudio/App/AppRouter.swift
ClipStudio/App/ContentView.swift
ClipStudio/Engines/Intelligence/EditingDNAEngine.swift
ClipStudio/Engines/Presets/StudioPreferences.swift
ClipStudio/Engines/Presets/StudioTemplateLibrary.swift
ClipStudio/Engines/Project/ProjectManager.swift
ClipStudio/Engines/Rendering/CompositionBuilder.swift
ClipStudio/Engines/Rendering/LayerRenderer.swift
ClipStudio/Engines/Storage/BackupManager.swift
ClipStudio/Engines/Timeline/ClipKeyframes.swift
ClipStudio/Features/Captions/TranscriptEditorSheet.swift
ClipStudio/Features/Dashboard/DashboardView.swift
ClipStudio/Features/Intelligence/AudioSeparationSheet.swift
ClipStudio/Features/Intelligence/EditingDNASheet.swift
ClipStudio/Features/Intelligence/MusicSyncSheet.swift
ClipStudio/Features/Intelligence/SmartToolsSheet.swift
ClipStudio/Features/ProStudio/StudioHubView.swift
ClipStudio/Features/ProStudio/StudioSheets.swift
ClipStudio/Features/ProStudio/StudioToolbar.swift
ClipStudio/Features/ProStudio/StudioView.swift
ClipStudio/Features/ProStudio/StudioViewModel+Intelligence.swift
ClipStudio/Features/ProStudio/StudioViewModel.swift
ClipStudio/Features/ProStudio/TimelineClipView.swift
ClipStudio/Features/Settings/SettingsView.swift
ClipStudio/Features/Templates/TemplatesWorkspaceView.swift
ClipStudio/Models/Effects.swift
ClipStudio/Models/Intelligence.swift
ClipStudio/Models/Timeline.swift
```

Docs replaced: `README.md`, `docs/FEATURE_STATUS.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/HANDOFF.md`; added `docs/PART5_CHANGES.md` (this file).

## Delete
Nothing.

## Data / compatibility
- Old projects open unchanged: the new `Clip.horizon` and `MaskSettings.centerTrack / sizeTrack` fields are optional and decode as nil from older files.
- New app-data files (all under Application Support / Caches, created on first use):
  - `State/ai-usage.json` — daily request / token counts (local only).
  - `State/ai-uploads.json` — Gemini Files uploaded in the last 46 h (so a video is not uploaded twice).
  - `State/AIContent/<projectID>.json` — saved Content Studio posts (included in backups; merged on restore; deleted with the project).
  - `Caches/AI/` — cached AI answers (7 days; clearable in AI settings).
  - `Caches/Analysis/<asset>-faces-…json`, `<asset>-horizon-v1.json` — face / horizon analyses.
- The Gemini key lives only in the Keychain (`com.rashid.clipstudio.secrets`, this device only) and is **never** written to backups, logs or project files.
