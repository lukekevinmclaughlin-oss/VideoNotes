# VideoNotes — Professional Hardening Audit

Date: 12 July 2026  
Status: source implementation and local verification complete; distribution artifacts still require regeneration

## Outcome

This pass focused on the two highest-risk areas: keeping generated notes traceable to the source video, and making the app feel dependable and polished across iPhone, iPad and Mac. The app now treats speech, OCR and traced frames as evidence rather than decoration. When it cannot justify a source-specific illustration, it uses a neutral non-semantic motif instead of inventing a diagram or object that was not in the video.

The interface received a responsive liquid-glass treatment, clearer progress and error states, an evidence-review workflow, a semantic Reading Mode and stronger accessibility behavior. Cancellation, rendering, export, privacy declarations and entitlement loading were hardened for production use.

## Implemented: accuracy and trust

- Frame sampling now records the frame time actually returned by AVFoundation, rather than presenting the requested probe time as evidence. Page citations, the Evidence Inspector and source preview therefore point to the extracted moment.
- The perceptual hash combines spatial contrast with absolute luminance, so uniformly dark and uniformly light frames no longer collapse to the same signature.
- Scene selection covers the timeline in two passes and can inspect up to 120 representative detailed scenes. Opening/closing context and high-change scenes are retained while transition bursts are spaced out.
- Blank transitions and dominant talking-head frames are rejected as textless visual evidence. Textless scenes require enough traced structure to support useful source-derived art.
- OCR deduplication preserves decimal points, operators, percentages and line boundaries. Fuzzy merging is restricted to adjacent, visually similar scenes with high text similarity; a fuller progressive reveal retains its own later timestamp.
- OCR text regions remain excluded from contour tracing, preventing malformed letter outlines from being presented as source art.
- Speech pauses and visual changes are both used as section boundaries. A section cannot borrow a future visual merely because no earlier frame is available.
- Section timestamps come from the actual visual or transcript evidence used for that section. The document language is marked `und` when the detector has not established a language instead of claiming English.
- Comparison layouts are used only when source points explicitly map to both named sides. Ambiguous content falls back to a concept layout instead of being split arbitrarily.
- Hero art uses the earliest relevant source-backed sketch. Process, concept and cover fallbacks no longer imply invented semantic icons, arrows or relationships; neutral decorative marks are used when no grounded sketch exists.
- Paired pages display both source times, preserving provenance for each section.
- The grounding badge now reports the evidence actually present: speech plus visual, speech only, visual only or limited evidence. It no longer overstates a result as “strong grounding.”
- The Evidence Inspector supports searchable/filterable timestamped speech and OCR, direct preview of the original media paused on the cited frame, and human correction of transcript or OCR text. A correction rebuilds and rerenders the notes from the amended evidence without rescanning the video.

These changes materially reduce irrelevant imagery, but do not imply that OCR, speech recognition or generic contour tracing is infallible. The inspector and source timestamps are intentional review tools, not merely UI detail.

## Implemented: UI, UX and accessibility

- The visual system uses layered glass panels, specular rims, depth, soft gradients, reactive hover/press states and a restrained animated HUD grid. Animation is used to communicate state and hierarchy rather than obscure content.
- Reduce Transparency, Increase Contrast, Reduce Motion, inactive-scene state and Low Power Mode are respected. Expensive ambient motion freezes when it would be distracting or wasteful.
- Headers, progress steps and result controls use responsive variants. `ViewThatFits` provides an expanded desktop toolbar and a compact menu-led toolbar without losing Evidence, Reading Mode, PNG export, regenerate, compact-layout or share actions.
- Primary controls and palette swatches meet a 44-point minimum target. Palette selection, evidence filters and page controls expose appropriate accessibility selection state.
- Fixed-width progress and clipped empty/error layouts were replaced with scrollable, adaptable states suitable for large Dynamic Type sizes.
- Raster note pages now have useful accessibility labels, hints and actions. Reading Mode provides the same generated content as scalable, selectable semantic text with source timestamps for VoiceOver, Dynamic Type and copying.
- Tiny page dots were replaced by Previous/Next controls and a clear “Page X of N” status. Oversized page zoom constraints are limited to Mac.
- Style regeneration keeps the existing pages visible and shows an “Updating style…” overlay, avoiding a disruptive blank-state flash. “Shuffle” is now the clearer “Regenerate layout.”
- Errors are typed and actionable. Speech-permission failures can open system settings; importer, PDF and PNG failures are surfaced instead of silently disappearing.
- Entitlement loading has a dedicated state, preventing a paywall flash while StoreKit access is being restored.
- Source changes reset the gallery position, and page indices are bounded when a rerender changes the page count.

## Implemented: reliability, performance and release hardening

- Speech recognition has cancellation propagation and lock-protected result collection. The pipeline checks cancellation between transcription, frame analysis, structuring and rendering; image and PDF renderers also check per page.
- Render jobs have generation and revision guards. Older asynchronous results cannot overwrite a newer source or style, and each PDF is written atomically into a unique temporary directory before publication.
- Previous temporary PDFs are cleaned up after successful replacement or reset.
- Page previews render at the native 1080 × 1920 canvas rather than at 2×. A ten-page measurement reduced peak memory from approximately 356 MB to 106 MB while PDF output remains vector based.
- PNG export creates a conflict-safe new folder, writes each page atomically, validates encoded data and removes partial output on failure. PDF export no longer substitutes empty data.
- User-facing feedback is typed as success or failure, and a newer message cannot be cleared by an older timer.
- Source preview uses the native platform player instead of the SwiftUI AVKit wrapper that crashed during macOS QA. Preview opens paused at the evidence timestamp so the cited frame remains visible until the reviewer chooses to play.
- The privacy manifest declares the required UserDefaults accessed-API reason `CA92.1`, with no tracking or collected-data declarations.
- Build number is now 2. The generated Info.plist configuration includes the speech-recognition usage description for both platforms.
- Strict Swift concurrency checking is clean for the engine after isolating speech-recognition callbacks and avoiding non-Sendable transcription results across the continuation boundary.

## Verification performed

| Check | Result |
| --- | --- |
| Engine XCTest suite | 35 tests passed |
| Strict concurrency build | Passed with complete checking and no warnings |
| macOS Debug app build | Passed |
| Generic iOS Simulator app build | Passed |
| Synthetic three-scene video | Three distinct scenes selected; four pages rendered; actual evidence times retained at approximately 00:01, 00:09 and 00:17 |
| Cancellation probe | Frame scan stopped in approximately 0.22 seconds rather than completing the roughly 45-second scan |
| Memory probe | Ten-page peak reduced from approximately 356 MB to 106 MB |
| Visual QA | Mac compact/wide layouts, Evidence Inspector and iPhone accessibility text sizing inspected |
| Current source product metadata | Build 2, speech usage description and `CA92.1` privacy reason verified |

## Release warning

**Do not ship the checked-in build-1 archives in `AppStoreAssets/Archives`.** They are stale relative to the current source. In particular, the archived iOS build does not contain `NSSpeechRecognitionUsageDescription`; requesting speech permission from that artifact can terminate the app. Both checked-in archives report bundle version 1.

Build 2 has been verified from current source in local products, but this pass did not create, sign or upload distribution archives. Before TestFlight or App Store submission, create fresh build-2-or-newer iOS and macOS archives from the current project, inspect their embedded Info.plist and privacy manifest, run them on release hardware, and upload those new artifacts only.

Existing App Store screenshots also predate this UI and must not be treated as a current representation of the product.

## Remaining professional roadmap

1. Build the real lecture fixture corpus defined in `EVALUATION.md` and enforce release gates for scene-selection recall, completeness, OCR error, timestamp alignment and unsupported-claim rate. Include slides, handwriting, screen recordings, talking heads, equations and poor audio.
2. Add subject-aware, source-constrained renderers for diagrams, charts, formulas, code and other technical notation. These should preserve detected structure and values rather than convert every source visual to a generic contour sketch.
3. Add overflow continuation pages so long, evidence-rich sections retain content without crowding or silent truncation.
4. Add an application test target with UI tests, accessibility audits, cancellation/rerender race coverage, export failure cases and measurable coverage reporting.
5. Capture new App Store screenshots for all required device sizes and replace the stale checked-in archives with freshly signed, validated release artifacts.
6. Derive trial duration, renewal wording, price and eligibility messaging directly from StoreKit product/offer state. Provide working Privacy Policy, Terms and subscription-management links wherever purchase messaging appears.
