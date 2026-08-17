<p align="center">
  <img src="assets/wordmark.svg" alt="VideoNotes" width="440">
</p>

<p align="center"><strong>Private, source-cited illustrated notes from video and audio.</strong></p>

VideoNotes is a native SwiftUI app for macOS, iPhone and iPad. It transcribes speech on device, reads on-screen text with Vision, traces selected source frames, structures the evidence into study notes, and exports the result without uploading the source media.

## Current features

- Video and audio import for MP4, MOV, M4V, MPEG, MP3, M4A, WAV, AIFF, AAC, FLAC and CAF sources.
- On-device Speech transcription and Vision OCR.
- Representative-scene selection with exact frame timestamps, face-aware illustration rejection, progressive-reveal handling and text/visual deduplication.
- Source-derived contour sketches. When a useful source image is unavailable, the renderer uses neutral decoration instead of inventing a diagram.
- Searchable Evidence Inspector with speech/OCR filters, source preview at the cited time and human correction followed by deterministic regeneration.
- Per-result grounding status, section citation coverage and explicit review labels for synthesized material.
- Accessible semantic Reading Mode with selectable text and source timestamps.
- Private, Keychain-backed AES-256-GCM project recovery that restores notes, evidence, style and page position without duplicating the source media.
- Measured continuation pages for unusually dense sections, preserving every semantic claim instead of clipping or truncating it.
- Tagged, Unicode-searchable illustrated PDFs with document metadata and a pixel-identical semantic text layer.
- Native Liquid Glass on macOS 26/iOS 26, material fallback on older systems, and accommodations for Reduce Motion, Reduce Transparency and Increase Contrast.
- Complete runtime string coverage in English and German, localized plural forms and speech-permission text, plus conservative on-device source-language metadata.

## Note presentation formats

All 14 formats are source-safe views of the same typed note model. Every format preserves every generated section exactly once; changing format can reorder or safely pair complete sections, but does not regenerate, replace or paraphrase their evidence.

| Format | Use case |
| --- | --- |
| Illustrated | Balanced cover-led visual notes with safe section pairing. |
| Detailed | One complete section per page for maximum room. |
| Condensed Review | Denser review pages that pair only sections proven to fit. |
| Evidence-First | Source-chronological sections without a synthesized cover. |
| Focus Cards | One original-order idea per card without a cover. |
| Quick Review | Compact, cover-free refresher. |
| Study Guide | Summaries and definitions first, followed by the complete lesson. |
| Cornell Notes | Source-provided definitions lead as cues, complete notes follow, and summaries close the set. |
| Hierarchical Outline | Complete concepts, definitions, methods, processes, comparisons, quotes and review are grouped by semantic level. |
| Timeline / Chapter Map | Dated sections follow source chronology; undated review material remains last. |
| Q&A Flashcards | Source-provided definitions and headings become study-card prompts without inventing questions. |
| Exam Revision | Summaries, definitions and comparisons lead, followed by all remaining source material. |
| Tutorial / Step-by-Step | Source-provided processes and methods lead; every other section remains ordered reference material. |
| Decisions & Action Items | Source-provided comparisons and procedures lead without inventing decisions, commitments or tasks. |

PDF output supports Digital 9:16, A4 and US Letter page sizes. Illustrated PDFs include searchable semantic text, source timestamps, accessibility tags and document metadata. Decorative illustrated text is excluded from the reading structure while the invisible source-ordered layer supplies tagged headings, paragraphs and `ActualText`, avoiding duplicate or conflicting accessibility content.

Additional outputs are full-resolution PNG pages, Markdown, plain text, accessible styled HTML and structured JSON. JSON is a versioned typed interchange format rather than a page-oriented summary: it preserves document title, subtitle, language, source/provenance fields, hero sketch and every `NoteSection` payload, and can reconstruct the exact source semantic document. HTML uses appropriate section, article, list, table, quotation/citation and definition-list elements. Markdown neutralizes raw HTML and escapes headings, inline syntax and table delimiters from source content. These four semantic exports are derived directly from the typed document and remain available when visual or PDF rendering fails or is still unavailable.

## Accuracy model

VideoNotes treats extracted material as evidence, not decoration:

- The same OCR words on different visuals are retained; nearby visually matching duplicates are removed.
- Repeated course/app headers are grouped instead of creating one topic per frame.
- Narrated spans do not promote unrelated menus, file paths or partial UI labels into instructional steps.
- Talking heads can contribute captions but cannot become illustrations.
- Hero sketches must come from the opening source context.
- Every cited page uses the actual returned frame or transcript time.
- Synthesized summaries are labeled `SYNTHESIZED REVIEW` and surfaced as requiring review.

OCR, speech recognition and contour tracing remain fallible. The Evidence Inspector and citation coverage are part of the product's trust workflow.

## Build and test

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate
swift test --package-path Engine --parallel
xcodebuild -project VideoNotes.xcodeproj -scheme VideoNotes-macOS -destination 'platform=macOS' test
xcodebuild -project VideoNotes.xcodeproj -scheme VideoNotes-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
xcodebuild -project VideoNotes.xcodeproj -scheme VideoNotes-iOS-UI -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
xcodebuild -project VideoNotes.xcodeproj -scheme VideoNotes-macOS-UI -destination 'platform=macOS' build-for-testing
```

The current source suite contains 77 engine tests, 46 app-hosted tests for each platform, and four UI tests. It covers every 14-presentation-format × 3-PDF-size combination, source-safe specialized ordering, dense continuation, Unicode PDF search, tagged-PDF structure, semantic-layer pixel identity, grounding provenance, localization, stale visual-export prevention, typed semantic round-trip and validation, Markdown/HTML safety, encrypted recovery and StoreKit behavior/configuration. These counts describe the current inventory pending the final integrated rerun; they are not a substitute for its result. The four matching macOS UI tests compile with `build-for-testing`; executing them still requires Xcode/XCTRunner Accessibility authorization on the host Mac.

`scripts/ci-verify.sh` reproduces the engine, app, iOS UI, Release-build, analyzer and StoreKit-fixture-leakage checks while compiling the macOS UI runner. Swift and compiler warnings are errors throughout the gate. App-hosted unit tests run serially with one worker—including the macOS suite—to avoid shared app-state interference. The pinned GitHub workflow invokes that script, but it cannot gate commits until this directory is placed under version control and the workflow is activated on a repository runner.

## Project layout

- `App/Sources`: universal SwiftUI interface, StoreKit access, app state and exports.
- `App/Tests`: macOS/iOS app-hosted unit tests.
- `Engine/Sources/SketchnoteEngine`: extraction, structuring, planning and rendering.
- `Engine/Tests`: deterministic accuracy, planning and export tests.
- `docs`: architecture, design, evaluation, security and audit records.

## Release status

The quality gate is configured for warnings-as-errors macOS/iOS Release builds and both static analyzers. The latest 14-format and typed-export changes still require the final integrated rerun before they can be treated as a release candidate. The last inspected Release bundles contained English and German localization products, privacy manifests, app assets and licensed fonts, and excluded the test-only StoreKit fixture; fresh bundle inspection remains part of that rerun. The checked-in App Store archives and screenshots are obsolete and must not be shipped.

Before a commercial release, the remaining gates are: a legally clean labelled real-video corpus; App Store Connect/Sandbox lifecycle testing; fresh signed archives and store media; long-duration physical-device testing; hands-on VoiceOver and macOS automation-permission coverage; localized legal review; and activating the checked-in CI workflow in version control. See the audit for the exact evidence still required; local tests cannot guarantee external App Store conditions or every real media file.

See [docs/AUDIT-5.md](docs/AUDIT-5.md) for the latest implementation audit and verification record.

## Brand assets

The current marks live in `assets/logo.svg`, `assets/logo-mark.svg` and `assets/wordmark.svg`. Classic variants are retained with the `-classic` suffix.
