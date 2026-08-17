# VideoNotes: Audit and Improvements

A full-stack review of the spec as it stood after the native re-spec: product, UX, engine, architecture, design, accessibility, privacy, and cost. Each finding has a recommendation, a priority, and a status. The high-value items are applied into the specs in this pass; the rest are logged for later so nothing is lost.

Priorities: **P0** shippable-quality gap, **P1** high value, **P2** nice to have, **P3** future.

---

## Summary: what changed in this pass

Applied into `SPEC.md`, `ENGINE.md`, `ARCHITECTURE.md`, and the new `DESIGN.md`:

1. **Design language** overhauled to the Holographic Study HUD (Liquid Glass, holographic reticle, signature scan-and-assemble motion) with hard legibility and reduced-motion guardrails. New `DESIGN.md`.
2. **New logo** in the HUD language (reticle scanning a data-complex that assembles into a play core with an arc-reactor glow). Classic mark archived.
3. **On-device by default**: the app is fully usable with no key (Vision OCR + local transcription + vector illustrations). Cloud is an optional quality upgrade, not a requirement. This removes the biggest adoption blocker.
4. **In-app study, not just export**: active-recall review with spaced repetition (FSRS), so the notes get used.
5. **Scrub-to-source**: every card links back to its moment in the video with an inline mini-player.
6. **Inline tutor**: per-card AI actions (explain more, simplify, example, make a question, why it matters).
7. **Home and library + onboarding sample lecture** so first value lands in under a minute.
8. **Cost and trust controls**: pre-run estimate, live meter, hard budget cap, and a privacy dashboard with redaction preview.
9. **Editing power-ups**: keyboard-first review on Mac, explicit undo/redo, editable vector-diagram nodes, original-frame vs sketch compare, Pencil annotations merged into cards and exports.
10. **Pipeline and cost optimizations**: downscaled keyframes to vision, skip the vision call entirely for text-only frames (on-device OCR suffices), batch and tier model calls, and overlap transcription with scanning.
11. **Full-text search**, **read-aloud (TTS)**, and **background processing with a done notification**.

## Product and features

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| P1 | The study loop ends at export. The app makes notes but never helps you learn them. | Build an in-app **Study mode**: flashcards and quizzes with **FSRS spaced repetition**, generated from the notes, with a review schedule and progress. | P1 | Applied (SPEC 6.13) |
| P2 | No link from a note back to the video. Learners cannot verify or re-watch a tricky moment. | **Scrub-to-source**: each card's timestamp opens an inline mini-player at that clip; a timeline shows keyframe markers. | P1 | Applied (SPEC 6.13) |
| P3 | Notes are static. A frontier 2026 study tool should tutor. | **Inline tutor actions** per card: explain more, simplify, give an example, make a question, why it matters. Grounded in the card plus transcript. | P1 | Applied (SPEC 6.13) |
| P4 | No search across a study set or library. | **Full-text search** over notes, headings, glossary, and OCR text; jump to card. | P1 | Applied (SPEC 6.14) |
| P5 | Single-video only; no way to build a subject. | **Course workspace**: group lectures into one revision space with a merged glossary and cross-lecture deck. | P2 | Proposed |
| P6 | No read-aloud. | **TTS narration** of a card or the whole set (AVSpeechSynthesizer), great for revision and accessibility. | P2 | Applied (SPEC 6.13) |
| P7 | No first-run value. | **Bundled sample lecture** and a guided first pass so the user sees a finished study set in under a minute. | P1 | Applied (SPEC 6.14) |
| P8 | Vector diagrams are described as editable but the UI never exposes it. | Let users **drag nodes and edit labels** on reconstructed diagrams; changes persist and re-export. | P2 | Applied (SPEC 6.6, 6.16) |
| P9 | No trust-building comparison. | **Compare toggle**: dim source frame behind the original sketch to confirm accuracy. | P2 | Applied (SPEC 6.16) |
| P10 | iPad Pencil is mentioned but not integrated into the artefact. | **Merge PencilKit annotations** into the card and into PDF/image exports. | P2 | Applied (SPEC 6.16) |

## UX and flow

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| U1 | The flow is a good linear pipeline but there is no home. | Add a **Home / Library** of recent study sets, plus New. Makes the app a place, not a one-shot tool. | P1 | Applied (SPEC 6.14) |
| U2 | Long runs block the user, especially on iOS. | **Background processing** with a **completion notification**; the user can leave and come back. | P1 | Applied (SPEC 6.14, ARCH 10) |
| U3 | One video at a time. | **Queue**: drop several lectures, process in sequence. | P2 | Proposed |
| U4 | Review is mouse-bound. Power users on Mac want speed. | **Keyboard-first review**: j/k move cards, e edit, r regenerate, k/d keep/drop, / search. | P1 | Applied (SPEC 6.16) |
| U5 | Non-destructive is promised but there is no explicit history. | **Undo/redo stack** across all edits and regenerations. | P1 | Applied (SPEC 6.16) |
| U6 | Sensitivity is a bare slider. | Make it the **HUD dial** that re-picks live and re-flows the filmstrip (see DESIGN 8). | P2 | Applied (DESIGN) |

## Engine and correctness

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| E1 | Screen-share/code lectures differ from camera-on-board. | **Adaptive sampling and scoring per content type** (a static slide deck needs far fewer samples than a whiteboard). | P1 | Applied (ENGINE 1, 3) |
| E2 | Code frames need special handling. | Language-aware OCR, monospaced formatting, and syntax highlight in notes; stitch scrolling code across a segment. | P2 | Proposed |
| E3 | A single slide that evolves across several segments can fragment into duplicate-ish cards. | **Cross-segment evolution merge**: detect the same slide growing and keep the final state as one card. | P2 | Proposed |
| E4 | Scores computed on GPU vs CPU can differ slightly across devices, threatening reproducibility of selection. | Pin scoring to a **deterministic path** (fixed precision, tolerance-bucketed thresholds) so the same video yields the same keyframes on any device. | P2 | Applied as note (ENGINE 11) |
| E5 | Understanding spends a vision call on every keyframe, including text-only slides. | For text-only frames, **on-device OCR is sufficient**; skip the VLM call. | P1 | Applied (ENGINE 7, ARCH 7) |

## Architecture and optimization

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| A1 | Full-res keyframes sent to vision waste tokens and bandwidth. | Send **downscaled** keyframes (long edge tuned per provider); keep full-res only for the artefact. | P1 | Applied (ARCH 7) |
| A2 | Stages run sequentially. | **Overlap transcription with scanning** and pipeline understanding while later frames still score, to cut wall-clock. | P1 | Applied (ENGINE 0, ARCH 12) |
| A3 | Every keyframe uses the same (expensive) model. | **Tiered routing**: a cheap model triages, the strong model only handles complex diagrams; batch multiple simple frames per call. | P2 | Applied (ARCH 7) |
| A4 | No hard spend ceiling. | **Budget cap**: user sets a max; the run estimates first and stops at the cap, degrading to on-device. | P1 | Applied (SPEC 6.15) |
| A5 | Provider failures mid-run. | Already handled (retry/backoff, checkpoint). Keep, and surface in the HUD telemetry log. | P1 | Kept |

## Design, graphics, animation

Covered in full by the new `DESIGN.md`. Headlines: a two-surface system (holographic HUD chrome + legible study paper), Liquid Glass materials with a fallback for the OS floor, a disciplined motion system tied to real engine events, and six signature animations (arc-reactor boot, the Scan, completeness lock, card assembly, ambient HUD, export beam). Hard guardrails: never put glow or glass behind body text, and full Reduce Motion / Reduce Transparency / Dynamic Type support.

## Accessibility

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| X1 | A heavy HUD risks excluding motion- and contrast-sensitive users. | **Reduce Motion, Reduce Transparency, Increase Contrast** paths that keep the app fully usable and handsome; a one-tap **Focus/calm mode** that strips the HUD for reading. | P0 | Applied (DESIGN 9, SPEC 8) |
| X2 | Live regions during processing. | VoiceOver **progress announcements** ("28 kept of 1,842 scanned"); decorative HUD hidden from AT. | P1 | Applied (DESIGN 9) |
| X3 | Alt-text for illustrations. | Auto-written alt-text on every illustration, carried into HTML/EPUB/PDF tags. | P1 | Kept (SPEC 8) |

## Privacy, trust, and business

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| B1 | BYO-key is a real adoption blocker; a student may have no key. | **On-device by default**: Vision OCR + local whisper + vector illustrations make a fully usable, private, free experience with zero setup. Cloud is an optional quality tier. | P1 | Applied (SPEC 4, 6.11, ARCH 7) |
| B2 | Users cannot see what leaves the device. | **Privacy dashboard**: per-run, show exactly what will be and was sent, with a redaction preview for on-screen PII. | P1 | Applied (SPEC 6.15) |
| B3 | Pricing path. | v1 is one-off BYO-key with the on-device free path; a later Pro tier bundles managed credits and premium export themes. | P2 | Proposed |

## Proposed backlog (not applied this pass)

Course workspace (P5), processing queue (U3), code-lecture handling (E2), cross-segment slide-evolution merge (E3), speaker diarization for Q&A attribution (P3), incremental re-import of a longer cut (P3), and a managed-credit Pro tier (B3). All are logged here and in `ROADMAP.md` later tracks.
