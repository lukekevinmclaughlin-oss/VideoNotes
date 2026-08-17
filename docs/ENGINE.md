# VideoNotes: The Intelligence Engine

How VideoNotes decides what to keep, understands it, writes notes, and redraws the visuals. This is the differentiator. Everything here in the deterministic stages is pure, reproducible, and unit-tested; the AI stages are isolated behind the provider layer.

---

## 0. Pipeline at a glance

```
video ─▶ [1 Decode & Sample] ─▶ [2 Segment] ─▶ [3 Score frames] ─▶ [4 Pick keyframe / segment]
                                                                        │
        [5 Dedup across video] ◀───────────────────────────────────────┘
              │
              ▼
        [6 Transcribe + align] ─▶ [7 Vision understanding] ─▶ [8 Note generation]
                                                                    │
                                          [9 Sketch engine] ◀───────┘
                                                    │
                                                    ▼
                                          [10 Assemble Study Set]
```

Stages 1 to 5 and 10 are deterministic. Stages 6 to 9 add understanding and generation: much of it runs on-device (Vision OCR, Speech or whisper transcription, all vector sketching), and only the semantic and generative parts use the provider layer. Each is grounded by the deterministic outputs and caches its result keyed by a content hash, so re-runs and edits do not re-spend tokens or time.

The guiding idea: **spend deterministic compute to throw away 95% of frames, so expensive model calls only ever touch the handful of frames that actually carry finished teaching content.** A 60-minute lecture at 30fps is 108,000 frames; a good Study Set is 20–60 cards. The engine's real product is that reduction, done correctly.

Stages overlap to cut wall-clock: transcription runs alongside frame scanning (audio and video are independent), and understanding/notes/sketch pipeline per keyframe as soon as each is selected rather than waiting for the whole scan to finish. The user sees cards begin to assemble while later frames are still being scored.

---

## 1. Decode and sample

- Use AVFoundation to read and sample the video: `AVAsset` for metadata (duration, fps, resolution, rotation) and `AVAssetImageGenerator` for frame extraction (async, hardware-accelerated, no bundled ffmpeg).
- **Two-rate strategy.** A coarse *scan pass* extracts frames at an adaptive low rate (default 1 fps, raised to 2–3 fps for fast-changing content, lowered for static slide decks). A later *refine pass* extracts a small burst of full-rate frames only inside the short windows where a keyframe is being chosen, to nail the exact "finished" moment.
- Frames are decoded to a small working size (e.g. long edge 512 px) for scoring; the chosen keyframe is later re-extracted at full resolution.
- Streamed: frames are processed and released one at a time. The whole video is never resident in memory.
- Pixel operations (resize, greyscale, histogram, edge/Laplacian, hashing) use Accelerate/vImage and Core Image (optionally Metal Performance Shaders), which are fast and memory-light on Apple silicon.

## 2. Segment (shot / content-change detection)

Goal: split the timeline into **content segments**, each roughly one slide, one board state, or one screen.

Signals per adjacent scan-frame pair:

- **Perceptual hash distance.** Compute dHash and pHash (64-bit). Hamming distance between consecutive frames is the primary change signal (robust to compression noise, small motion).
- **Colour histogram correlation.** Cheap global change detector, catches fades and cut transitions the hash may smooth over.
- **Edge-map delta.** Ratio of changed edge pixels, sensitive to new text/strokes appearing while the background is static (writing on a board).

A segment boundary is declared when a weighted combination crosses an adaptive threshold, with hysteresis so a single noisy frame does not split a segment. A cheap hash-distance pre-pass over the coarse scan frames narrows the candidate boundaries before the finer signals run, to cut work.

Output: an ordered list of segments, each with `[startTime, endTime]` and its member scan-frames.

## 3. Score frames (per frame, within a segment)

Every scan-frame gets a vector of cheap, interpretable scores. No AI here.

| Score | How | Why |
| --- | --- | --- |
| **Sharpness** | Variance of the Laplacian (focus measure). | Reject motion blur and mid-transition smears. Higher is sharper. |
| **Ink / content density** | Fraction of "content" pixels: adaptive-threshold the frame, measure coverage of text/stroke-like pixels (edge density in the content region, excluding uniform background). | Proxy for "how much has been written/revealed". Rises as a board fills. |
| **Stability** | Inverse of pHash distance to the next N frames: how long the frame stays unchanged after this instant. | The finished state of a board/slide is stable right before it changes. Peaks mark "settled" moments. |
| **Occlusion** | Fraction of the content region covered by a person/hand, from Vision on-device person segmentation (`VNGeneratePersonSegmentationRequest`), with a cheap motion-blob fallback. | A presenter standing in front of the board ruins the frame. Prefer the clear view. |
| **Legibility** | Local contrast and estimated text-height in the content region. | Prefer frames where text is large and high-contrast enough to read/OCR. |
| **Content-type prior** | Fast classifier (aspect of layout, colour palette, straight-line density) giving a soft label: slide / board / code / document / chart / talking-head. | Talking-head-dominant frames are down-weighted to near zero; slide/board/code up-weighted. Also tunes later stages. |

All scores are normalised per segment so thresholds adapt to the lecture's own lighting and style.

## 4. Pick the keyframe for a segment (the "complete, not half-written" rule)

This is the heart of the user's request: *keep the frame where the content is finished, not mid-writing.*

Within a segment, define **content-completeness** as the point where ink/content density has plateaued near its segment maximum AND the frame is stable (about to change) AND sharp AND minimally occluded.

Algorithm (deterministic):

```
for each segment S:
    # 1. Build the ink-density curve over S's scan-frames.
    d[t] = ink_density(frame_t)                     # monotone-ish rising as content is added

    # 2. Find the "settle point": last time d is within P% of its
    #    segment max AND the frame is stable for the next W seconds
    #    (i.e. content stopped growing and hasn't been wiped yet).
    candidates = { t in S : d[t] >= P * max(d over S)
                            and stability[t] >= STABLE_MIN }

    # 3. Refine: re-extract full-rate frames in a small window around the
    #    best candidate and pick the locally sharpest, least-occluded one.
    t* = argmax over refine_window( w_sharp*sharp + w_leg*legibility
                                    - w_occ*occlusion + w_stab*stability )

    # 4. Reject the whole segment if the winner still looks unfinished or empty:
    if d[t*] < MIN_CONTENT or content_type(t*) == talking_head:
        drop segment
    else:
        keyframe(S) = full_res_extract(t*)
```

Key behaviours this produces:

- **Progressive whiteboard.** As the lecturer writes, `d` climbs. The instant they step back and start erasing or move to a new board, `d` for the old content stops climbing and the frame goes stable: that settled, full, unoccluded frame is chosen. Mid-writing frames (still climbing, hand in shot) are never chosen.
- **Animated / build slides.** A slide that reveals bullets one by one is one segment whose final built state has max density and is stable before the next slide: the complete build is chosen, not bullet 1 of 4.
- **Static slide.** Density is flat and high throughout; the sharpest, least-occluded instant wins.
- **Talking head between slides.** Low content density, non-slide content type: dropped.
- **Camera wobble / blur.** Low sharpness: never chosen even if timing is right.

Every parameter (P, W, STABLE_MIN, MIN_CONTENT, weights) has a per-content-type default and is exposed through the single "sensitivity" control in the UI (which scales the effective thresholds). Re-running selection at a new sensitivity is cheap: it reuses cached scores and only re-picks.

## 5. Deduplicate across the whole video

The same slide can appear in several segments (a presenter flips back; a board is left up during a tangent). After per-segment selection:

- Cluster keyframes by pHash Hamming distance with a union-find over a distance threshold, plus a structural check (same OCR-able text skeleton) to avoid merging two genuinely different slides that happen to share a template.
- Keep one representative per cluster: the highest combined sharpness + legibility + completeness score.
- Preserve order by earliest occurrence, but record the other timestamps (so a card can note "referred to again at 42:10").

Output of the deterministic core: an ordered, de-duplicated list of **keyframes**, each with timing, content type, and its score vector. This is the point where the model layer takes over. Typically 20–60 keyframes from an hour of video.

## 6. Transcribe and align

- Transcript source, in priority order: user-provided caption file (`.srt`/`.vtt`) ▶ on-device (bundled whisper.cpp, or the Speech framework `SFSpeechRecognizer`), offline by default ▶ provider transcription API (if configured for speed/quality).
- Output is word- or phrase-level timestamped text with detected language.
- **Alignment.** For each keyframe with time window `[start, end]` (its segment span), gather the transcript spanning that window plus a small lead-in (speakers usually explain a slide just before and during it). This aligned snippet is the language grounding for understanding and notes.

## 7. Understanding: OCR plus structure (per keyframe)

On-device Vision OCR (`VNRecognizeTextRequest`) first extracts the on-screen text for free and offline. Then one structured VLM call per keyframe (batched with bounded concurrency), grounded by that OCR text and the aligned transcript, adds the semantic layer. Understanding returns a typed object, not prose:

```jsonc
{
  "title": "Backpropagation: the chain rule over layers",
  "contentType": "board",            // confirms/overrides the deterministic prior
  "onScreenText": ["dL/dw = ...", "delta^l = ..."],   // from on-device Vision OCR
  "isComplete": true,                 // final completeness gate; can veto a frame
  "visualKind": "diagram|chart|formula|table|timeline|illustration|text-only",
  "structure": {                      // present when visualKind is structured
     "kind": "graph",
     "nodes": [ ... ], "edges": [ ... ], "labels": [ ... ], "layoutHint": "left-to-right"
  },
  "formulas": ["\\frac{\\partial L}{\\partial w} = ..."],  // LaTeX
  "keyTerms": ["gradient", "chain rule", "activation"],
  "confidence": 0.0-1.0
}
```

Notes on the design:

- **`isComplete` is a second, semantic gate.** The deterministic stage rejects frames that look unfinished; the vision model can still veto a frame it can tell is mid-thought (e.g. a sentence trailing off). Vetoed frames are dropped or merged into the neighbouring card.
- **`structure` is the bridge to original illustrations.** When the visual is structured, the model returns its *logical structure* (what connects to what, axis labels, series values), not a description of the pixels. That structure is what the sketch engine redraws. This is what makes the illustration original and exact rather than a copy.
- **Spend only where needed.** Text-only frames whose OCR is confident skip the VLM call entirely (on-device OCR is enough). Keyframes are downscaled before upload (long edge tuned per provider), never sent full-res. Simple frames are batched into one call, and routing is tiered: a cheap model triages, the strong model handles only complex diagrams. With no key at all, OCR plus transcript still yields notes.
- **Content is evidence, not instructions.** OCR text and transcript are wrapped as untrusted data; the model is told to ignore any directives inside them, is given no tools or network, and can only return the schema. The exact request/response contracts (schemas, prompts, injection defences) live in `PROMPTS.md`; the threat model is in `SECURITY.md`.
- Everything is cached keyed by `hash(keyframe pixels + transcript snippet + prompt version)`.

## 8. Note generation (per card)

One language call per card (or small batches for cross-card consistency), given: the vision `understanding`, the aligned transcript snippet, the titles of the previous and next cards (for flow and no-repeat), and the user's density setting.

Output is structured, not a blob:

```jsonc
{
  "heading": "Backpropagation",
  "points": ["...", "...", "..."],          // 3-7 concise bullets
  "definitions": [{ "term": "gradient", "def": "..." }],
  "formulas": ["\\nabla_w L = ..."],        // rendered with SwiftMath
  "steps": ["1 ...", "2 ...", "3 ..."],     // when a procedure/derivation
  "whyItMatters": "One line, optional",
  "sourceTags": { "fromSpeech": [...], "fromSlide": [...] },  // optional provenance
  "flags": ["check: value of eta unclear"]  // uncertainty, never invention
}
```

Faithfulness rules baked into the prompt and validated by the deterministic post-check:

- No claim may appear that is not supported by the frame text/structure or the transcript snippet. A lightweight check flags bullets whose key terms appear in neither source.
- Formulas are carried through as LaTeX from the vision stage where possible, not re-typed from memory.
- Terms already defined in an earlier card are not redefined (a running glossary set is threaded through).

## 9. Sketch engine (original illustrations)

The rule from the brief: **the app draws its own image, original, not a direct copy.** The engine picks the cheapest mode that is exact, and only falls back to generative art for genuinely pictorial content.

### 9.1 Mode selection

| `visualKind` from vision | Illustration mode | Renderer |
| --- | --- | --- |
| graph / flowchart / tree / cycle / mind-map / state machine | **Vector reconstruction** | Build a graph model from `structure`, lay it out (a Swift layered-graph layout), render with Core Graphics, then apply a hand-drawn "study sketch" finish. |
| bar / line / scatter / pie chart | **Vector chart** | Re-plot the extracted series/values with a charting layer, sketch-styled. Exact axes and labels. |
| table / matrix | **Vector table** | Re-typeset the table from extracted cells. |
| timeline / process | **Vector timeline** | Deterministic timeline layout from ordered items. |
| Venn / set relationships | **Vector Venn** | Circles and regions from the extracted set relations. |
| sequence / UML / ER diagram | **Vector diagram** | Lifelines, boxes, and relations from the extracted structure. |
| circuit / schematic | **Vector schematic** | Components and wires from a netlist-like structure. |
| chemical structure | **Vector structure** | Atoms and bonds from the extracted graph. |
| simple map / spatial | **Vector map** | Labelled regions and points from the layout. |
| formula / derivation | **Typeset math** | SwiftMath (LaTeX to Core Text) to crisp vector math. No image model needed. |
| illustration / physical setup / metaphor / anatomy | **Generative sketch** | Prompt the connected image model to draw an original line-art illustration in the house style, from the concept description (never "copy this frame"). |
| text-only slide | **No illustration** | The notes are the content; optionally a small dim source thumbnail. |

Most lecture visuals (diagrams, charts, formulas, tables) are structured, so most illustrations are exact vector redraws: original, editable, crisp at any export size, and free of model image cost. Generative art is reserved for the minority of truly pictorial concepts.

### 9.2 The house style ("study sketch")

- One `StyleToken` per Study Set fixes: stroke weight and slight roughness (a Core Graphics stroke-perturbation pass gives the hand-drawn look), palette (2 to 3 accent inks on paper), corner radius, font for labels, and fill hatching. Every vector illustration in the set is rendered through it, so the notebook looks coherent.
- For generative illustrations, the same StyleToken is expressed as a fixed style prefix in the image prompt (line art, limited ink palette, no text baked in), and any labels are overlaid as real vector text afterwards so they stay sharp and correct (models are unreliable at text-in-image).
- Themes: `ink on paper` (default), `blueprint`, `mono`, `high-contrast`. Chosen at Study-Set level, restylable in one action.

### 9.3 Accuracy safeguards

- Vector reconstructions are generated from the extracted structure, so labels, directions, and quantities are exactly what the model read from the frame (and the user can correct a mislabel once and it stays fixed).
- Generative illustrations get an automatic verification pass: the same vision model checks the produced image against the intended concept and label list, and regenerates if it drifted or introduced wrong text.
- Labels on generative art are always overlaid as vector text, never trusted to the image model.

## 10. Assemble the Study Set

Deterministic:

- Order cards by first occurrence.
- Group into sections: detect topic shifts from card titles/key-term clustering and (if present) the lecture's own slide-section cues, producing chapter headings.
- Generate front matter (title, summary, TOC) and back matter (glossary from all `definitions`, quiz/flashcards from points + definitions).
- Produce the in-memory `StudySet` model that every exporter consumes (see `ARCHITECTURE.md` §Data model).

## 11. Determinism, caching, resumability

- Stages 1–5 and 10 are pure functions of `(video bytes, settings)`. Same input, same keyframes, every time. This is what makes the engine unit-testable on fixtures. Scoring is pinned to a deterministic path (fixed precision, tolerance-bucketed thresholds) so GPU vs CPU differences across devices cannot change which frames are selected.
- Each AI stage caches by content hash. Editing a note or restyling illustrations never re-runs vision; re-exporting never re-runs anything.
- A run journal records the last completed stage per keyframe, so a crash or quit resumes without redoing finished work (mirrors the checkpoint pattern in Luke's other apps).

## 12. What gets unit-tested (see `TESTING` in ARCHITECTURE.md)

- Scene segmentation on synthetic frame sequences (known boundaries).
- pHash/dHash correctness and dedup clustering.
- Sharpness, ink-density, stability, occlusion scorers on crafted frames (blurred, half-written, occluded, finished).
- The keyframe picker on a scripted "whiteboard fills then erases" sequence: asserts it picks the finished-before-erase frame.
- Dedup on a "slide shown twice" sequence: asserts one representative.
- Study Set assembly and every exporter against golden fixtures.
- The vector sketch renderers (graph, chart, table, timeline, formula) against golden PDF/SVG output.

## 13. Multi-input fusion (optional attachments)

When the user attaches the source deck (PDF, PPTX, Keynote) and/or a transcript, the engine fuses them for exactness. Attachments are content, never instructions (`SECURITY.md`).

- **Slide extraction.** Parse the deck into per-slide text, vector shapes, and images (PDFKit / OOXML). This is ground-truth text and real vector structure, with no OCR error.
- **Keyframe-to-slide alignment.** Match each kept keyframe to its slide by visual similarity (pHash + layout + text overlap), producing a per-card slide reference, robust to the video showing a slide cropped, zoomed, or at an angle.
- **Fusion rules.** Where a keyframe matches a slide, use the slide's exact text and redraw the illustration from the slide's real vector structure; the vision model becomes optional (used only to confirm the match, or skipped). Where there is no match (a live board, a demo), fall back to OCR and the normal path. A slide never shown becomes no card; a shown board with no slide is still a card. Fusion only improves accuracy; it never fabricates.
- **Payoff.** Near-perfect text, exact diagrams, and lower cost (fewer or no vision calls).

## 14. Robustness matrix

Every real-world pathology has a defined behaviour. No input crashes or silently returns nothing.

| Input pathology | Behaviour |
| --- | --- |
| Talking-head only (no slides/board) | Almost all frames dropped; the set is small or empty, the app says so and offers a transcript-only outline. |
| No audio | Visual-only notes from OCR/structure; no transcript grounding, flagged. |
| Non-English (zh/ja/de/...) | Transcription, understanding, notes, and export all in that language; correct CJK/RTL fonts in sketches and exports. |
| Portrait phone video / rotated | Orientation normalised from metadata before scoring. |
| Handwriting-only (tablet) | Treated as board content; completeness/stability picks settled strokes; OCR best-effort, structure where legible. |
| Code screencast | Code content type; monospaced formatting; scrolling code handled per segment (deep syntax handling is a later track). |
| Math-heavy | Formulas as LaTeX from OCR/structure, rendered with SwiftMath; derivations as steps. |
| Screen recording with cursor | Cursor motion ignored by scoring; not mistaken for content change. |
| Animations / video within slides | Treated as one evolving segment; the settled final state is kept. |
| Duplicate slides / flip-backs | Deduplicated to one representative, with back-references. |
| Uniformly low quality (blur, dim, compressed) | Best effort with a quality warning; thresholds adapt but never invent content. |
| Corrupt / unsupported file | Declined with a clear message; on macOS, optional ffmpeg fallback for unsupported containers. |
| DRM-protected source | Declined with an explanation; never bypassed. |
| Extremely long (2h+) | Chunked, checkpointed, memory-bounded, resumable; background on iOS. |

Each row is a fixture in `EVALUATION.md`; a bug found on a real lecture becomes a new row and a new fixture.
