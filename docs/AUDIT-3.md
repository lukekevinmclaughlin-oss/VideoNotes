# VideoNotes — Product, UX and Accuracy Audit (2026 polish pass)

> Historical record: this pass has been superseded by `AUDIT-4.md`. Its 96-scene and 28-test figures describe the earlier implementation, not the current build.

## Implemented in this pass

### Accuracy and trust

- Replaced sparse fixed-interval frame extraction with two-pass scene selection. A lightweight full-timeline pass finds visual changes; OCR and contour tracing then run on up to 96 representative scenes.
- Preserved the opening and closing context and prioritised high-change scenes while spacing selections so transitions cannot consume the keyframe budget.
- Kept real video-derived sketches on process and comparison pages. Those layouts previously discarded the source sketch and could fall back to generic icons.
- Removed OCR-recognised text regions from contour art. Text remains typeset from OCR, while traces focus on the source diagram or object instead of drawing malformed letter outlines.
- Added source timestamps to generated pages for provenance and fast verification against the video.
- Added a visible grounding report showing speech-segment and key-scene evidence. The app no longer presents every result with the same implied confidence.
- Added a searchable source-evidence inspector with timestamped speech and OCR, copyable text, evidence filters and trace indicators.
- Enabled automatic OCR language detection and used technical vocabulary from the transcript as contextual recognition hints.
- Increased long-lecture probe coverage and added fuzzy OCR deduplication so minor recognition fluctuations do not create duplicate pages.
- Added deterministic tests for scene selection and retained the existing deterministic rendering/export suite.

### UI and UX

- Deepened the liquid-glass system with specular highlights, inner rims, layered shadows, gradient primary controls and a richer two-axis HUD grid.
- Added responsive header variants and compact import labelling for narrow windows and iPhone.
- Made the result header responsive and added concise evidence pills for grounding quality.
- Made the complete style/export toolbar horizontally scrollable on compact devices.
- Hid the platform scrollbar in the page gallery while preserving snapping, keyboard navigation, page dots, hover tilt, zoom and reduced-motion support.
- Retained clear analysis stages, cancellation, drag-and-drop, keyboard shortcuts and export feedback.

## Recommended next investments

1. Add a user-review screen for transcript/OCR corrections before rendering. This is the highest-value next accuracy feature because no OCR or speech model is perfect.
2. Add optional source-deck import (PDF/PPTX) and align slides to the video. Exact source text and vectors will outperform any screenshot reconstruction.
3. Extend the evidence inspector with stored source-frame thumbnails and direct seek-to-time playback.
4. Add subject-aware renderers for equations, code, charts and chemistry rather than treating every visual as a generic contour sketch.
5. Build the fixture corpus described in `EVALUATION.md` and gate releases on scene-selection F1, completeness, OCR word error rate and unsupported-claim rate.
6. Add resumable processing and a queue for long lectures, including thermal and memory safeguards on iPhone.
7. Add editable notes, page reordering and per-page regeneration using only that page's cited evidence.

## Verification

- Engine: 28 XCTest cases passing.
- macOS application: Debug build succeeds; empty and generated-results states visually inspected.
- iOS application: generic iOS Simulator build succeeds.
- Synthetic three-scene fixture: three distinct scenes selected, four grounded pages rendered, source timestamps present, and text contours excluded from visual art.
