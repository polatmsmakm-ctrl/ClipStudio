# Part 4 — files to add / replace

Apply on top of Part 3. Paths are repo paths. **Nothing to delete. No change to project.yml, the workflow or Info.plist** (no new permissions: everything in Part 4 runs on device, nothing is uploaded).

## Add (23 new files)
```
ClipStudio/Models/Intelligence.swift
ClipStudio/Engines/Vision/FrameSampler.swift
ClipStudio/Engines/Vision/SubjectTracker.swift
ClipStudio/Engines/Vision/Stabilizer.swift
ClipStudio/Engines/Music/MusicAnalyzer.swift
ClipStudio/Engines/Music/BeatSync.swift
ClipStudio/Engines/Intelligence/EditingDNAEngine.swift
ClipStudio/Engines/Intelligence/ReferenceAnalyzer.swift
ClipStudio/Engines/Intelligence/QualityInspector.swift
ClipStudio/Engines/Intelligence/OutputVariants.swift
ClipStudio/Engines/Audio/SourceSeparator.swift
ClipStudio/Engines/Presets/EditingDNAStore.swift
ClipStudio/Engines/Presets/StudioTemplateLibrary.swift
ClipStudio/Features/ProStudio/StudioViewModel+Intelligence.swift
ClipStudio/Features/Intelligence/IntelligenceShared.swift
ClipStudio/Features/Intelligence/SmartToolsSheet.swift
ClipStudio/Features/Intelligence/MusicSyncSheet.swift
ClipStudio/Features/Intelligence/EditingDNASheet.swift
ClipStudio/Features/Intelligence/QualityInspectorSheet.swift
ClipStudio/Features/Intelligence/OutputVariantsSheet.swift
ClipStudio/Features/Intelligence/AudioSeparationSheet.swift
ClipStudio/Features/Templates/TemplatesWorkspaceView.swift
ClipStudioTests/Part4Tests.swift
```

## Replace (14 changed code files — full new versions)
```
ClipStudio/App/AppRouter.swift
ClipStudio/App/ContentView.swift
ClipStudio/Engines/Rendering/CompositionBuilder.swift
ClipStudio/Engines/Rendering/LayerRenderer.swift
ClipStudio/Engines/Storage/BackupManager.swift
ClipStudio/Features/Dashboard/DashboardView.swift
ClipStudio/Features/ProStudio/StudioHubView.swift
ClipStudio/Features/ProStudio/StudioSheets.swift
ClipStudio/Features/ProStudio/StudioToolbar.swift
ClipStudio/Features/ProStudio/StudioView.swift
ClipStudio/Features/ProStudio/StudioViewModel.swift
ClipStudio/Features/ProStudio/TimelineClipView.swift
ClipStudio/Features/Settings/SettingsView.swift
ClipStudio/Models/Timeline.swift
```

## Docs (replace)
```
README.md
docs/HANDOFF.md
docs/IMPLEMENTATION_PLAN.md
docs/FEATURE_STATUS.md
docs/PART4_CHANGES.md   (new)
```

## What changed inside the replaced files
| File | Change |
|---|---|
| Models/Timeline.swift | `Clip.stabilization: StabilizationSettings?` (decoded with `try?`, so Part 1–3 projects load unchanged) |
| Engines/Rendering/LayerRenderer.swift | media layers are shifted by the stabilization correction and zoomed (`stabilized(_:dx:dy:zoom:)`) before the crop |
| Engines/Rendering/CompositionBuilder.swift | `build` preloads the stabilization paths of the clips in the timeline (`StabilizationStore.preload`) |
| Engines/Storage/BackupManager.swift | merges `Presets/editing-dna.json` and copies missing `Presets/Templates/*.json`; reloads both stores |
| App/AppRouter.swift, App/ContentView.swift | routes `.templates`, `.editingStyles`, `.onDeviceAI` |
| Features/ProStudio/StudioViewModel.swift | 7 new `StudioSheet` cases: `smartTools(id)`, `music`, `editingDNA`, `quality`, `outputs`, `separation(id)`, `saveTemplate` |
| Features/ProStudio/StudioSheets.swift | routing for the new sheets |
| Features/ProStudio/StudioView.swift | "الذكاء على الجهاز" menu section, "حفظ كقالب", new iPhone action-bar buttons |
| Features/ProStudio/StudioToolbar.swift | toolbar buttons for the Part 4 tools |
| Features/ProStudio/TimelineClipView.swift | "ثابت" / "تتبع" badges; context items for smart tools and voice separation |
| Features/ProStudio/StudioHubView.swift | Templates + Editing styles tiles |
| Features/Dashboard/DashboardView.swift | Templates + Editing styles tiles |
| Features/Settings/SettingsView.swift | Templates, Editing styles, and the optional Core ML separation model |

## Data compatibility
- `EditProject.currentSchemaVersion` stays 3: the only new project field (`Clip.stabilization`) is optional.
- Analyses are caches (Caches/ClipStudio/Analysis): subject tracks, stabilization paths and music analyses are recreated on demand if the cache is cleared.
- Editing styles and templates live in `Presets/` and are part of backups. The optional Core ML model lives in Application Support/Models and is **not** included in backups (it can be large — re-import it after a restore).
