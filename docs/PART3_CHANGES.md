# Part 3 — files to add / replace

Apply on top of Part 2. Paths are repo paths. **No files to delete. No project.yml, workflow or Info.plist change.**

## Add (36 new files)
```
ClipStudio/Engines/Audio/AudioDSP.swift
ClipStudio/Engines/Audio/AudioExtractor.swift
ClipStudio/Engines/Audio/AudioTapProcessor.swift
ClipStudio/Engines/Audio/DuckingEngine.swift
ClipStudio/Engines/Audio/LoudnessAnalyzer.swift
ClipStudio/Engines/Audio/SoundEffectsLibrary.swift
ClipStudio/Engines/Audio/VoiceoverRecorder.swift
ClipStudio/Engines/Captions/CaptionBuilder.swift
ClipStudio/Engines/Captions/SubtitleFormats.swift
ClipStudio/Engines/Captions/TranscriptStore.swift
ClipStudio/Engines/Captions/TranscriptionService.swift
ClipStudio/Engines/Export/FrameSnapshot.swift
ClipStudio/Engines/Presets/MotionPresetStore.swift
ClipStudio/Engines/Presets/ProjectTemplates.swift
ClipStudio/Engines/Presets/TextStyleLibrary.swift
ClipStudio/Engines/Rendering/WatermarkRenderer.swift
ClipStudio/Engines/Text/FontCatalog.swift
ClipStudio/Engines/Timeline/TimelineEngine+Organize.swift
ClipStudio/Features/AudioStudio/AudioStudioInspector.swift
ClipStudio/Features/AudioStudio/AudioStudioSheets.swift
ClipStudio/Features/AudioStudio/VolumeAutomationOverlay.swift
ClipStudio/Features/Captions/CaptionsSheet.swift
ClipStudio/Features/Captions/TranscriptEditorSheet.swift
ClipStudio/Features/ProStudio/StudioOrganizeViews.swift
ClipStudio/Features/ProStudio/StudioViewModel+Audio.swift
ClipStudio/Features/ProStudio/StudioViewModel+Captions.swift
ClipStudio/Features/ProStudio/StudioViewModel+Organize.swift
ClipStudio/Features/ProStudio/StudioViewModel+Text.swift
ClipStudio/Features/TextStudio/GraphicsInspector.swift
ClipStudio/Features/TextStudio/TextInspector.swift
ClipStudio/Features/TextStudio/TextLibrarySheets.swift
ClipStudio/Models/AudioEffects.swift
ClipStudio/Models/Captions.swift
ClipStudio/Models/MotionPreset.swift
ClipStudio/Models/Watermark.swift
ClipStudioTests/Part3Tests.swift
```

## Replace (26 changed code files — full new versions)
```
ClipStudio/Engines/Rendering/ClipCompositor.swift
ClipStudio/Engines/Rendering/CompositionBuilder.swift
ClipStudio/Engines/Rendering/GeneratedContentRenderer.swift
ClipStudio/Engines/Rendering/LayerRenderer.swift
ClipStudio/Engines/Rendering/NestedSequenceRenderer.swift
ClipStudio/Engines/Rendering/RenderTypes.swift
ClipStudio/Engines/Storage/BackupManager.swift
ClipStudio/Engines/Timeline/ClipKeyframes.swift
ClipStudio/Features/ProStudio/Inspector/AudioInfoInspectors.swift
ClipStudio/Features/ProStudio/Inspector/InspectorView.swift
ClipStudio/Features/ProStudio/Inspector/TransformInspector.swift
ClipStudio/Features/ProStudio/StudioHubView.swift
ClipStudio/Features/ProStudio/StudioKeyCommands.swift
ClipStudio/Features/ProStudio/StudioSheets.swift
ClipStudio/Features/ProStudio/StudioTimelineView.swift
ClipStudio/Features/ProStudio/StudioToolbar.swift
ClipStudio/Features/ProStudio/StudioView.swift
ClipStudio/Features/ProStudio/StudioViewModel+Operations.swift
ClipStudio/Features/ProStudio/StudioViewModel.swift
ClipStudio/Features/ProStudio/StudioViewer.swift
ClipStudio/Features/ProStudio/TimelineClipView.swift
ClipStudio/Features/Shared/ProjectActions.swift
ClipStudio/Models/Animation.swift
ClipStudio/Models/Content.swift
ClipStudio/Models/Project.swift
ClipStudio/Models/Timeline.swift
```

## Docs (replace)
```
README.md
docs/HANDOFF.md
docs/IMPLEMENTATION_PLAN.md
docs/FEATURE_STATUS.md
docs/PART3_CHANGES.md   (new)
```

## What changed inside the replaced files
| File | Change |
|---|---|
| Models/Timeline.swift | Track: `color`, `isSolo`, `pan` (+ `carriesAudio`); ClipAudio: `effects` with a custom decoder |
| Models/Animation.swift | ClipTransform: `stretch`, `aspectLocked` with a custom decoder |
| Models/Content.swift | TextStyle `kerning`; TextContent `loop`, `design`, `subtitle`, `accentColor`, `caption`; new text animations; LoopAnimation, TitleDesign; shapes star/arrow/heart/bubble; sticker `loop`; ScriptDirection — all with custom decoders |
| Models/Project.swift | `ProjectSettings.watermark` (+ decoder); schema 3; watermark logo counts as a referenced asset |
| Engines/Rendering/CompositionBuilder.swift | solo, Audio Studio processing taps (`audioTapPolicy`), audio parameter / meter stores, watermark resolution |
| Engines/Rendering/RenderTypes.swift, ClipCompositor.swift | `RenderInstruction.watermark`, drawn last |
| Engines/Rendering/LayerRenderer.swift | non-uniform stretch in `matrix`, blur / wipe / rotation / loop animation states for generated layers |
| Engines/Rendering/GeneratedContentRenderer.swift | title designs, caption word highlight (TextKit), kerning, new shapes, extended TextAnimator |
| Engines/Rendering/NestedSequenceRenderer.swift | no watermark inside nested renders |
| Engines/Timeline/ClipKeyframes.swift | caption word timing through split / join / retime |
| Engines/Storage/BackupManager.swift | merges motion presets, text styles, sound-effect registry and transcripts; reloads their stores |
| Features/Shared/ProjectActions.swift | `newPro(..., template:, openingTitle:)` |
| Features/ProStudio/StudioViewModel.swift | inspector tabs `.text` / `.graphic`, 11 new sheets, preview key ignores live audio effects, `showsVolumeAutomation`, taps always on in preview |
| Features/ProStudio/StudioViewModel+Operations.swift | `startBusy` no longer private (used by Part 3 extensions) |
| Features/ProStudio/StudioView / StudioToolbar / StudioSheets / StudioKeyCommands | entry points and sheet routing for every Part 3 tool |
| Features/ProStudio/StudioTimelineView.swift | track color stripe + menu, solo, close gaps, text/caption tracks, automation toggle, draggable markers |
| Features/ProStudio/TimelineClipView.swift | label / track color stripe, FX badge, volume automation overlay, long-press preview, new context items |
| Features/ProStudio/StudioViewer.swift | stretch in ClipGeometry, edge handles when the aspect lock is off |
| Features/ProStudio/StudioHubView.swift | project templates + opening title in the new-project sheet |
| Features/ProStudio/Inspector/InspectorView.swift | routes the Text and Shape tabs; project summary button |
| Features/ProStudio/Inspector/TransformInspector.swift | aspect lock / width / height, motion presets |
| Features/ProStudio/Inspector/AudioInfoInspectors.swift | the old basic `AudioInspector` moved out (replaced by Features/AudioStudio/AudioStudioInspector.swift); "select all clips of this file" |

## Data compatibility
- `EditProject.currentSchemaVersion` is now 3. Part 1 and Part 2 project files decode unchanged (every new field has a default).
- Backups from Parts 1–2 restore normally; Part 3 backups also carry motion presets, text styles, the sound-effect registry and transcripts.
