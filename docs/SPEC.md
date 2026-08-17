# VideoNotes: Product and Functional Specification

Version 0.1 (draft) · Target: frontier quality, 2026 · Author: Luke McLaughlin

> Product-vision document. It includes roadmap capabilities that are not in the current app. See the repository README and `AUDIT-5.md` for the implemented feature set and verified release status.

---

## 1. One line

VideoNotes turns any lecture video into a set of clean, original, illustrated study notes: it watches the video, keeps only the frames that carry finished educational content, understands them, redraws the key visuals as original sketches, writes concise notes underneath each one, and exports the result to every common document format.

## 2. The problem

Students and self-learners consume a huge amount of video: recorded lectures, MOOC modules, conference talks, YouTube explainers, tutorials. Video is a poor study medium. You cannot skim it, search it, annotate it well, or revise from it the night before an exam. Today people either:

- re-watch at 2x and pause to screenshot (slow, messy, low-retention), or
- paste an auto-transcript into a chatbot (loses every diagram, formula and board sketch, and produces a wall of text with no visual anchors).

Neither produces the thing a learner actually wants: a compact, visual, well-structured set of notes they can own, edit, print and revise from.

## 3. What VideoNotes produces

A **Study Set**: an ordered document that follows the lecture's flow. Each unit ("Note Card") contains:

1. an **original illustration** (a redrawn diagram, chart, or concept sketch, not a screenshot of the video), and
2. **concise, structured notes** underneath it (key points, definitions, formulas, worked steps, why-it-matters), grounded in both what was shown on screen and what the lecturer said.

Around the cards, the Study Set adds a title, a one-page summary, a table of contents, a glossary of key terms, and an optional auto-generated quiz / flashcard deck. The whole thing exports to PDF, Word, PowerPoint, Markdown, HTML, EPUB, LaTeX, Anki, and more.

## 4. Design principles

| Principle | What it means in practice |
| --- | --- |
| **Original, not copied** | Illustrations are redrawn from scratch in a consistent house style. The app never ships the raw video frame as the "illustration". Frames are kept only as an optional dim reference thumbnail. This is both a quality choice (clean, legible, consistent) and a rights-hygiene choice. |
| **Signal over noise** | The engine's core job is deciding what NOT to include. Half-written boards, transitional frames, talking-head shots, duplicate slides, and blurry frames are rejected before any AI cost is spent. |
| **Deterministic core, AI at the edges** | Frame selection, scoring, dedup, layout and export are deterministic and unit-tested. AI is used only for understanding (vision + language) and generation (notes + sketches). The same video with the same settings yields the same selection every time. |
| **The learner owns it** | Everything is editable. Nothing is locked. Projects are re-openable and re-exportable. Notes are plain, portable data. |
| **On-device first, bring your own intelligence** | The app works fully with no key at all: on-device OCR, transcription, and vector illustrations. Connecting a key (Anthropic, OpenAI, Google, or a local model) is an optional quality upgrade, never a requirement. No hardcoded provider. |
| **Private by default** | Video never leaves the machine. Only the selected keyframes and their aligned transcript snippets are sent to the chosen model, and only when the user has connected a cloud provider. Offline mode sends nothing. |
| **Content is data, not commands** | Everything the app reads (slide text, transcripts, attached files) is untrusted study material, never instructions. Text hidden inside a lecture cannot make the app act: the note models get no tools, no network, and no access to your other notes. See `SECURITY.md`. |
| **A live instrument, still legible** | The interface is a holographic study HUD (Liquid Glass, a scanning reticle, knowledge assembling in real time), but note content stays calm and perfectly readable. Atmosphere lives in the chrome and the motion, never behind the text. See `DESIGN.md`. |

## 5. Target users

- **University / college students** revising from recorded lectures.
- **Self-directed learners** working through MOOCs, YouTube courses, bootcamp recordings.
- **School / exam candidates** (A-levels, Abitur, AP) building revision packs.
- **Professionals** distilling conference talks and internal training into reference notes.
- **Educators** turning their own recordings into hand-out notes for students.

Primary job to be done: "I watched (or need to watch) this lecture. Give me notes I would have made if I were an excellent, tireless note-taker, that I can revise from and edit."

## 6. Functional requirements

### 6.1 Import

- **FR-IMP-1** Import local video files: mp4, mov, m4v, and other AVFoundation-supported formats. On iOS/iPadOS also import straight from the Photos library (`PhotosPicker`) and Files; on macOS via open panel, Files, and drag-and-drop. Formats AVFoundation does not natively decode (mkv, webm) are handled on macOS when the user has ffmpeg installed (optional, auto-detected), otherwise flagged with guidance.
- **FR-IMP-2** Import local audio-only files (mp3, m4a, wav) for transcript-only note sets (no illustrations, notes from speech).
- **FR-IMP-3** Optional "Import from URL" for videos the user is entitled to (e.g. their own institution's hosting). Uses a pluggable downloader that is off by default and clearly gated with a rights reminder. Not a piracy tool: it never bypasses DRM.
- **FR-IMP-4** Platform-native import: drag-and-drop and open panel on macOS, `PhotosPicker`, document picker, and share-sheet-in on iOS and iPadOS. Show duration, resolution, size, and an estimated processing cost (frames to analyse, on-device vs. provider work, approximate tokens) before the user commits.
- **FR-IMP-5** Accept an existing transcript / caption file (.srt, .vtt) to skip local transcription and improve accuracy.

### 6.2 Intelligent scan and keyframe selection (the core engine)

See `ENGINE.md` for the algorithm. Requirements:

- **FR-SCAN-1** Decode and sample the video efficiently without loading it all into memory.
- **FR-SCAN-2** Segment the video into content segments using scene/shot detection.
- **FR-SCAN-3** For each segment, select the single most complete, sharpest, least-occluded representative frame ("keyframe"). "Most complete" explicitly means: the moment the on-screen content is finished, just before it is erased, scrolled, or replaced. Half-written boards and mid-build slides must be rejected.
- **FR-SCAN-4** Classify each keyframe by content type: slide, whiteboard/blackboard, handwritten paper, code/screen-share, document, chart/graph, demo, or talking-head. Talking-head-only and content-free frames are dropped.
- **FR-SCAN-5** Deduplicate near-identical keyframes across the whole video (a slide shown twice, a board left up while the speaker talks) keeping the best single representative.
- **FR-SCAN-6** Every keep/drop decision is inspectable and reversible in the UI. The user can lower/raise sensitivity and re-run selection without re-decoding.
- **FR-SCAN-7** A "sensitivity" control trades recall vs. precision (fewer, denser cards ↔ more, finer cards), with sensible defaults per detected content type.

### 6.3 Transcription and alignment

- **FR-TR-1** Produce a timestamped transcript of the audio, on-device by default (bundled whisper.cpp or the Speech framework `SFSpeechRecognizer`), or via a provider API, or from an imported caption file.
- **FR-TR-2** Align transcript segments to keyframes by timestamp so each card's notes are grounded in what was actually said while that content was on screen.
- **FR-TR-3** Detect and label the spoken language; support non-English lectures (see i18n).

### 6.4 Understanding

- **FR-UND-1** For each keyframe, a vision model extracts a structured understanding: topic/title, transcribed on-screen text (OCR), any diagram described as structure (nodes, edges, labels, axes, series), formulas as LaTeX, and a content-completeness judgement (final gate that can still reject a frame the deterministic stage let through).
- **FR-UND-2** Understanding is grounded with the aligned transcript snippet to disambiguate (e.g. an axis label the camera never showed clearly).
- **FR-UND-3** Understanding output is cached per keyframe so edits and re-exports do not re-spend tokens.

### 6.5 Note generation

- **FR-NOTE-1** For each kept keyframe, generate concise, structured study notes: a short heading, 3–7 key points, definitions of new terms, formulas (rendered, not as raw text), worked steps where relevant, and a one-line "why this matters" when useful.
- **FR-NOTE-2** Notes use both the visual understanding and the aligned transcript, and stay consistent across adjacent cards (shared terminology, no repetition of the same definition twice).
- **FR-NOTE-3** Note density is a user setting: `terse` (bulleted essentials), `balanced` (default), `detailed` (fuller explanations with examples).
- **FR-NOTE-4** Notes never hallucinate beyond source: if the model is uncertain, it marks a point as "check" rather than inventing. Claims that appear only in speech vs. only on the slide can be optionally tagged by source.

### 6.6 Original illustration / sketch generation

See `ENGINE.md` §Sketch engine. Requirements:

- **FR-ILL-1** For each card, generate an **original** illustration in a consistent house style, chosen intelligently by content type:
  - **Structured visual** (flowchart, graph, tree, cycle, mind-map, timeline, table, matrix, Venn, sequence/UML, ER diagram, bar/line/scatter chart, circuit, chemical structure, simple map, labelled diagram): reconstruct the *structure* and render it as clean vector art with a hand-drawn "study sketch" finish. This is deterministic and crisp, never a copy of the pixels. See `ENGINE.md` §9 for the full taxonomy.
  - **Mathematical**: render formulas and derivations as typeset math.
  - **Conceptual / illustrative** (a metaphor, an anatomy sketch, a physical setup): generate an original line-art illustration via the connected image model, prompted from the concept, in the same house style.
- **FR-ILL-2** All illustrations across one Study Set share a single visual style ("style token") so the notes look like one coherent notebook.
- **FR-ILL-3** Illustrations are accurate: labels, quantities, axis directions and relationships must match the source. Reconstructed vector diagrams are preferred over generative images whenever the content is structured, because they are exact and editable.
- **FR-ILL-4** The user can, per card: regenerate the illustration, switch its mode (vector ↔ generative ↔ formula ↔ "use dim source frame"), edit labels, or drop the illustration entirely.
- **FR-ILL-5** Reconstructed vector diagrams are directly editable: drag nodes, rename labels, and re-colour, with edits persisted and carried into every export.
- **FR-ILL-6** A "compare to source" toggle dims the original video frame behind the sketch so the learner can confirm the redraw is accurate.

### 6.7 Study Set assembly

- **FR-DOC-1** Assemble kept cards into an ordered document that follows the lecture's structure, grouping cards into sections/chapters where the content suggests them.
- **FR-DOC-2** Generate front matter: title (from the lecture), a one-page executive summary, and a table of contents.
- **FR-DOC-3** Generate back matter: a glossary of key terms (deduplicated across the set) and an optional auto-quiz: multiple-choice and short-answer questions, plus a flashcard deck (question/answer pairs) derived from the notes.
- **FR-DOC-4** Every generated element is editable and individually toggleable.

### 6.8 Review and edit

- **FR-ED-1** A two-pane workspace: a left rail (outline + keyframe filmstrip with keep/drop state) and a main pane of editable Note Cards.
- **FR-ED-2** Per card actions: edit notes (rich text + Markdown + LaTeX), regenerate notes, regenerate/switch illustration, edit the heading, reorder (drag), merge two cards, split a card, delete, or restore a previously dropped frame.
- **FR-ED-3** Bulk actions: re-run selection at a new sensitivity, regenerate all notes at a new density, restyle all illustrations, translate the whole set.
- **FR-ED-4** Non-destructive: original selection, source frames, and transcript are always retained so any regeneration is possible without re-importing.

### 6.9 Export

See `ARCHITECTURE.md` §Export. All exports are driven from the same internal Study Set model.

- **FR-EX-1** Export formats (v1 core): **PDF**, **DOCX** (Word), **PPTX** (PowerPoint), **Markdown** (+ asset folder, Obsidian-friendly callouts), **HTML** (single self-contained file).
- **FR-EX-2** Export formats (v1 extended): **EPUB**, **Anki** (`.apkg` flashcards + cloze), **LaTeX**, **RTF**, **JSON** (the raw Study Set, re-importable), plain **TXT**.
- **FR-EX-3** Export via detected tools when present for extra targets (ODT, DOCX↔ODT, etc. via pandoc if installed), following the same "detect optional tools" pattern the engine uses for downloaders and local models.
- **FR-EX-4** "Send to Notion" (paste-ready Markdown or, if a token is connected, a direct page push). Never required, never default.
- **FR-EX-5** Export options: theme (see design), paper size, include/exclude source thumbnails, include/exclude quiz, include/exclude glossary, one-card-per-page vs. flowing layout, table-of-contents on/off.
- **FR-EX-6** Exports are pixel-faithful to the in-app design: vector illustrations stay vector in PDF/DOCX/PPTX/SVG-capable targets.

### 6.10 Projects and reproducibility

- **FR-PRJ-1** Each run is a saved project (a `.videonotes` bundle) containing the source reference, extracted keyframes, transcript, the Study Set model, illustrations, and the run settings ("recipe").
- **FR-PRJ-2** Re-open, edit, and re-export without the original video (though re-selecting frames needs it).
- **FR-PRJ-3** A run is checkpointed and resumable: closing or crashing mid-processing does not lose completed work, and a long lecture resumes from the last completed stage.
- **FR-PRJ-4** The recipe (settings) can be saved as a preset and reused ("My lecture style").

### 6.11 Providers, keys, offline

See `PROVIDERS` section in `ARCHITECTURE.md`.

- **FR-PROV-0** Works with no key by default: on-device Vision OCR, on-device transcription, and vector/formula illustrations produce a complete study set offline. Connecting a provider is optional and only raises quality (semantic understanding of complex diagrams, generative illustrations, higher-accuracy transcription).
- **FR-PROV-1** Connect one or more providers by key: Anthropic, OpenAI, Google, plus a generic OpenAI-compatible endpoint (for local servers such as Ollama / LM Studio).
- **FR-PROV-2** Assign capabilities (vision, notes, transcription, image generation) to providers independently, with automatic best-available defaults.
- **FR-PROV-3** Keys are stored in the OS keychain, never in plain project files, never logged.
- **FR-PROV-4** Fully-offline mode: deterministic selection + on-device Vision OCR + local transcription (whisper.cpp or Speech) + optionally a local vision/text model (OpenAI-compatible endpoint or MLX/Core ML) + vector/formula illustrations. Zero network egress, clearly indicated.
- **FR-PROV-5** Graceful degradation: if image generation is unavailable, fall back to vector/formula illustrations; if vision is unavailable, fall back to transcript-grounded notes with source-frame thumbnails.

### 6.12 Settings

- Providers & keys, default capability routing, offline toggle.
- Default note density, illustration style, sensitivity, and language.
- Privacy: what may be sent, redaction of on-screen PII before upload (optional), telemetry off by default.
- Appearance: study theme light (default) / dark / system, the optional Immersive HUD theme, Focus (calm) mode, Reduce Motion and Reduce Transparency honoured, accent, study font (including a dyslexia-friendly option).
- Storage: project location, cache size, clear cache.

### 6.13 In-app study, review, and tutor

- **FR-STU-1** Study mode: turn a set into an active-recall session (flashcards and quizzes generated from the notes), scheduled with spaced repetition (FSRS), with per-card mastery and a review queue that persists across sessions. This is the payoff: the notes get used, not just made.
- **FR-STU-2** Scrub-to-source: each card's timestamp opens an inline mini-player at that moment of the video; a timeline shows keyframe markers to jump between cards and re-watch a tricky moment.
- **FR-STU-3** Inline tutor: per-card AI actions (explain more, simplify, give an example, make a practice question, "why does this matter"), grounded in the card plus transcript, appended as editable note extensions.
- **FR-STU-4** Read-aloud: narrate a card or the whole set with on-device TTS (AVSpeechSynthesizer) and word highlighting, for revision and accessibility.

### 6.14 Home, library, search, and onboarding

- **FR-LIB-1** Home / Library: recent and pinned study sets, a quick "New from video", and (later) Course groupings of related lectures.
- **FR-LIB-2** Full-text search across a study set (headings, notes, glossary, OCR text) and across the library; results jump to the card.
- **FR-LIB-3** First-run onboarding with a bundled sample lecture that produces a finished study set in under a minute, no key required, so value lands immediately.
- **FR-LIB-4** Background processing: long runs continue when the app is backgrounded, with a completion notification; the user can leave and return.

### 6.15 Cost, budget, and trust controls

- **FR-TRUST-1** Pre-run estimate: before any spend, show frames to analyse, on-device vs. provider work, and an approximate token/cost range.
- **FR-TRUST-2** Live meter and hard budget cap: the user sets a maximum; the run meters spend live and stops at the cap, degrading gracefully to on-device rather than overspending.
- **FR-TRUST-3** Privacy dashboard: per run, show exactly what will be and was sent to which provider, with a preview of on-screen PII redaction (blur emails/names) before upload.

### 6.16 Editing power-ups

- **FR-EDIT-1** Keyboard-first review on macOS: navigate cards (j/k), edit (e), regenerate (r), keep/drop, search (/), with a discoverable shortcut map.
- **FR-EDIT-2** Explicit undo/redo across every edit, regeneration, and bulk action.
- **FR-EDIT-3** Apple Pencil (iPad): freehand annotate notes and sketches; annotations merge into the card and into PDF/image exports.
- **FR-EDIT-4** Direct vector-diagram editing (drag nodes, rename labels) as in FR-ILL-5, with a compare-to-source toggle (FR-ILL-6).

### 6.17 Multi-input fusion (attach slides and transcript)

- **FR-FUSE-1** Optionally attach the lecture's source deck (PDF, PPTX, Keynote) and/or a transcript/caption file. These are treated as content inputs, never as instructions (see `SECURITY.md`).
- **FR-FUSE-2** Align each kept keyframe to its matching slide by visual similarity, so notes use the deck's exact text and the illustration is redrawn from the deck's real vector structure. This removes OCR error and makes diagrams exact.
- **FR-FUSE-3** Fusion only ever improves accuracy, never fabricates: a slide skipped in the talk is not invented into a card, and a keyframe with no matching slide (a live board) falls back to OCR.
- **FR-FUSE-4** With slides attached, most understanding needs no vision model at all (the deck is ground truth), cutting cost as well as error.

### 6.18 Robustness on real-world lectures

- **FR-ROB-1** Defined, graceful behaviour across the real range of inputs (see the robustness matrix in `ENGINE.md`): talking-head-only (few or no cards, said clearly), no audio (visual-only notes), non-English (end to end in that language), portrait phone video, handwriting-only, code screencasts, math-heavy, screen recordings with a cursor, and animations.
- **FR-ROB-2** Bad inputs fail safely and legibly: corrupt or unsupported files, DRM-protected sources (declined with an explanation, never bypassed), and uniformly low-quality video (best effort with a quality warning).
- **FR-ROB-3** No input produces a crash or a silently empty result; the app always explains what it found and why.

### 6.19 Sync, telemetry, and voice

- **FR-SYS-1** iCloud sync of study sets across the user's devices with safe conflict resolution (no silent lossy merges); a study set is a portable document.
- **FR-SYS-2** Telemetry is off by default and, if enabled, is aggregate and on-device-derived only (counts and timings); note, transcript, and video content are never sent.
- **FR-SYS-3** Product voice: plain, encouraging, honest; sentence case, no hype; errors say what happened and what to do; uncertainty is shown, not hidden.

## 7. Primary user flow

1. **Drop a lecture in.** VideoNotes shows length, quality, and an estimate ("~34 keyframes, ~2 min, ~X tokens").
2. **Scan.** A live "analysis filmstrip" streams past: candidate frames are scored in real time, rejected ones dim out, kept keyframes snap into the outline. The user sees the intelligence working and can stop early.
3. **Generate.** Understanding, notes, and illustrations are produced per card with visible progress. Cards fill in top-to-bottom.
4. **Review.** The learner reads, tweaks a heading, regenerates one sketch they want cleaner, deletes one redundant card, bumps two sections' notes to "detailed".
5. **Export.** Pick PDF for printing plus Anki for spaced revision. Done.

Total hands-on time target for a 60-minute lecture: under 3 minutes of user attention, most of it optional review.

## 8. Non-functional requirements

| Area | Requirement |
| --- | --- |
| **Platforms** | One universal SwiftUI codebase for macOS, iPadOS, and iOS. Full capability on Mac and iPad; iPhone supports import, processing of shorter clips, review, and export. All three share the same engine and documents (iCloud Drive). |
| **Performance** | Deterministic scan of a 60-minute 1080p lecture completes in well under real time on Apple silicon (target: under 3 min on a modern Mac or recent iPad; iPhone favours shorter clips). AI stages run with bounded concurrency and stream results. |
| **Memory** | Frame extraction and hashing are streamed in autorelease-pooled batches; peak memory stays bounded regardless of video length, and stays within iOS/iPadOS limits for long inputs (chunked and checkpointed). |
| **Reliability** | Any stage is resumable from checkpoint. A single failed provider call retries with backoff and never aborts the whole run. |
| **Privacy** | Video and full frame set stay local. Only selected keyframes + aligned transcript snippets are uploaded, and only to the user's chosen provider. Offline mode uploads nothing. No telemetry without explicit opt-in. |
| **Accuracy** | Illustrations and notes must match the source. Structured content is reconstructed exactly (vector), not approximated. Uncertain items are flagged, not invented. |
| **Accessibility** | Full keyboard navigation (macOS), VoiceOver with live progress announcements, Dynamic Type, Reduce Motion and Reduce Transparency paths, high-contrast theme, a one-tap Focus (calm) reading mode, dyslexia-friendly font, PencilKit editing on iPad, and alt-text auto-written for every illustration in HTML/EPUB/PDF exports. |
| **Internationalisation** | Handle non-English lectures end to end: transcription, understanding, notes, and export in the lecture's language, with an optional "translate notes to X" pass. First-class support for the languages Luke already targets (English, German, Chinese, Japanese) including correct rendering (CJK fonts, pinyin/furigana where relevant). |
| **Offline-first core** | The app is fully usable for scanning, editing, and vector/formula illustration with no internet and no key. |
| **Design and motion** | Holographic Study HUD with Liquid Glass and signature scan-and-assemble animations, over a legible study surface. All motion maps to real pipeline events, honours Reduce Motion, and never sits behind body text. Target 120fps on ProMotion. See `DESIGN.md`. |

## 9. Quality bar and success metrics

Each metric below has a concrete, running measurement and (for the important ones) a release gate in `EVALUATION.md`. Quality is measured, not asserted.

- **Selection precision/recall**: on a labelled test set of lectures, keyframes match a human's "these are the slides/boards worth keeping" with high precision (few junk cards) and high recall (few missed concepts). Tracked as a regression metric on fixtures.
- **Completeness correctness**: for progressive-build content (whiteboard, animated slides), the chosen frame is the finished state in the large majority of segments.
- **Note faithfulness**: spot-check rubric on a fixture set: notes contain no claim absent from frame+transcript; formulas are correct; terms are defined.
- **Illustration accuracy**: reconstructed diagrams preserve all labels/relationships; generated sketches carry no incorrect labels.
- **Time saved**: a 60-minute lecture becomes an editable, exportable Study Set with under 3 minutes of user attention.
- **Export fidelity**: every format opens cleanly in its native app with intact math and vector art.

## 10. Out of scope for v1

- Real-time / live-stream capture (v1 is file and completed-recording based).
- Team collaboration / cloud sync (local-first only).
- Non-Apple platforms (Android, Windows, web); v1 is Apple-native only.
- Multi-lecture Course workspaces (v1 has a home/library of single-video study sets; Course grouping is a later track).
- Anything that bypasses DRM or scrapes paid platforms.

## 11. Distribution

- Universal native app. macOS distributed as a notarised, direct-download DMG (unsigned for first internal builds, consistent with Alembic and the other siblings in `DMG_Applications`); iOS and iPadOS via TestFlight then the App Store.
- BYO-key plus a genuine on-device offline mode means no server and no per-user running cost, and fits App Store review (the user supplies their own key, and the app is fully functional offline).
- A future "Pro" tier could bundle managed credits or advanced export themes, but v1 ships as a one-off BYO-key product. Not a v1 dependency.

---

See also: `ENGINE.md` (the intelligence), `ARCHITECTURE.md` (stack, data model, providers, export, testing), `DESIGN.md` (the Holographic Study HUD, Liquid Glass, motion), `PROMPTS.md` (model contracts and prompt strategy), `EVALUATION.md` (how quality is measured and gated), `SECURITY.md` (threat model and prompt-injection defence), `AUDIT.md` and `AUDIT-2.md` (the reviews that shaped this), `ROADMAP.md` (build plan).
