# VideoNotes v2: Sketchnote Engine Specification

Status: implemented baseline plus roadmap, updated 2026-07-13. Supersedes the *output* sections of SPEC.md (6.5-6.9, study sets, FSRS, tutor). The repository README and `AUDIT-5.md` are authoritative for the currently shipped surface.

## 1. Product contract

One input, one analysis, one output. Everything else is supporting machinery.

- **Input:** exactly one local media file — video (MP4, MOV, M4V) or audio (MP3, M4A, WAV, AAC, FLAC).
- **Analysis:** extract and structure the educational content (what is taught, in what order, with which key points, processes, comparisons, and quotes).
- **Output:** one set of **graphic-style illustrated note pages** — hand-drawn infographic "sketchnotes" (reference: the NotebookLM-style infographic — marker headings, doodle icons, chunky arrows, highlighter blobs, callout quote boxes, numbered process columns). Exported as PNG (per page) and a single PDF.

The illustrated pages ARE the product. Markdown/cards remain internal representations only.

## 2. Pipeline overview

```
Media file
  └─ A. Probe          (video? audio-only? duration, tracks)
  └─ B. Extract        (transcript from audio; OCR'd keyframes from video)
  └─ C. Structure      (→ Semantic Note Model, the single source of truth)
  └─ D. Plan           (SNM → page plan: templates, icons, palette)
  └─ E. Render         (deterministic Core Graphics sketchnote renderer)
  └─ F. Export         (PNG pages, multi-page PDF, share sheet)
```

Stages A-B and E-F are fully deterministic and on-device, always. Stage C has an on-device default and an optional BYO-key LLM tier. Stage D is deterministic.

## 3. Stage A — Probe

- `AVURLAsset` load: duration, video tracks, audio tracks.
- Route: video+audio → full pipeline; video-only (no audio) → OCR-only; audio-only → transcript-only. Reject zero-duration / unreadable (existing `ScanError` paths).
- Long-input policy: hard cap none; adaptive sampling density (see B2) and chunked transcription keep memory flat.

## 4. Stage B — Extract

### B1. Transcript (audio and video files)
- `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` (deploy target macOS 14 / iOS 17; no audio ever leaves device). Locale from settings, default system locale, fallback en-US.
- For video, extract the audio track via `AVAssetReader` to PCM chunks; recognize in ≤60 s windows with 2 s overlap; stitch on word timestamps.
- Output: `[TranscriptSegment { start, end, text }]` at sentence granularity (split on `SFTranscription` segment boundaries + punctuation).
- Info.plist: `NSSpeechRecognitionUsageDescription`. Graceful degrade: if permission denied or recognizer unavailable → OCR-only mode with a visible notice, not a failure.
- Later upgrade slot (v2.1): WhisperKit as an optional quality tier behind the same `Transcriber` protocol.

### B2. Keyframes + OCR (video files)
- Existing sampler, generalized: sample count `min(48, max(7, duration/25s))` evenly spaced fractions; keep the tolerance fix (`Before = .zero`, `After = 0.5s`).
- Existing Vision `VNRecognizeTextRequest` (.accurate, language correction) per frame; existing text-signature dedup; per-frame failures skip (existing behavior).
- Output: `[VisualMoment { time, lines[] }]` for deduped, text-bearing frames.

## 5. Stage C — Structure: the Semantic Note Model (SNM)

Single JSON document both tiers must produce. The renderer consumes ONLY this.

```json
{
  "title": "Transform Your Content Into an Interactive AI",
  "subtitle": "3 No-Code Methods to Turn Your MRR Assets into AI Products",
  "language": "en",
  "sections": [
    { "kind": "concept",
      "heading": "Your Content Becomes the Brain of the AI",
      "body": "You ground a powerful AI model in your specific knowledge…",
      "points": ["Answers limited to your content", "Passive info → active tool"],
      "iconHints": ["brain", "document", "arrow"],
      "sourceTime": 184.2 },
    { "kind": "quote",
      "text": "Basically what you have done is you have created an AI for them…",
      "sourceTime": 201.0 },
    { "kind": "methods",
      "heading": "3 No-Code Methods to Create Your AI Product",
      "columns": [
        { "title": "NotebookLM", "tagline": "Create a Private Q&A Bot",
          "summary": "A focused private chat experience…",
          "steps": ["Load MRR docs into a Notebook", "Set to Anyone with the link", "…"],
          "iconHints": ["notebook", "lock", "link"] }
      ] },
    { "kind": "process", "heading": "…", "steps": ["…"], "iconHints": ["…"] },
    { "kind": "comparison", "heading": "…", "left": {"…"}, "right": {"…"} },
    { "kind": "definition", "term": "…", "meaning": "…" },
    { "kind": "summary", "heading": "Key Takeaways", "points": ["…"] }
  ]
}
```

Rules (both tiers): title required; 2-9 sections; every string grounded in transcript/OCR (no invented facts); `points` ≤ 6, each ≤ 90 chars; `steps` ≤ 6, each ≤ 60 chars; quotes verbatim from transcript; `iconHints` from the icon vocabulary (§8), renderer treats them as hints not commands.

### C1. On-device tier (DEFAULT — works with zero keys)
Deterministic heuristics over transcript + OCR:
- **Segmentation:** topic boundaries from (a) slide-change times (visual-moment signature changes), (b) long pauses (> 2.5 s), (c) discourse markers ("next", "the second method", "in summary"). Merge to 2-9 sections.
- **Headings:** OCR first-line of the section's dominant slide when present (slides are usually better titles than speech); else top keyphrase via `NLTagger` lexical class + frequency-weighted n-grams.
- **Points:** rank section sentences by keyphrase density + position; compress to clauses (strip fillers via NL tokenization); cap and truncate at word boundaries.
- **Kind detection:** enumerations ("three ways", numbered slide lists, parallel OCR columns) → `methods`/`process`; "X is/means" → `definition`; high-emphasis verbatim sentence (spoken slowly / repeated / quoted on slide) → `quote`; final section → `summary`.
- **iconHints:** keyword → icon-vocabulary lookup table (§8).
- Fully deterministic: same input file → same SNM.

### C2. BYO-key tier (OPTIONAL, per [[feedback_connection_agnostic]])
- One schema-confined LLM call (PROMPTS.md conventions: content-as-data injection defence, grounding contract, JSON schema = SNM, temperature 0). Input: stitched transcript + deduped OCR blocks with timestamps. Providers: Anthropic / OpenAI / Google / OpenAI-compatible / local, keys in Keychain.
- Validation: schema check + grounding spot-check (every quote must substring-match transcript; headings must share ≥ 1 content word with the section span). Fail → fall back to C1, never block.

## 6. Stage D — Plan: pages and templates

Deterministic mapping SNM → `PagePlan`:

- Page size: 1080×1920 pt portrait (phone/social-friendly, matches reference) — A4 variant at export.
- **Template library v1** (each maps to a panel in the reference image):
  1. **Hero** — title, subtitle, one big metaphor doodle (docs → sparkle chat), corner squiggles.
  2. **Concept** — heading, doodle cluster (e.g. documents → arrows → circuit-brain), body paragraph + up to 3 highlighter-underlined points, optional attached quote box.
  3. **Methods** — heading + 2-3 columns, each: title (highlight chip), tagline in script font, summary, numbered icon steps.
  4. **Process** — heading + vertical numbered steps with icons and connector arrows.
  5. **Comparison** — two half-page panels, VS badge, mirrored points.
  6. **Quote** — full-width tilted quote card, oversized quotation marks, attribution.
  7. **Summary** — checklist with hand-drawn checkboxes.
- Packing: hero always page 1; sections flow in order; `concept`+its `quote` co-locate; a `methods` with 3 columns gets a full page; two small sections may share a page. Text measured with actual fonts; overflow → drop lowest-ranked points first, then spill to continuation page. Minimum body size 24 pt — never shrink below, always cut instead.
- Palette (from reference, default "Paper & Ink"): paper #F7F4EC, ink #2B2B2B, highlight #F4E948, steel-blue #5B7285, gold #C9A227. Three alternates (Blueprint, Chalkboard, Pastel) selectable in UI; palette is part of the plan, not the renderer.

## 7. Stage E — Render: the sketchnote look

SwiftUI-hosted `CGContext` renderer (offscreen, per page). All randomness from a **seeded PRNG (SplitMix64, seed = SHA-256 of file + settings)** → identical re-renders, golden-image testable. "Shuffle style" in UI just bumps the seed.

- **Rough strokes:** every visible line (borders, arrows, underlines, icon strokes) is a perturbed path: resample at ~12 pt intervals, offset each point perpendicular by 1-D value-noise (amp 1.5-3 pt), render 2 overlapping passes at 60-75 % alpha with slight offset → marker-sketch ink. Rounded caps/joins.
- **Panels:** rounded rects via rough strokes, corner radii jittered per corner; optional torn-paper edge for the hero.
- **Highlighter:** fat (18-26 pt) single rough stroke behind keywords/chips, multiply blend, highlight color.
- **Arrows:** thick tapered chunky arrows (filled rough outline, like the reference's steel-blue arrows) + thin squiggle arrows for annotations.
- **Doodles/icons:** from the icon library (§8), rough-stroked, occasional gold sparkle accents.
- **Typography:** bundled SIL-OFL hand fonts — headings **Shantell Sans** (bold), body **Patrick Hand**, script accents **Caveat**. OFL permits app bundling; register via `CTFontManagerRegisterFontsForURL`. Fallback: SF Rounded. CJK/RTL v1: fallback to rounded system font (hand fonts are Latin-only) — content still correct, style degrades gracefully.
- **Paper:** flat paper color + very low-amplitude noise grain + faint corner-dot registration marks (reference has subtle print feel). No skeuomorphic gradients.
- Renders at 2x by default (2160×3840 px), 3x optional.

Relationship to DESIGN.md: the app chrome stays Holographic Study HUD (dark holo shell); the sketchnote is the *artifact* visual language (bright paper). Two-surface principle already in DESIGN.md — chrome vs study-paper — this makes the paper literal.

## 8. Icon library

- ~120 curated original hand-drawn vector glyphs, authored as normalized `CGPath` data (Swift codegen from an internal SVG folder at build time; no runtime SVG parsing). Categories: objects (document, notebook, brain, gear, lock, link, cloud, folder, globe, chart, lightbulb, magnifier, chat, play, book…), actions (upload, share, settings, check, plus), decorations (sparkle, squiggle, underline, ring, speech-bubble, banner).
- Keyword map: `iconHint` string → glyph id (+ synonyms table: "ai" → brain-circuit, "share" → link/arrow-out…). Unknown hint → deterministic fallback rotation of generic doodles (bulb, ring, sparkle) — never blank, never a wrong-looking specific icon.
- All original artwork (drawn in-house as paths) — no copyrighted icon sets; keeps App Store clean.

## 9. Stage F — Export & UI

- Export: PNG per page, one PDF (vector where possible: render pages into `CGPDFContext` directly — the renderer is CG, so PDF stays true vector; PNG rasterized from the same draw). Share sheet + save panel. Filenames `<source-name>-notes-p1.png`.
- UI flow (keeps current shell): Paywall → Import (or drag-drop) → progress ("Transcribing 12:40 of 48:12" → "Reading slides 9/24" → "Structuring notes" → "Illustrating page 3 of 5") → **page carousel preview** (pinch zoom, swipe) → style bar (palette picker, density: compact/roomy, shuffle-seed) → Export.
- Style/density/palette changes re-run only D+E (fast); shuffle only E.
- Existing DEBUG hooks extend: `VIDEONOTES_AUTO` (unchanged), `VIDEONOTES_AUTO_OUT` now writes the SNM JSON, `VIDEONOTES_AUTO_PNG=<dir>` writes rendered pages headlessly for golden tests.

## 10. Non-functional

- 60-min 1080p lecture: extract ≤ 4 min on M-series (transcription dominates; runs concurrent with sampling), structure < 1 s on-device tier, render < 1 s/page. Memory flat via streaming PCM + one-frame-at-a-time sampling.
- Zero network in default mode; BYO-key calls only in C2 and only transcript/OCR text is sent (never media). SECURITY.md T1 (content-as-data) applies to C2 verbatim.
- Sandbox unchanged (user-selected read + security-scoped bookmark for re-analysis).

## 11. Architecture & code layout

New local SPM package `SketchnoteEngine` (pure, XCTest-covered, no UI):
```
Engine/Sources/
  Probe.swift  Transcriber.swift  FrameSampler.swift  OCR.swift
  SNM.swift (model + validation)  HeuristicStructurer.swift  LLMStructurer.swift
  PagePlanner.swift  Templates/*.swift  IconLibrary.swift (+ generated Glyphs.swift)
  RoughRenderer.swift (stroke synth)  PageRenderer.swift  Exporter.swift  Pipeline.swift
```
App target consumes `Pipeline`. `VideoStudyModel` becomes a thin observable wrapper (progress enum per stage, cancel via structured concurrency).

## 12. Testing

- Unit: segmentation, heading extraction, SNM validation, keyword→icon map, text-fit/overflow, PRNG stability.
- Golden images: fixture SNM JSONs → rendered PNG hash-compare (seeded, deterministic — safe in CI). Tolerance: exact bytes on same OS; per-OS goldens.
- E2E: extend the ffmpeg 3-slide fixture with a spoken-audio track (say/afconvert-generated speech) → assert SNM has 3 sections with expected headings → pages render non-empty via `VIDEONOTES_AUTO_PNG`.
- EVALUATION.md gates re-targeted: section-boundary F1 vs hand-labeled fixtures; grounding checks (no SNM string absent from source).

## 13. Milestones

- **M1 (build first):** Probe + Transcriber + heuristic SNM + templates Hero/Concept/Process + RoughRenderer + PNG/PDF export + progress UI. Audio-only files fully supported. → validate the look on 3 real lectures before widening.
- **M2:** video OCR fusion (slide-aware headings/sections), full template set, icon library complete, palettes, page carousel + style bar.
- **M3:** BYO-key structurer + validation/fallback, density modes, A4 export, golden CI suite.
- **M4 (post-ship candy):** WhisperKit tier, PencilKit annotation on pages, per-section regenerate.

## 14. Open questions (defaults chosen, flag if wrong)

1. Page aspect: defaulting to 1080×1920 portrait like the reference (A4 at export in M3). 
2. Hand fonts are Latin-only; non-Latin lectures render in rounded system font v1.
3. Paywall is Pro monthly; price, billing period and any introductory offer are shown only from StoreKit product and account-eligibility state.
