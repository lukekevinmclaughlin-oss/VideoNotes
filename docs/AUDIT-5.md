# VideoNotes — Commercial-Quality Audit and Upgrade Pass

Date: 13 July 2026  
Status: latest format/export implementation documented; integrated rerun pending; external shipment gates remain

## Outcome

This pass audited the extraction engine, note structure, illustration grounding, rendering, export pipeline, SwiftUI interaction model, accessibility, StoreKit presentation, build configuration and checked-in distribution assets.

The largest user-visible additions are 14 evidence-preserving note layouts, three PDF page formats, four semantic export formats, local project recovery and native OS 26 Liquid Glass. The largest correctness changes are stricter agreement between speech, OCR and source frames, measured continuation pages and a versioned typed interchange model: repeated app/deck chrome is grouped, narrated videos no longer promote unrelated UI labels into lesson steps, sparse narration is never padded with noisy OCR, unusually dense note sections are never clipped, and semantic JSON preserves the typed document instead of reducing it to rendered-page summaries.

## Implemented improvements

### Source accuracy and illustration relevance

- OCR deduplication now requires textual and visual agreement. Identical text over different diagrams is retained; exact nearby duplicates and visually matching progressive reveals are consolidated.
- Prefix-like slides merge only when adjacent, nearby and visually similar.
- Captioned face-dominant frames retain OCR but cannot become page illustrations.
- Repeated deck/app titles such as “Studio” and “Desktop” no longer fragment a short video into one section per sampled frame.
- Continuous short narration is grouped into a small number of useful topics rather than a single page or a page per sentence.
- Repeated visual headers defer to transcript-derived topic headings while preserving the exact frame and timestamp.
- File paths, ellipsized controls, status fragments and unsupported navigation labels are filtered as interface chrome.
- Numbered OCR becomes a narrated process only when its claims overlap the speech in that topic. Visual-only numbered slides remain supported.
- Narrated concepts are never padded with OCR to reach a desired bullet count.
- The selected OCR heading itself is removed from section points, even when Vision did not return it first.
- Hero art can only use an opening source sketch; late titled frames cannot be borrowed as cover art.
- `GroundingAuditor` proves every used sketch is an exact traced-stroke match to the imported video and is temporally aligned with that section's citation. Visual similarity alone cannot pass.
- The same strict opening-window rule is shared by hero selection and auditing, preventing selection/audit drift.
- The studio surfaces the verified/total source-drawing count; unverified or wrong-scene art becomes a review warning.
- The development CLI emits `grounding-audit.json` and fails when any illustration is fabricated, temporally mismatched or borrowed from later B-roll.
- Paired-section connectors are neutral marks rather than an invented semantic relationship.
- Missing-time summaries are labeled `SYNTHESIZED REVIEW`.

### Formats and exports

- Added 14 source-safe layouts: Illustrated, Detailed, Condensed Review, Evidence-First, Focus Cards, Quick Review, Study Guide, Cornell Notes, Hierarchical Outline, Timeline / Chapter Map, Q&A Flashcards, Exam Revision, Tutorial / Step-by-Step and Decisions & Action Items.
- Every layout retains every note section exactly once. Specialized layouts use stable semantic ranking and measured pairing only: flashcards never invent questions, and decisions/action views never invent decisions, commitments or tasks.
- Added Digital 9:16, A4 and US Letter PDF sizes with centered aspect-fit artwork.
- Illustrated PDFs now carry document-info and XMP metadata, accessibility tags and invisible Unicode semantic text for every section and source timestamp.
- PDF tagging begins before any decorative Core Text is drawn: illustrated content is wrapped as non-structure, while the invisible source-ordered layer carries tagged headings/paragraphs with `ActualText`. This prevents legacy Core Text tags from conflicting with the explicit accessibility tree.
- The semantic PDF layer rasterizes pixel-for-pixel identically to the visual-only document while remaining searchable and extractable.
- Added Markdown, plain-text, styled accessible HTML and versioned typed JSON exports alongside PDF, PNG and Reading Mode.
- Semantic exports include evidence timestamps and explicit review warnings for uncited pages.
- The JSON envelope preserves schema version, source label, document title/subtitle/language, stable presentation identifier, evidence coverage, hero sketch, source times, review flags, source sketches and every field of every typed `NoteSection` variant. Decoding validates the schema, indexes and review invariants and reconstructs the exact original `NoteDocument`.
- HTML escapes source text and uses semantic `<section>`, `<article>`, heading, list, table, `<blockquote>/<cite>` and `<dl>/<dt>/<dd>` structures with language attributes. Markdown neutralizes raw HTML and escapes headings, inline syntax, multiline content and table delimiters.
- Semantic export readiness depends only on the typed document, not rendered images or a PDF URL. If visual rendering fails, the failure state retains Markdown, text, HTML and JSON export while the user retries the visual layout.
- PDF and PNG export are disabled while a new style/format is rendering, preventing stale output.
- Rendered page count, PDF finalization, file writes and PNG finalization are validated and surfaced as typed failures.

### UI, UX and visual design

- Added a responsive format gallery with descriptions, live page-count estimates and PDF paper selection.
- Added native `glassEffect` on macOS/iOS 26 with material and opaque accessibility fallbacks.
- Refined panels, rims, depth, hover/press response, background glow and reduced-contrast behavior.
- Added citation-coverage and review-required states instead of relying on a global success-looking evidence badge.
- StoreKit price, period and introductory-offer text now come from the loaded product and account eligibility; the UI no longer invents a fallback price or universal trial.
- Purchase and restore have progress, duplicate-action guards, retry handling and Privacy, Terms and subscription-management links.
- StoreKit is isolated behind an injectable boundary so product loading, eligibility, verified purchase, pending, restore and failure states can be tested without changing production behavior.
- A local monthly-subscription/free-trial fixture validates product metadata in test bundles and is excluded from release app bundles.
- New-session actions require destructive confirmation; failed rendering keeps the last usable pages and reports the error.
- Failed analysis can retry the same source or select another.

### Durability and dense-content preservation

- A versioned private snapshot restores the semantic document, extracted evidence, human corrections, presentation style, paper size, seed and page position after termination.
- The source video/audio is not copied. A security-scoped bookmark/path reference enables preview when available; already-generated notes still reopen if the source moved.
- Snapshot writes are atomic and revision-ordered, encrypted with AES-256-GCM, authenticated against their version/algorithm/key fingerprint and bounded to 64 MB.
- The random 256-bit recovery key lives separately in Keychain with after-first-unlock, this-device-only protection; encrypted reads never create a replacement for a missing key.
- Existing SHA-256 v1 recovery envelopes migrate atomically. A key or write failure leaves the valid v1 bytes untouched so migration can retry.
- Recovery storage uses owner-only permissions, iOS Data Protection and backup exclusion; unreadable snapshots are quarantined and **Start New** removes active and quarantined recovery data.
- Missing/transient Keychain failures preserve ciphertext for retry; wrong-key and authentication failures are distinguished. **Start New** deletes ciphertexts before retiring their key.
- Validation no longer caps or drops semantic sections, bullets, steps, comparison rows, quotes, definitions or summaries.
- Before any of the 14 layout rules run, measured overflow is split into deterministic continuation fragments. Continuations retain exact text, claim order and source timestamps.
- Dense multi-type and adversarial wide-glyph tests reconstruct every original claim exactly once; normal-sized sections remain layout-compatible with the earlier renderer.

### Accessibility and interaction

- Reduce Motion now covers phase changes, page entrances, palette changes, progress text, feedback, zoom and hover response.
- Reduce Transparency and Increase Contrast are handled centrally by the glass system.
- Progress stages, page changes and feedback are announced.
- Reading Mode exposes separate semantic headings and selectable body text.
- Page preview includes labeled zoom in/out/reset/close controls, percentage state and keyboard shortcuts.
- Evidence rows adapt between horizontal and vertical layouts.
- The accessibility-sized empty state places its primary import action before decoration.
- Long page sets use capped entrance delays.
- Added stable accessibility identifiers and hermetic macOS/iOS UI-test fixtures for empty, completed, format, page-navigation, export, recovery and accessibility-size flows.

### Language and localization

- Added runtime string-catalog coverage for every current English/German UI key plus localized speech-permission text and plural resources for counts and subscription periods. The compiled catalogs have matching key sets; professional German and localized legal review remain release gates.
- All 14 presentation formats have localized display names while retaining unique, locale-independent raw identifiers for saved projects and semantic interchange.
- Dynamic UI, recovery, StoreKit, progress, export and accessibility strings now resolve through runtime localization instead of remaining English-only values.
- On-device lexical language detection writes `en`, `de` or conservative `und` document metadata; German speech overrides unrelated English slide chrome.
- German stopwords, conversational filler, list/process, comparison, definition and pull-quote markers produce German-aware note structure while preserving transcript evidence verbatim.
- Synthesized German labels use `Wichtigste Erkenntnisse` and `Auf dem Bildschirm um …`.
- Speech locale selection is explicit request → audio-track BCP-47 metadata → device locale, with fallback restricted to the same language family instead of silently using `en-US`.

### Test and build infrastructure

- Added macOS and iOS application unit-test targets and configured both app schemes for testing; the current shared app suite contains 46 tests on each platform.
- Added coverage for stale visual-export rejection, grounding/review logic, all semantic formats, semantic HTML structure/escaping, Markdown neutralization, versioned JSON validation, exact typed-section round-trip and export UTTypes.
- Added recovery coverage for clean restore, missing sources, corruption quarantine, private attributes, write ordering and deletion.
- Added StoreKit coverage for configuration/trial metadata, verified mock purchase, pending/restore, load failure and duplicate-action guarding.
- Added engine regressions for OCR/visual deduplication, repeated visual chrome, face-safe art, heading removal, hero timing, process grounding and narrated OCR padding.
- Added dense continuation, exact-once reconstruction, searchable/tagged PDF, metadata, Unicode extraction and semantic-layer pixel-identity regressions.
- Added wrong-scene/fabricated/late-hero provenance regressions and German language/structuring/recognizer-locale coverage.
- Added a complete 14-layout × 3-PDF-size rendering matrix.
- Added four iOS XCUITest commercial flows; the same four macOS tests compile, with host execution awaiting one-time Xcode/XCTRunner Accessibility authorization.
- Added a reproducible `scripts/ci-verify.sh` gate and pinned-action GitHub workflow for engine/app/UI tests, Release builds, analyzers and StoreKit-fixture leakage checks. All Xcode steps treat Swift/compiler warnings as errors; app-hosted unit suites run serially with one worker, hardening the macOS path against shared-state interference.

## Verification record and pending integrated rerun

| Check | Result |
| --- | --- |
| Engine XCTest suite | Current source suite contains 77 tests; final integrated rerun pending |
| macOS app-hosted suite | Current source suite contains 46 tests; final integrated rerun pending |
| iOS app-hosted suite | Current source suite contains 46 tests; final integrated rerun pending |
| iOS UI suite | Current suite contains 4 tests; final integrated rerun pending |
| macOS UI suite | The same 4-test source compiles with `build-for-testing`; latest compile is pending and host execution remains gated by Xcode/XCTRunner Accessibility authorization |
| Engine warnings-as-errors build | Required by the current gate; final integrated rerun pending |
| macOS Debug and warnings-as-errors Release builds | Prior baseline passed; latest integrated rerun pending |
| iOS Simulator Debug and warnings-as-errors generic-device Release builds | Prior baseline passed; latest integrated rerun pending |
| macOS static analyzer | Prior baseline passed; latest integrated rerun pending |
| iOS static analyzer | Prior baseline passed; latest integrated rerun pending |
| Release localization/resource audit | Prior bundles had matching English/German key sets, localized permission text, privacy manifest, assets and licensed fonts; fresh inspection pending |
| StoreKit test-fixture leakage audit | Prior bundles were clean; fresh `.storekit`/test-data leakage inspection pending |
| Native macOS visual QA | Empty, progress and completed studio states inspected |
| Real 53-second screen-demo fixture | Speech, OCR, tracing, structuring, rendering and export completed end to end |
| Searchable PDF matrix | Current test inventory covers all 14 layouts × 3 page sizes; latest integrated result pending |
| Final fixture PDF | Four pages; correct media box and page count; tagged/searchable; no clipping, overlap, UI-path debris or unsupported process steps |

The real fixture initially produced ten repetitive OCR-heavy pages. The final implementation produced four paced pages following the narrated topics, with exact source-derived sketches, source timestamps and a clearly labeled synthesized takeaway. That regression is now covered by focused deterministic tests.

## Remaining commercial release gates

The source is substantially more professional, but “commercially shippable” still requires evidence outside this local coding pass:

1. Replace the stale checked-in App Store archives, screenshots, subscription-review image and metadata. Create, sign and inspect fresh archives from the current build only.
2. Build the labelled, legally clean fixture corpus defined in `EVALUATION.md`. Gate releases on scene recall/completeness, OCR error, timestamp alignment and unsupported-claim rate across slides, handwriting, code, equations, talking heads, poor audio and non-English media.
3. Match the local product fixture to App Store Connect and exercise real StoreKit Test/Sandbox lifecycle cases: offer ineligibility, purchase/restore UI, expiration, revocation and billing retry. Current transaction-state tests use an injectable mock; iOS additionally validates the live local StoreKit test session.
4. Add long-duration thermal/memory testing on representative iPhone, iPad and Mac hardware, plus hands-on VoiceOver testing. Authorize Xcode/XCTRunner in macOS Accessibility settings and execute the compiled macOS UI suite.
5. Complete professional review of the German translation and localized StoreKit/legal material; extend locale-aware structuring beyond English/German before marketing broader language support.
6. Initialize version control and activate the checked-in quality-gate workflow so tests, analyzers, release provenance and artifact validation run on every candidate. The current script runs the 77-test engine and 46-test-per-platform app inventories, four iOS UI tests, compiles the macOS UI suite, builds both Release products, runs both analyzers and rejects leaked StoreKit fixtures. Warnings are errors across Xcode steps and app-hosted unit tests use one serial worker, but this is not an active commit gate while the directory has no repository metadata.

No local test suite can guarantee every real media file or external StoreKit/App Store condition. Completed rows above record the prior evidence; pending rows must be rerun against the latest source, and every remaining external gate should be completed before public shipment.
