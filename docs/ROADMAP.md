# VideoNotes: Build Roadmap

Phased so that something real works at the end of every phase. The deterministic engine is built and tested before any AI spend, so the hardest, most differentiating part (correct keyframe selection) is proven first. Everything is one universal SwiftUI codebase over a shared `VideoNotesEngine` Swift package, styled by the Holographic Study HUD (`DESIGN.md`).

Each phase lists its goal, the work, and a concrete "done when" acceptance bar.

---

## Phase 0: Scaffold, shell, and design system

**Goal:** a universal app that boots on macOS and iOS/iPadOS with the HUD design language in place.

- XcodeGen `project.yml` with `VideoNotes-macOS` and `VideoNotes-iOS` targets over the local `VideoNotesEngine` package (mirror Alembic's setup).
- The `DESIGN.md` foundation: `GlassPanel` material (Liquid Glass with the `macOS 14 / iOS 17` fallback), the HUD/study two-surface theming, tokens, the reticle `Canvas`, and the arc-reactor boot animation. New app icon/mark from `assets/logo.svg`.
- `@Observable` view models and the screen shell (Home, Import, Analyze, Review, Study, Export, Settings) as `NavigationSplitView` (Mac/iPad) / stack (iPhone) routes.
- `DocumentGroup` over the `.videonotes` package `UTType`; open/save round-trips an empty StudySet.

**Done when:** both targets build and launch, the boot animation and glass chrome render, you can navigate the shell on Mac and in the iOS simulator, and an empty XCTest suite is green.

## Phase 1: Deterministic engine and the Scan (the differentiator)

**Goal:** correct, tested keyframe selection with no AI at all, shown as the signature Scan.

- `Engine/Video` (AVFoundation two-rate sampling, adaptive per content type), `Engine/Hash`, `Engine/Scoring` (sharpness, ink-density, stability, occlusion via Vision person segmentation, legibility, on vImage/Core Image, deterministic path), `Engine/Select` (the completeness picker), `Engine/Dedup`.
- `Engine/Pipeline` orchestration with an `AsyncStream` progress feed + checkpoint journal.
- The **Analyze / Scan** UI: live filmstrip, scan line, telemetry, rejected-frame fall-away, and kept keyframes flying into the outline lattice (`matchedGeometryEffect`), all driven by real engine events.
- Fixture suite + the flagship tests (fills-then-erases ▶ finished frame; slide-shown-twice ▶ one card) and the deterministic **evaluation harness** (`EVALUATION.md`): selection F1, completeness accuracy, and dedup, running in CI as a release gate.

**Done when:** importing a real lecture yields a correct, de-duplicated, ordered keyframe set you can eyeball as right, the sensitivity dial re-picks instantly, the Scan animation reads well, and the engine test suite is green. No network used.

## Phase 2: Understanding, notes, and cost/trust controls

**Goal:** each keyframe becomes grounded, faithful notes, on-device first and cost-safe.

- On-device `Engine/Understand` first (Vision OCR) and `Engine/Transcribe` (whisper.cpp or Speech) + alignment, overlapping transcription with scanning. Fully offline path works here.
- `Engine/AI` provider layer (URLSession clients, capability routing, Keychain, actor-bounded concurrency + retry) with the optimizations: downscaled keyframes, skip-VLM-on-text-only, batching, tiered routing.
- VLM structure understanding + note generation (structured, density, faithfulness post-check), cached by content hash. Model contracts per `PROMPTS.md` (schemas, grounding, prompt-injection defences from `SECURITY.md`); the model-eval faithfulness judge panel.
- Multi-input fusion: attach a slide deck (PDF/PPTX) and/or transcript, aligning keyframes to slides for exact text and vectors (`ENGINE.md` §13).
- Cost and trust: pre-run estimate, live meter, hard budget cap, and the privacy dashboard with PII-redaction preview.

**Done when:** a scanned lecture produces faithful notes per card in the chosen language; the no-key on-device path and the cloud path both work; the budget cap stops spend and degrades gracefully; re-running does not re-spend.

## Phase 3: Sketch engine (original illustrations)

**Goal:** every card gets an original, accurate illustration.

- `Engine/Sketch`: StyleToken + Core Graphics stroke-perturbation finish; vector renderers for graph/flowchart/tree/cycle, chart, table, timeline; SwiftMath formulas; golden PDF/SVG tests. Self-drawing render animation in the app.
- Generative mode via `Engine/AI` image generation (provider, or optional on-device Core ML `ml-stable-diffusion`), with label-overlay-as-vector and the auto-verification pass.
- Mode selection wired to `visualKind`; per-card mode switch.

**Done when:** structured visuals render as crisp, correct, consistently-styled vector sketches; pictorial concepts get verified original line art; the whole set shares one coherent style; sketch tests green.

## Phase 4: Review, edit, and tutor workspace

**Goal:** the learner can shape and interrogate the Study Set.

- Review/Edit: outline + filmstrip rail, editable `NoteCardView`s, per-card inspector. Scrub-to-source mini-player and keyframe timeline.
- Editing power-ups: keyboard-first review (macOS), explicit undo/redo, PencilKit annotation (iPad), direct vector-diagram node/label editing, compare-to-source toggle.
- Inline tutor actions (explain more, simplify, example, make a question, why it matters) and read-aloud (TTS).
- Bulk: re-select at new sensitivity, regenerate at new density, restyle all, translate all. `userEdited` protection.

**Done when:** every edit and tutor action works and is non-destructive, undo/redo covers everything, scrub-to-source and Pencil work, and a full session feels fluid on Mac and iPad.

## Phase 5: Study, library, and search

**Goal:** the notes get used, and the app becomes a place.

- **Study mode**: flashcards + quizzes generated from notes, scheduled with **FSRS** spaced repetition, per-card mastery, a persistent review queue.
- **Home / Library**: recent and pinned study sets, quick New; full-text search across a set and the library.
- Background processing with a completion notification; onboarding with a bundled sample lecture (no key required).

**Done when:** a finished set drives a real spaced-repetition review session, the library and search work, a long run completes in the background and notifies, and first-run shows a finished sample in under a minute.

## Phase 6: Export everything

**Goal:** the Study Set leaves the app in any format, natively.

- Shared study layout (SwiftUI view + Core Graphics path) and themes.
- Core exporters: PDF (`ImageRenderer`/PDFKit), HTML, Markdown, RTF (`NSAttributedString`).
- OOXML/zip exporters via ZIPFoundation: DOCX, PPTX, EPUB; Anki `.apkg` via GRDB + ZIPFoundation; plus LaTeX, JSON, TXT; pandoc-gated ODT on macOS; Notion (paste or push).
- Native delivery: save panel on macOS, `ShareLink`/share sheet on iOS/iPadOS; batch export; Pencil annotations included; golden-file tests per format.

**Done when:** every core format opens cleanly in its native app with intact math and vector art, Anki decks import and review correctly, batch export works on both platforms, and export tests are green.

## Phase 7: Polish, package, ship

**Goal:** a shippable universal build.

- Accessibility pass: Reduce Motion / Reduce Transparency / Increase Contrast paths, Focus (calm) mode, VoiceOver progress, Dynamic Type, auto alt-text everywhere.
- `.videonotes` package read/write hardening, resume-after-crash verified, iOS long-video chunking/thermal handling, ambient-motion power/thermal gating.
- Robustness pass across the `ENGINE.md` §14 matrix (every pathology has a fixture and defined behaviour); a security review against `SECURITY.md` (injection, egress, key handling); iCloud sync with conflict resolution.
- Performance pass to hit the 60-min-in-under-3-min target on Mac and iPad; 2-hour input soak test; 120fps HUD on ProMotion.
- `README`, `PRIVACY`, `SUPPORT`; macOS notarised DMG (unsigned first); iOS/iPadOS TestFlight build.

**Done when:** a clean 60-minute lecture goes end to end (scan ▶ notes ▶ study ▶ printed PDF + Anki deck) on Mac and iPad, offline mode sends nothing, motion/accessibility toggles all behave, the DMG installs on a fresh Apple-silicon Mac, and the iOS build runs from TestFlight.

---

## Later tracks (post-v1)

- **Course mode**: group many lectures into one revision workspace with a combined glossary and cross-lecture flashcards.
- **Processing queue**: drop several lectures and process in sequence.
- **Code-lecture handling**: language-aware OCR, syntax highlight, scrolling-code stitching.
- **Cross-segment slide-evolution merge**; speaker diarization for Q&A attribution.
- **Deeper on-device intelligence** (local VLM via MLX/Core ML); **Share extension and Shortcuts**.
- **Managed-credit "Pro"** tier for users who do not want to bring a key.

## Suggested first build slice

Phase 0 + Phase 1 is the honest proof of the whole idea: if the deterministic engine picks the right, finished, de-duplicated frames from a real lecture and shows it in the holographic Scan, the rest is well-trodden (on-device Vision, models, native layout, export). Build and validate that first, on a handful of real lectures, before spending a token.
