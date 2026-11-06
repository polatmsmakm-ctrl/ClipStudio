# Part 2 — files to add / replace

Apply on top of Part 1. Paths are repo paths. **No files to delete. No project.yml or workflow change.**

## Add (39 new files)
```
ClipStudio/Components/PrecisionSlider.swift
ClipStudio/Components/TimecodeField.swift
ClipStudio/Engines/Media/ReverseRenderer.swift
ClipStudio/Engines/Media/WaveformService.swift
ClipStudio/Engines/Presets/ColorPresetStore.swift
ClipStudio/Engines/Presets/LUTLibrary.swift
ClipStudio/Engines/Presets/StudioPreferences.swift
ClipStudio/Engines/Rendering/ColorMatcher.swift
ClipStudio/Engines/Rendering/FramePreviewRenderer.swift
ClipStudio/Engines/Rendering/NestedSequenceRenderer.swift
ClipStudio/Engines/Timeline/ClipKeyframes.swift
ClipStudio/Engines/Timeline/Snapping.swift
ClipStudio/Engines/Timeline/StudioClipboard.swift
ClipStudio/Engines/Timeline/TimelineEngine.swift
ClipStudio/Engines/Timeline/UndoStack.swift
ClipStudio/Features/Color/ColorControls.swift
ClipStudio/Features/Color/ColorLibraryPanels.swift
ClipStudio/Features/Color/ColorWorkspaceView.swift
ClipStudio/Features/ProStudio/Inspector/AudioInfoInspectors.swift
ClipStudio/Features/ProStudio/Inspector/CropMaskChromaInspectors.swift
ClipStudio/Features/ProStudio/Inspector/EffectsInspector.swift
ClipStudio/Features/ProStudio/Inspector/InspectorView.swift
ClipStudio/Features/ProStudio/Inspector/KeyframeEditorView.swift
ClipStudio/Features/ProStudio/Inspector/SpeedInspector.swift
ClipStudio/Features/ProStudio/Inspector/TransformInspector.swift
ClipStudio/Features/ProStudio/StudioHubView.swift
ClipStudio/Features/ProStudio/StudioKeyCommands.swift
ClipStudio/Features/ProStudio/StudioMediaPanel.swift
ClipStudio/Features/ProStudio/StudioSheets.swift
ClipStudio/Features/ProStudio/StudioTimelineView.swift
ClipStudio/Features/ProStudio/StudioToolbar.swift
ClipStudio/Features/ProStudio/StudioView.swift
ClipStudio/Features/ProStudio/StudioViewModel+Editing.swift
ClipStudio/Features/ProStudio/StudioViewModel+Gestures.swift
ClipStudio/Features/ProStudio/StudioViewModel+Operations.swift
ClipStudio/Features/ProStudio/StudioViewModel.swift
ClipStudio/Features/ProStudio/StudioViewer.swift
ClipStudio/Features/ProStudio/TimelineClipView.swift
ClipStudioTests/StudioEngineTests.swift
```

## Replace (9 changed code files — full new versions)
```
ClipStudio/App/AppEnvironment.swift
ClipStudio/App/AppRouter.swift
ClipStudio/App/ContentView.swift
ClipStudio/Engines/Rendering/CompositionBuilder.swift
ClipStudio/Engines/Storage/BackupManager.swift
ClipStudio/Features/Dashboard/DashboardView.swift
ClipStudio/Features/Settings/SettingsView.swift
ClipStudio/Features/Shared/ProjectActions.swift
ClipStudio/Models/Project.swift
```

## Docs (replace)
```
README.md
docs/HANDOFF.md
docs/IMPLEMENTATION_PLAN.md
docs/FEATURE_STATUS.md
docs/PART2_CHANGES.md   (new)
```

## Data compatibility
- `EditProject.currentSchemaVersion` is now 2. Part 1 project files decode unchanged (new fields default: no nested sequences, default studio state).
- Backups made with Part 1 restore normally; Part 2 backups also carry saved looks, the LUT index and the reversed-render registry.
