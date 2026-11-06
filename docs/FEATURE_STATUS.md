# CLIPSTUDIO — Feature Status

Status after **Part 6 (all six parts written)**. Legend:
- **Code written** — complete implementation authored; *not yet compiled or tested on device* (the implementation agent does that).
- **Engine only** — processing code exists and is used internally; user-facing editing UI arrives in the listed part.
- **Pending** — not written yet (planned part shown).

Nothing below is marked "completed": per the spec, a feature is complete only after it has been built and tested.

## Foundation (Part 1)
| Feature | Status |
|---|---|
| XcodeGen project, GitHub Actions unsigned IPA + Release, optional signed IPA, unit-test job | Code written |
| App icon generator (runs in CI if no icon is provided) | Code written |
| Arabic RTL UI, English digits, dark theme, studio-gold accent, animated background (replaced by `AppBackground` image if added) | Code written |
| iPhone tabs / iPad sidebar adaptive layout | Code written |
| Home Screen + Lock Screen widget (export progress, recent projects) | Code written — needs App Group at signing time (optional) |
| Keyboard "تم" bar, haptics, empty states, search, toasts | Code written |
| Backup & restore (.csbackup, streaming, merge-restore) — Part 2 adds LUT index, color looks and reversed-render registry; Part 3 adds motion presets, text styles, sound-effect registry and transcripts; Part 4 adds editing styles and templates | Code written |

## Media & projects (Part 1)
| Feature | Status |
|---|---|
| Import from Photos / Files (security-scoped, streamed copy), duplicate detection | Code written |
| Library: thumbnails, metadata, search, filters, sorting, rename, delete (with usage warning), relink | Code written |
| Storage management (sizes, cache cleanup, unused media) | Code written |
| Projects: autosave, version snapshots, restore, duplicate, rename, delete, crash recovery | Code written |

## Smart Stories, Merge, Batch, Export (Part 1)
| Feature | Status |
|---|---|
| Splitter (max / fixed / equal / custom), platform presets, scene / pause / keyframe snapping, manual cuts, gallery, export all | Code written + unit tests |
| Merge: order, trim, 22 transitions, music, audio crossfade, res/fps matching, aspect conversion, live preview | Code written |
| Batch: split / convert / resize / compress / merge, pause/resume, cancel, retry, recovery | Code written |
| Export: MP4/MOV, H.264/HEVC, 720p–4K, 24–60 fps, quality/bitrate, queue, history, stream copy | Code written |

## Pro Studio — timeline (Part 2)
| Feature | Status |
|---|---|
| Full-screen editor; iPad resizable multi-panel workspace (inspector · viewer/timeline · media), iPhone sheets | Code written |
| Layout presets (editing / viewer focus / timeline focus / minimal) + save custom layout | Code written |
| Unlimited video / overlay / audio / adjustment tracks; reorder layers; lock / hide / mute; track volume; rename | Code written |
| Center-playhead timeline: scrub with momentum, vertical track scroll, pinch zoom, zoom to fit, adaptive ruler | Code written |
| Move clips in time and between tracks (ghost preview), snapping to edges / playhead / markers / in-out | Code written + unit tests |
| Trim handles (source-limited extension), blade tool, split at playhead, join (un-split) | Code written + unit tests |
| Delete, ripple delete, duplicate, replace, nudge by frames, enable/disable, label colors | Code written + unit tests |
| Magnetic primary storyline (no gaps, transitions overlap) — can be turned off | Code written + unit tests |
| Insert / overwrite / append placement, drag & drop from media panel onto any track | Code written + unit tests |
| Multi-select, select all, select forward, clipboard (copy / cut / paste), copy & paste attributes by category | Code written |
| Markers (add, rename, color, delete, jump), in/out points, loop in/out playback | Code written |
| Undo / redo (150 steps, gestures coalesced into one step) | Code written + unit tests |
| Filmstrips (only visible part drawn) and audio waveforms (cached peaks) | Code written |
| Timecode display and "go to timecode" (HH:MM:SS:FF, seconds, ±relative, Arabic digits) | Code written + unit tests |
| J/K/L shuttle (forward up to 8×, reverse by stepping when needed), frame step, edit-point navigation | Code written |
| Hardware keyboard shortcuts (⌘Z/⇧⌘Z/⌘C/⌘X/⌘V/⌘D/⌘A/⌘B/⌘G/⌘E + single keys) and shortcuts sheet | Code written |
| Apple Pencil: configurable double-tap (blade / play / undo), hover scrubbing | Code written |
| Instant preview refresh for attribute edits (no rebuild), debounced rebuild for timing edits | Code written |

## Pro Studio — editing (Part 2)
| Feature | Status |
|---|---|
| On-canvas transform: drag, pinch, rotate (two fingers or handle), corner scale, center snapping | Code written |
| Transform inspector: position / scale / rotation / opacity / anchor / flips, fit modes, PiP presets, blend modes | Code written |
| Keyframes on position, scale, rotation, opacity, crop, volume and effect intensity; keyframe editor (retime, easing, delete) | Code written + unit tests |
| Visual crop editor with aspect presets and animated reframing | Code written |
| Masks (rectangle / ellipse / linear) with visual editor, feather, invert | Code written |
| Chroma key with eyedropper, tolerance / softness / spill, checkerboard preview | Code written |
| Speed: presets, 0.1×–8× slider, pitch preservation, speed-ramp curve editor + ramp presets | Code written + unit tests |
| Reverse playback (renders a reversed copy with reversed audio, once per source, with progress & cancel) | Code written |
| Freeze frames | Code written + unit tests |
| Detach audio to its own track | Code written |
| Effects stack (14 effects) with live thumbnails, reorder, enable, keyframable intensity | Code written |
| Transitions browser (22) with live animated preview, duration, apply to all cuts | Code written + unit tests |
| Adjustment layers and solid-color layers | Code written |
| Nested sequences: create from selection, open/edit, re-render on exit (re-points every instance), break apart | Code written |
| Basic clip audio (mute, keyframable volume, fades) — extended by the Audio Studio (Part 3) | Code written |

## Color (Part 2)
| Feature | Status |
|---|---|
| Color workspace with live GPU preview of the clip's real frame (or the composite under an adjustment layer) | Code written |
| Before / after: split with draggable divider, side by side, after only | Code written |
| RGB + luma histogram | Code written |
| Basic sliders (exposure … hue), 5-point tone curve, lift / gamma / gain wheels | Code written |
| LUT import (.cube, 3D), LUT library (Settings), intensity, live thumbnails | Code written |
| Looks: 12 built-in + save / delete your own | Code written |
| Shot matching against another clip (exposure, contrast, saturation, balance) with strength | Code written |
| Multi-clip color apply, copy / paste grade | Code written |

## Studio additions (Part 3 — the 10 suggestions)
| Feature | Status |
|---|---|
| Drag markers on the ruler (frame-snapped, live timecode, one undo step) | Code written |
| Track colors (header stripe, clip stripe, mixer, summary) | Code written |
| Select all clips that use the same file | Code written + unit tests |
| Project templates: blank, Reels/TikTok 9:16, YouTube 16:9, square, 4:5, podcast, slideshow (crossfades + gentle motion), optional opening title | Code written + unit tests |
| Full-resolution frame snapshot → Photos + Exports (PNG) | Code written |
| Motion presets: 13 built-in (Ken Burns, pans, fades, pop, spin, slide in/out, handheld) + save your own; apply to many clips | Code written + unit tests |
| Close gaps (selected track / all tracks, from the summary or the track menu) | Code written + unit tests |
| Long-press clip preview (looping muted video, still, rendered text/graphic, audio details) | Code written |
| Aspect lock off → edge handles stretch width/height; width/height sliders; reset | Code written |
| Project summary (totals, content types, per-track clips/coverage/transitions/gaps) | Code written |

## Audio Studio (Part 3)
| Feature | Status |
|---|---|
| Real-time processing per clip (MTAudioProcessingTap, preview and export): gain −24…+24 dB, balance, high-pass, 5-band parametric EQ, adaptive spectral noise reduction, voice enhancement, compressor, −1 dBFS limiter | Code written + unit tests (filter math) |
| Live parameter updates while playing (no preview rebuild) | Code written |
| EQ response graph with draggable bands; audio presets (clear voice, podcast, noise cleanup, background music, telephone, warm) | Code written |
| Mixer: per-track live meters, volume, balance, mute, solo; audio-only export (M4A) with share | Code written |
| Volume automation drawn on the timeline (add / drag / delete points) | Code written |
| Automatic ducking of music under speech (waveform-based, editable keyframes) | Code written + unit tests |
| Loudness normalization (ITU-R BS.1770-4 integrated LUFS: −14 / −16 / −23) | Code written + unit tests |
| Audio extraction of a clip to a new library file (AAC) | Code written |
| Voiceover recording (count-in, level meter, timeline playback muted or not, placed at the start position) | Code written |
| Sound-effects library (18 effects synthesized on device, preview, imported once) | Code written |

## Text, titles & graphics (Part 3)
| Feature | Status |
|---|---|
| Text inspector: text, second line, any installed font (Arabic fonts first), weight, size, color, alignment, letter & line spacing, width, outline, shadow/glow, background box | Code written |
| Title designs: plain, lower third (RTL-aware), frame, underline, banner, quote; 11 ready title templates filled with your text | Code written |
| Animations: 10 entrance/exit (fade, slide, pop, zoom, typewriter, blur, wipe, bounce, spin) + 6 loops (pulse, float, shake, swing, blink, rotate) | Code written |
| Text styles: 8 built-in + save your own | Code written |
| Shapes (9 incl. star, arrow, heart, speech bubble), emoji and SF-symbol stickers with loops, image/logo overlays | Code written |
| Project watermark (text or logo, corner, size, opacity) in preview and every export | Code written |

## Captions & transcription (Part 3)
| Feature | Status |
|---|---|
| Speech-to-text (Arabic dialect locales, English and more), on-device when supported; Apple servers only after explicit consent; chunked, cached per file + language, cancellable with real progress | Code written + unit tests (coverage) |
| Automatic captions: words mapped through trims/speed, grouping by characters/lines/duration/pauses/sentences, balanced line breaks | Code written + unit tests |
| Caption looks with per-word highlight (color, karaoke, moving box, word-by-word, reveal) — 8 presets | Code written |
| Caption editor: text, split before a word, merge, delete, sync offset, restyle all, highlight color | Code written |
| SRT / WebVTT import and export | Code written + unit tests |
| Text-based editing foundation: delete words, filler words and long pauses from the transcript → all tracks cut in sync (markers follow) | Code written + unit tests (engine) |

## Smart reframe, tracking & stabilization (Part 4)
| Feature | Status |
|---|---|
| Smart reframe: faces → people → most salient object (or one of them), Vision on device, smooth virtual camera (adjustable smoothing + zoom), written as editable crop keyframes | Code written + unit tests (crop math) |
| Object tracking: draw a box on the first frame → `VNTrackObjectRequest` frame by frame; reframe on it; "lost" position held and reported | Code written |
| Titles / stickers / shapes follow a tracked subject (position keyframes keep the current offset) | Code written |
| Video stabilization: camera path analyzed once per file (translational registration), strength and zoom adjustable instantly, suggested zoom, enable / remove; badge on the timeline | Code written + unit tests (corrections, interpolation) |

## Music intelligence & beat sync (Part 4)
| Feature | Status |
|---|---|
| Music analysis on device: tempo (60–200 BPM), beats (dynamic programming), downbeats, energy curve, sections, the drop; cached per file | Code written + unit tests (synthetic click tracks) |
| Energy / beat / section view with jump to the drop | Code written |
| Cut to the beat: every 1 / 2 / 4 / 8 beats or nearest beat, downbeats only, source-length aware | Code written + unit tests |
| Beat-centred transitions (every 1 / 2 / 4 cuts, any transition, duration) | Code written + unit tests |
| Beat markers (downbeats or every beat + drop) that clips snap to; remove all | Code written + unit tests |

## Editing DNA, reference editing & templates (Part 4)
| Feature | Status |
|---|---|
| 4 built-in styles (fast reels, calm cinematic, documentary, daily vlog) | Code written |
| Learn the style of the current project (shot rhythm & spread, transitions, cuts on beat, look / LUT, caption & title styles, still motion, music level, aspect) | Code written + unit tests |
| Learn from a reference video (Files or library, analyzed locally, never imported): scene cuts → rhythm, fades / flashes, representative frame for color matching, tempo + cuts on beat, on-screen text → caption / title style | Code written |
| Apply a style with options (pacing, transitions, color with strength, text, still motion, music) as one undo step; beat-synced pacing when the music is analyzed | Code written + unit tests |
| Style library: duplicate, rename, delete (hub, Settings and editor) | Code written |
| Save any project as a template (picture clips → numbered slots, keep or drop the music) | Code written + unit tests |
| Templates workspace: fill slots one by one or several in order → new project (short videos slowed to keep the rhythm, empty slots removed, missing music dropped) | Code written + unit tests |

## Audio separation (Part 4)
| Feature | Status |
|---|---|
| Voice / background stems: stereo centre extraction (in-phase coherence, speech band), voice-vs-noise for mono, automatic choice; stems on new tracks, original muted not deleted; voice + background = original | Code written + unit tests |
| Optional Core ML mask model (import .mlmodel / .mlpackage in Settings, compiled and shape-validated on device) | Code written |

## Quality Inspector (Part 4)
| Feature | Status |
|---|---|
| Instant checks: missing media, black gaps, flash frames, low resolution, frame-rate mismatch, text outside the title-safe area, tiny text, caption reading speed and overlaps, hidden / muted tracks, disabled clips, risky gain without limiter, broken watermark | Code written + unit tests |
| Deep scan: real loudness (BS.1770) and peaks per clip, exposure per picture clip | Code written |
| One-tap fixes (close gap with all tracks in sync, delete flash frame, move into safe area, enlarge text, show / unmute track, enable clip / limiter, normalize, exposure fix, replace media, watermark) and jump-to | Code written + unit tests |

## Multiple content outputs (Part 4)
| Feature | Status |
|---|---|
| 9:16 / 16:9 / 1:1 / 4:5 variants as new projects (original untouched) | Code written + unit tests |
| Full-frame shots: smart subject-following crop, centred crop or whole picture over blur; PiP layers keep their placement | Code written + unit tests |
| Titles / stickers resized for the new shape and kept in the safe area; captions re-wrapped | Code written + unit tests |
| Optional "export all" into the export queue with chosen settings | Code written |

## Part 4 suggestions (delivered with Part 5)
| Feature | Status |
|---|---|
| Privacy blur: detect faces (Vision, cached per file), choose faces, blur / pixelate / black box that follows each face (tracked ellipse mask on a silent overlay copy) | Code written + unit tests |
| Subject masks: mask that follows a tracked subject (center / size keyframes), spotlight (darken everything else), remove | Code written + unit tests |
| Horizon leveling: `VNDetectHorizonRequest` at 4 fps, smoothed, render-time rotation with cover zoom; strength / smoothing editable | Code written + unit tests |
| Music ending fit: end on a bar with fade, keep the song's real ending (cut the start on a bar), or loop whole bars to the end of the picture | Code written + unit tests |
| Auto edit to the beat: photos + videos + song + style → full timeline, every cut on a beat, short videos slowed, music fades at the last cut | Code written + unit tests |
| Batch color match: match every shot to one reference frame (one undo step) | Code written |
| Duck under a chosen voice track (plus extra targets) | Code written |
| Before / after compare (drag divider, rendered with the real renderer) | Code written |
| Export quality check before export (optional, can be turned off in studio preferences) | Code written |
| Share styles / templates as `.csstyle` / `.cstemplate` files; import assigns new IDs | Code written + unit tests |

## AI layer (Part 5)
| Feature | Status |
|---|---|
| Provider architecture: `AIProvider` protocol, `GeminiProvider`, `LocalAIProvider`, `AIRequestRouter` (provider choice, daily limit, 429 cool-down, cache, streaming, on-device fallback with a note) | Code written + unit tests |
| Gemini over REST with URLSession: `x-goog-api-key` header, structured JSON output (`responseSchema`), SSE streaming, Files API resumable upload + ACTIVE polling, function calling | Code written + unit tests (request / response / errors) |
| Key in the Keychain (this device only); optional default key from the `GEMINI_API_KEY` secret at build time; masked display, test connection, remove | Code written |
| Model picker filled from `GET /v1beta/models` (generateContent only), newest stable "flash" chosen automatically | Code written + unit tests |
| Arabic errors: no key, offline, timeout, 429 (with wait time), daily quota, 403 / invalid key, 404 model, blocked by safety | Code written + unit tests |
| Consent before any media upload (what is sent, size); "on device instead" button; text-only requests show a note | Code written |
| Usage screen (requests / tokens per day, last 7 days), daily limit, response cache (7 days) with size + clear | Code written |
| AI Storyboard: idea + duration + tone + library media → editable scenes (purpose, shot, on-screen text, voice-over) → new project with shots, titles and scene markers | Code written + unit tests |
| Smart Highlights: on-device scene cuts + loudness + speech, Gemini on frames (or a compressed copy with "whole video"), review, one reel or one project per moment | Code written + unit tests |
| Content Studio: titles, captions, hashtags, hook and thumbnail text per platform within platform limits; editable, saved with the project, copy / share | Code written + unit tests |
| AI Editing Assistant: chat with streaming, the timeline sent as text only, 17 editing functions → validated, editable plan; destructive steps flagged; preview (keep / undo) or apply as one undo step | Code written + unit tests |
| On-device assistant: Arabic / English command parser for the same functions (works offline) | Code written + unit tests |
| AI help for text-based editing: fillers, repetitions, stumbles, off-topic parts and long pauses suggested; only marked in the transcript editor (deletion still needs the user) | Code written + unit tests |
| AI enrichment of reference editing: Gemini reviews frames of the reference and refines the learned style (pace, transitions, look, text) | Code written |

## Part 5 suggestions (delivered with Part 6)
| Feature | Status |
|---|---|
| Generated voiceover from text: Apple device voices offline (AVSpeechSynthesizer → file) or Gemini TTS voices (text only sent); preview, then place on a voiceover track at the playhead | Code written + unit tests (chunks, WAV, TTS wire format) |
| Storyboard: optional generated voiceover for every scene's voice-over line, placed on a "تعليق صوتي" track at the scene start | Code written |
| Caption translation into 14 languages: Gemini in numbered batches (count verified, one retry) or Apple Translation on device (iOS 18+); review / fix lines; new captions track with same timing and style, original hidden not deleted | Code written + unit tests |
| Voice commands for the assistant: live on-device dictation (server only after consent), level meter, auto-stop after a pause, optional auto-send | Code written |
| Assistant memory: learns transitions, title placement, speeds, color moves, silence / beat / ducking choices from applied plans + user notes; summary sent with requests; preferred transition used by the on-device parser and validator; view / forget / clear | Code written + unit tests |
| Music suggestions from the library: mood (chosen, from project name or editing pace) → tempo / energy target; on-device analysis cached per file; ranked with reasons; listen; add with ending fitted to the picture | Code written + unit tests |
| Automatic thumbnail: 18 composite frames scored on device (sharpness, exposure, colorfulness, contrast, face quality); pick, write text (from Content Studio), position / color / size / darkening; JPEG to Photos + Files or share | Code written + unit tests (scoring) |
| Pre-publish hook check: on-device measurements (first text, first word, early cuts, black opening, music) + Gemini on 6 frames of the first 3 s; score, strengths, problems, suggestions with one-tap fixes (title at start, cut slow start) | Code written + unit tests |
| Assistant plan history per project (last 50): search, review steps, apply again, delete, clear | Code written + unit tests (Codable plans) |
| Smart shortening to a target length: sentences from the transcript; Gemini (text + times) or on-device importance scoring; toggle sentences, live resulting length; one-step cut on every track | Code written + unit tests |
| Episode series: several videos → one project per episode with intro card (name + "الحلقة N"), optional outro, shared song (fitted / looped on bars), same style; optional export of all | Code written + unit tests |

## Part 6 — performance, proxies, accessibility
| Feature | Status |
|---|---|
| Proxy media: 540p / 720p H.264 copies of heavy videos (4K, > 25 Mb/s, > 60 fps, ProRes) made one at a time, automatically after import (switchable) or on demand; used only by the Studio preview; exports / snapshots / analyses / AI use originals; tied to the original's fingerprint; delete one / all; storage shown | Code written + unit tests (policy) |
| Preview rebuilds automatically when a proxy becomes ready | Code written |
| Performance monitor: thermal state, Low Power Mode, memory warnings (cache purge), memory footprint / available memory sampling | Code written |
| Adaptive preview: capped to 540p (serious heat / Low Power) or 360p (critical heat); banner in the Studio; proxy generation pauses while hot; can be switched off | Code written + unit tests (cap policy) |
| Animated background stops in Low Power Mode / heat (and with Reduce Motion, as before) | Code written |
| Accessibility: VoiceOver value for timeline clips (kind, times, speed, state) and actions (select, play from here, split, nudge ±1 s, delete); adjustable playhead (±1 s per swipe); toasts spoken; larger trim handles option; labels on new controls | Code written + unit tests (descriptions) |
| Settings → «الأداء والنسخ الخفيفة وتسهيلات الاستخدام»: proxies, heavy-video list, adaptive preview, device status, memory, accessibility options | Code written |

## Pending
Nothing is left unwritten in the six-part plan. Every feature still needs to be **built and tested on device** by the implementation agent (see `docs/HANDOFF.md`). Items are marked "Code written", never "completed".

## Known limitations (by design / platform)
- iOS does not allow GPU rendering in the background: re-encode jobs pause when the app leaves the foreground and resume on return.
- Speed ramps are approximated with 12 constant-speed steps (AVFoundation scales time ranges linearly). Ramped clips cannot be lengthened by trimming (shortening works).
- Reverse shuttle (J) uses fast frame stepping when the composition cannot play backwards natively.
- Nested sequences are rendered to a high-quality HEVC file; edits inside them appear in the main timeline after leaving the sequence (re-render with progress).
- Boosting above 100 % uses the Audio Studio gain (dB) — the volume slider itself stays 0–100 % (AVAudioMix limit).
- Balance acts on stereo sources; mono sources stay centered (the processing tap receives the source channel layout).
- Noise reduction adds about 16 ms of latency to that clip (STFT); it learns the noise floor during the first second of each clip.
- Speech recognition on device depends on the language and iOS version; when unavailable the user must allow Apple's servers (never automatic). Reversed clips are not transcribed.
- Caption word timing comes from the recognizer; captions imported from SRT get estimated (even) word timing.
- Ducking reads cached waveform peaks (50 per second) — very quiet speech may need a lower sensitivity threshold.
- Platform upload limits change; presets are starting values and are fully editable.
- Smart reframe analyzes 8 frames per second and smooths between them; very fast subjects may lag slightly at low smoothing values (raise the zoom less, or use object tracking).
- Object tracking starts on the clip's first source frame; if the object leaves the frame the last position is held (reported with the time).
- Stabilization corrects translation (pan / tilt shake), not rotation or rolling shutter; the zoom hides moving borders. It is not available on clips with a speed curve.
- Beat detection is tuned for music with a clear pulse; rubato / ambient music may give no beats (reported).
- Stereo centre extraction separates what is centred (usually voice / lead vocals) from what is wide; centred instruments (kick, bass above 120 Hz) may stay in the voice stem. Mono files can only be separated from steady noise. The optional Core ML model gives better results.
- Reference-video style learning measures rhythm, light / color, tempo and text presence — it does not copy footage, fonts or music.
- Proxies are made with `AVAssetExportSession` presets (960×540 / 1280×720, H.264). HDR / 10-bit footage looks SDR in the proxy preview only; exports keep the original's quality.
- Proxy generation runs while the app is open (iOS suspends it in the background); it continues when the app returns.
- Apple Translation (on-device) needs iOS 18 and may ask to download the language pair the first time; on iOS 17 translation needs a Gemini key.
- Device voices depend on the voices installed on the device (Settings › Accessibility › Spoken Content › Voices); Arabic enhanced voices sound much better than the default.
- Gemini TTS models are preview models on Google's side and may be renamed; the app picks the newest TTS model from the model list.
- Voice commands use on-device recognition when the language supports it; otherwise the user is asked before audio goes to Apple.
- The hook check measures loudness only through Gemini's frames / the transcript (the on-device check does not read audio levels); fixes are limited to a title at the start and cutting a slow start.
- Smart shortening needs transcribed speech (Speech, on device); videos without speech can't be shortened by importance.
- Thumbnail scoring is heuristic (no aesthetic model); the user always chooses the frame.
- Accessibility: most timeline editing is gesture-based; VoiceOver users get custom actions on clips and an adjustable playhead, but precise trimming still needs the inspector's numeric fields.
