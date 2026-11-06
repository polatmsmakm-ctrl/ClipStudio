# START HERE — instructions for the AI applying this code

This archive is the complete ClipStudio source (Parts 1–6): an Arabic (RTL) AI video editor for iPhone / iPad.
It has **never been compiled**. Your job is to put it in a GitHub repository, get it to build on GitHub Actions,
and produce an unsigned IPA (installed with Sideloadly).

## Read first
1. `docs/HANDOFF.md` has the full setup:
   - repository layout and secrets;
   - targets and file tree;
   - architecture notes;
   - the APIs most likely to need compile fixes (§7);
   - the QA checklist.
2. `docs/FEATURE_STATUS.md` says what every feature does and its known limitations.
3. `README.md` is the user's guide, in Arabic.

## Setup in short
- `github-workflows/build.yml` → move to **`.github/workflows/build.yml`**.
- `gitignore.txt` → rename to **`.gitignore`**.
- Everything else keeps its path.
- Stack: XcodeGen (`project.yml`; CI runs `xcodegen generate`; never commit an `.xcodeproj`), Swift 5 language mode, iOS 17 minimum, SwiftUI + `@Observable`, no third-party packages.
- Optional secret `GEMINI_API_KEY`. The workflow writes it into `ClipStudio/Generated/BuildSecrets.swift` at build time. The committed file must keep an **empty** key.

## Rules
- Fix compile errors **in place**: exact types, imports, `#available`, actor isolation.
- **Do not** remove, stub or simplify features to make the build pass.
- **Do not** change the architecture or the requirements.
- Never put API keys in the repository.
- Never fake progress. Never modify or delete the user's original media. Never overwrite existing files.
- UI text stays Arabic with English digits (format numbers with `Fmt`).
- After a green build, run the `ClipStudioTests` target. Then update `docs/FEATURE_STATUS.md` with what was actually verified.
