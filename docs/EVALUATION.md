# VideoNotes: Evaluation Harness

"Frontier-quality study notes" is a claim that has to be measured, or it is just marketing. This defines the fixtures, metrics, methods, and release gates that keep VideoNotes honest as it evolves. It pairs with `ENGINE.md` (what is being measured), `PROMPTS.md` (the contracts under test), and `SPEC.md` §9 (the quality bar these metrics operationalise).

Two tiers of evaluation are documented, but only the implemented deterministic checks apply to the current on-device product:

- **Deterministic checks** run offline with no models. The current source inventory contains 77 engine tests, 46 app tests for each platform and four UI tests; final integrated results for the expanded inventory are pending. `scripts/ci-verify.sh` also compiles the macOS UI runner, builds both Release products, runs both analyzers and checks for StoreKit-fixture leakage. Xcode warnings are errors and app-hosted unit tests use a single serial worker. A pinned workflow is checked in, but these checks do not yet gate commits because this directory is not currently under version control.
- **Future model eval** describes the evidence required if a generative understanding or illustration backend is ever introduced. The current app does not call one and must not claim those future measurements as shipped behavior.

## Implemented provenance gate

`GroundingAuditor` now verifies every source illustration without inference:

- A section drawing passes provenance only when its complete stroke payload exactly equals a traced `VisualMoment` from the imported video.
- It passes relevance only when that exact source moment is also within the section citation tolerance.
- Hero art must be an exact source trace from the shared strict opening window; later B-roll cannot pass as a cover image.
- A plausible, visually similar or generated drawing is deliberately treated as ungrounded.

The app surfaces the verified/total drawing count. The engine tests cover aligned, wrong-scene, fabricated and late-hero cases. `sketchnote-cli` writes `grounding-audit.json` and fails before rendering when strict illustration grounding is false. This is the current release-blocking answer to “no random images”; broader semantic fixture evaluation remains required below.

---

## 1. Required fixture corpus — not yet assembled

The required corpus is a versioned, hand-labelled set of short clips (mostly 2 to 8 minutes) spanning the real pathologies of lecture video. It should remain small enough to run often and broad enough to be representative.

| Category | What it stresses |
| --- | --- |
| Slide deck (screen capture) | Clean text, builds/animations, duplicate slides |
| Whiteboard / chalkboard | Progressive writing, erase cycles, occlusion, glare |
| Handwritten tablet (Notability-style) | Ink strokes, incremental reveal, no distinct "slides" |
| Code screencast | Scrolling code, terminal, small fonts, syntax |
| Math-heavy | Dense LaTeX, multi-line derivations |
| Talking-head with occasional slides | Mostly rejectable frames, sparse keepers |
| Non-English (zh, ja, de) | Transcription, CJK OCR, correct label fonts |
| Low quality (compressed, shaky, dim) | Blur/sharpness, legibility floors |
| Slides-attached (future input mode) | Multi-input fusion if source PDF/PPTX import is implemented; this is not a current app capability |

Each future fixture must ship ground truth: the expected kept keyframes (timestamps with tolerance), expected content types, reference OCR text, and a reference rubric for notes (the key concepts that must appear, the definitions expected, and any formulas). Ground truth must be versioned alongside the fixtures.

## 2. Metrics

### 2.1 Selection (deterministic, corpus-dependent release gate)

- **Precision / recall / F1** of kept keyframes vs ground truth, matched with a temporal tolerance and dedup-aware pairing (a kept frame within tolerance of a labelled keeper counts once).
- **Completeness accuracy**: of the segments with progressive content, the fraction where the chosen frame is the finished (pre-erase, fully-built) state. This is the headline metric for the core promise.
- **Junk rate** (false keeps: talking-head, blur, transitional) and **miss rate** (concepts with no card).
- **Dedup correctness**: no near-duplicate cards; no false-merge of genuinely different slides.
- **Stability**: same fixture, same settings, byte-identical keyframe selection across runs and across CPU/GPU paths (guards the deterministic-scoring pin).

### 2.2 Understanding (corpus-dependent; not yet measured across the required fixture set)

- **OCR word error rate** on `onScreenText` vs reference (on-device OCR is the text source; this measures the correction step does not degrade it).
- **Structure accuracy**: node/edge/label F1 for reconstructed diagrams; axis/series correctness for charts.
- **visualKind accuracy**: classification vs labelled kind.
- **isComplete gate**: precision/recall of the semantic completeness veto.

### 2.3 Notes (corpus-dependent trust metrics)

- **Faithfulness** (primary): a source-evidence review attempts to find any claim in the notes not supported by frame text/structure or transcript evidence. Score = fraction of cards with zero unsupported claims. Human labels are required for the release corpus; a calibrated judge panel is optional only if a future model-evaluation job is introduced.
- **Coverage**: fraction of the reference rubric's key concepts and definitions present.
- **Presentation integrity**: all 14 presentation formats retain every typed section exactly once. Specialized ranking may change order and measured pairing may change pagination, but no format may invent questions, decisions, actions or other unsupported claims.
- **Formula correctness**: LaTeX renders and matches reference (normalised).
- **Conciseness / no-repeat**: length within density band; no definition repeated across cards.

### 2.4 Illustration (implemented deterministic provenance plus future corpus metrics)

- **Exact source provenance** (implemented and test-gated): every used sketch exactly matches a traced source moment; fabricated count is zero.
- **Temporal relevance** (implemented and test-gated): every section sketch matches the source moment at its own citation; late hero art is rejected.
- **Future structured-diagram fidelity**: if structured diagram reconstruction is added, output must match golden PDF/SVG for fixed structures. This is not a current renderer claim.
- **Future label accuracy**: if structured diagrams are added, every reconstructed label must be present and correct.
- **Future generative accuracy**: if generative art is ever added, a judge pass must verify it depicts the intended concept with no wrong text; until then generated art must never be presented as source evidence.
- **Style consistency target**: source-derived sketches and renderer decoration remain within the selected palette/stroke system; representative corpus-wide scoring is not yet implemented.

### 2.5 Export (implemented deterministic checks plus future fixture baselines)

- **Validity**: every currently implemented export opens or parses: tagged PDF, PNG pages, Markdown, plain text, accessible HTML and versioned typed JSON. DOCX, PPTX, EPUB and Anki/APKG are not current formats and must be added to both the implementation and this gate before they can be claimed.
- **Typed interchange integrity**: JSON must retain schema version, document title/subtitle/language, source and evidence provenance, presentation identifier, hero/source sketches and every field of each `NoteSection`. Decoding must reject unknown versions or contradictory review metadata and reconstruct the exact original semantic document.
- **Text safety and semantics**: Markdown must neutralize raw HTML and escape syntax/table delimiters from evidence. HTML must escape source content and use typed section, article, list, table, quotation/citation and definition-list elements with appropriate language metadata.
- **Failure independence**: Markdown, text, HTML and JSON are derived from the typed note document and must remain exportable when visual/PDF output is unavailable; only PDF and PNG depend on successful visual rendering.
- **Current PDF fidelity checks**: the matrix spans all 14 presentation formats × 3 paper sizes. Tests inspect media boxes/page counts, Unicode extraction, `MarkInfo`, semantic-layer pixel identity and document metadata. Decorative Core Text is marked non-structure before drawing, while the invisible source-ordered layer carries explicit heading/paragraph tags and `ActualText`.
- **Pending fidelity gate**: add corpus-backed PDF/HTML golden comparisons with an explicit pixel-delta threshold. Formula and structured-vector checks apply only if those capabilities are implemented.

### 2.6 Performance and resource use (required device measurements; not complete)

- Wall-clock per stage and end to end, per device class (Mac, iPad, iPhone), against the SPEC targets.
- Peak memory per input length; thermal behaviour on iOS for a 2-hour input.
- CPU time, energy and local-storage growth per hour of media. The current pipeline has no per-video provider-token cost; token and routing-tier measurements apply only if a future remote model backend is introduced.

## 3. Method

- **Implemented deterministic checks** run in XCTest without a model or external network dependency. `scripts/ci-verify.sh` is the reproducible local/runner entry point. It treats warnings as errors across Xcode test/build/analyze steps and disables parallel app-unit execution with one worker, including for macOS. The checked-in workflow will make failures block commits or pull requests only after version control and a runner are configured.
- **Future model metrics**, if a model backend is introduced, would run in a separate job with pinned model ids and near-zero temperature, on demand and before releases. Judges would use a rubric and self-consistency; results would carry confidence intervals from repeated runs.
- **Future LLM-judge calibration** would require a rotating human panel to rate a random subsample each cycle. A judge must never become the only arbiter of a faithfulness release gate without periodic human calibration.
- **Reporting target**: once the legally clean corpus and release infrastructure exist, retain per-category results and trend them over time. No evaluation dashboard is implemented today.

## 4. Release gates

Once the labelled corpus and baseline exist, a release is blocked if any of these regress beyond tolerance versus the last release baseline:

- Selection F1 or completeness accuracy on the fixture corpus.
- Note faithfulness (zero-unsupported-claim rate).
- Export validity (any format fails to open).
- Performance targets (scan time, memory ceiling) on the reference devices.

Once the corpus and reporting infrastructure exist, secondary tracked metrics should include coverage and applicable structure accuracy. Generative accuracy and provider cost apply only if a generative backend is added.

Until that corpus exists, the absence of those measurements is itself an external release gate; the focused automated regressions must not be presented as representative accuracy proof for every media category.

## 5. Maintenance

- Fixtures and ground truth must be versioned; adding a new failure mode to the corpus should be the standard response to a real-world bug ("this lecture broke it" becomes a fixture).
- Any future prompt or model change must rebaseline model-eval metrics deliberately, with the change and metric delta recorded.
- The corpus must stay legally clean: self-recorded or public-domain/licensed clips only.

---

The current automated suite is designed to verify focused invariants such as exact illustration provenance, evidence timing, lossless layout continuation and export structure; the expanded inventory still needs its final integrated run. The broader SPEC metrics—selection precision/recall, completeness, corpus-wide faithfulness, time saved and representative export fidelity—become defensible shipment gates only after the labelled corpus, baselines and active CI reporting described above are in place.
