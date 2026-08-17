# VideoNotes: Audit, Round 2

The first audit (`AUDIT.md`) covered product, UX, and the design overhaul. This round goes after the things that decide whether the notes are actually trustworthy and whether the app survives real lectures: the model contracts, how quality is measured, security against content-borne prompt injection, robustness on messy inputs, and getting exact data when the source deck is available.

Priorities: **P0** shippable-quality gap, **P1** high value, **P2** nice to have, **P3** future. Status: applied to the specs this pass, or logged as backlog.

---

## Summary: what changed in this pass

1. **Model contracts pinned** (`PROMPTS.md`): exact JSON schemas for understanding and notes, grounding rules, faithfulness constraints, tutor/translation/sketch/verification prompts, determinism and cost mechanics. Quality stops being incidental.
2. **Evaluation harness** (`EVALUATION.md`): a fixture corpus, deterministic CI-gated metrics (selection F1, completeness, dedup, export validity) and pinned, human-calibrated model-eval (faithfulness via adversarial judge panels), with explicit release gates. "High quality" is now measured and gated.
3. **Security and prompt-injection threat model** (`SECURITY.md`): treats all lecture content as untrusted data, gives the note models no tools/network/cross-project access, confines output to a schema, and never fetches or executes content. This is the novel risk for AI note apps and it is now designed against.
4. **Robustness matrix** (`ENGINE.md` §14): every real-world pathology (talking-head-only, no audio, non-English, portrait, handwriting, code, math, cursor, animations, corrupt, DRM, 2h+) has a defined behaviour; each becomes a fixture.
5. **Multi-input fusion** (`ENGINE.md` §13, SPEC 6.17): attach the source deck and/or transcript; align keyframes to slides for exact text and real vector diagrams, removing OCR error and cutting cost.
6. **Broader sketch taxonomy**: Venn, sequence/UML, ER, circuit, chemistry, map added to the vector reconstructors.
7. **Sync, telemetry, and voice** (SPEC 6.19): iCloud sync with safe conflict resolution, opt-in content-free telemetry, and an explicit product voice.

## Quality and trust

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| Q1 | Note/understanding output was described by shape but not pinned; quality would drift per model and prompt. | Pin exact schemas, grounding, and faithfulness rules; version them into cache keys. | P0 | Applied (`PROMPTS.md`) |
| Q2 | "High quality" was asserted, not measured. | A real eval harness with fixtures, metrics, judge panels, and release gates. | P0 | Applied (`EVALUATION.md`) |
| Q3 | Faithfulness relied on a prompt instruction. | Deterministic support-check per claim + adversarial judge panel in eval; provenance tags surfaced. | P1 | Applied (`PROMPTS.md` §4, `EVALUATION.md`) |
| Q4 | Generative sketches could be confidently wrong. | Verification pass + label-overlay-as-vector + fallback; measured regenerate rate. | P1 | Applied (`PROMPTS.md` §3) |

## Security and privacy

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| S1 | The whole app feeds untrusted lecture text to LLMs; a slide could carry a prompt-injection payload. This was unaddressed. | Full threat model: content is data not commands, no tools/network/cross-project access to note models, schema-confined output, no fetch/execute of content. | P0 | Applied (`SECURITY.md`, `PROMPTS.md` §7) |
| S2 | Egress boundaries were stated but not modelled. | Explicit data-egress rules, redaction, privacy dashboard tie-in; endpoints never chosen by content. | P1 | Applied (`SECURITY.md` T2) |
| S3 | Malicious media, key handling, supply chain, at-rest, sync, export-rendering safety unlisted. | Enumerated with mitigations. | P1 | Applied (`SECURITY.md` T3-T8) |

## Robustness and correctness

| # | Finding | Recommendation | Pri | Status |
| --- | --- | --- | --- | --- |
| R1 | No defined behaviour for the messy real inputs a lecture app hits. | A robustness matrix with a defined outcome per pathology; each is a fixture. | P1 | Applied (`ENGINE.md` §14, SPEC 6.18) |
| R2 | When the source deck exists, OCR error and inexact diagrams were accepted. | Multi-input fusion: align frames to slides, use exact text and real vectors. | P1 | Applied (`ENGINE.md` §13, SPEC 6.17) |
| R3 | Sketch taxonomy was narrow (missed Venn, UML, ER, circuit, chemistry, maps). | Expanded the vector reconstructor taxonomy. | P2 | Applied (`ENGINE.md` §9) |
| R4 | No multi-device story; conflict semantics undefined. | iCloud sync as a document with card-level conflict resolution, no lossy merges. | P2 | Applied (SPEC 6.19, `ARCHITECTURE.md` §6) |

## Backlog (not applied this pass)

- Code-lecture depth (syntax highlight, scrolling-code stitch), cross-segment slide-evolution merge, speaker diarization (carried from `AUDIT.md`).
- Automatic difficulty/level tagging of cards; per-subject note templates (a proof vs a data table vs a process).
- A shared, opt-in fixture-contribution flow so real failing lectures improve the eval corpus over time.
- Course workspace, processing queue, managed-credit Pro (carried from `AUDIT.md`).
