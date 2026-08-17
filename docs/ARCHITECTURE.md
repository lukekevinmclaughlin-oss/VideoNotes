# VideoNotes: Architecture

Technical design for a native, universal app: stack, targets, module layout, data model, the provider/capability layer, the export subsystem, per-platform behaviour, testing, performance, and security.

Platform: native SwiftUI, universal across macOS, iPadOS, and iOS. One codebase, one pure engine, platform-adaptive UI. Consistent with Luke's native apps (Alembic, Recast, SpaceLens, Talkify, Accent Coach).

---

## 1. Why native (and what it unlocks)

Going native is not a compromise for this app: Apple's on-device frameworks do a large part of the hard work for free, offline, and fast, which is exactly what a private study tool wants.

| Need | On-device Apple framework | Payoff |
| --- | --- | --- |
| Decode video, extract frames | AVFoundation (`AVAssetImageGenerator`, `AVAsset`) | Hardware-accelerated, streamed, no bundled ffmpeg. |
| Per-frame pixel scoring (sharpness, edges, histogram, hash) | Accelerate / vImage, Core Image, Metal | Fast CPU/GPU image ops, no `sharp`/libvips. |
| On-screen text (OCR) | Vision (`VNRecognizeTextRequest`) | Slide/board text extracted on-device, offline, free. A big chunk of "understanding" needs no cloud at all. |
| Occlusion (presenter in front of board) | Vision (`VNGeneratePersonSegmentationRequest`) | Native person masking to score/avoid occluded frames. |
| Transcription | Speech (`SFSpeechRecognizer`) or bundled whisper.cpp | On-device transcript, offline. |
| Math typesetting | SwiftMath (LaTeX to Core Text) | Crisp native formulas, no web view. |
| Vector sketch rendering | Core Graphics (`CGContext`) + SwiftUI `Canvas` | Original diagrams drawn natively, exportable to PDF as true vectors. |
| Optional on-device generation | Core ML (Apple `ml-stable-diffusion`) or MLX | A fully-offline generative-sketch path, no key required. |
| Handwriting/annotation (iPad) | PencilKit | Annotate notes and sketches with Apple Pencil. |
| Export to PDF | `ImageRenderer` / PDFKit / Core Graphics | Native, vector-faithful. |
| Key storage | Keychain Services | Secrets never in files. |

The one thing the Node ecosystem gave cheaply was DOCX/PPTX/EPUB/Anki writers. Those formats are just zipped XML (DOCX/PPTX/EPUB) or SQLite plus media (Anki), so they are written directly in Swift with `ZIPFoundation` and a SQLite library. See the export section.

## 2. Targets and toolchain

- **XcodeGen** from `project.yml` (Luke's convention), generating `VideoNotes.xcodeproj` with two app targets sharing one engine package:
  - `VideoNotes-macOS` (platform macOS)
  - `VideoNotes-iOS` (platform iOS, `TARGETED_DEVICE_FAMILY: "1,2"` so it runs on iPhone and iPad)
- **Deployment targets**: macOS 14, iOS 17. This gives the Observation framework (`@Observable`), `ImageRenderer`, modern Vision, and Swift Concurrency without needing the very newest OS.
- **Swift 5.9+, Swift Concurrency** (async/await, actors, `TaskGroup`) throughout the pipeline and provider layer.
- **Engine as a local Swift Package** (`VideoNotesEngine`, `path: Engine`) consumed by both app targets, exactly like Alembic's `AlembicEngine`.

Sketch of `project.yml`:

```yaml
name: VideoNotes
options:
  bundleIdPrefix: com.lukemclaughlin
  deploymentTarget: { macOS: "14.0", iOS: "17.0" }
  createIntermediateGroups: true
packages:
  VideoNotesEngine: { path: Engine }
settings:
  base: { SWIFT_VERSION: "5.0", MARKETING_VERSION: "1.0.0", CODE_SIGN_STYLE: Automatic, CODE_SIGN_IDENTITY: "-" }
targets:
  VideoNotes-macOS:
    type: application
    platform: macOS
    sources: [App/Sources, App/Resources]
    dependencies: [{ package: VideoNotesEngine }]
    info: { path: App/Info-macOS.plist, properties: { LSApplicationCategoryType: public.app-category.education } }
    entitlements:
      path: App/VideoNotes-macOS.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.files.user-selected.read-write: true
        com.apple.security.assets.movies.read-only: true
        com.apple.security.network.client: true
    settings: { base: { PRODUCT_BUNDLE_IDENTIFIER: com.lukemclaughlin.videonotes, ENABLE_HARDENED_RUNTIME: YES } }
  VideoNotes-iOS:
    type: application
    platform: iOS
    sources: [App/Sources, App/Resources]
    dependencies: [{ package: VideoNotesEngine }]
    info:
      path: App/Info-iOS.plist
      properties:
        NSPhotoLibraryUsageDescription: "Import lecture videos from your library."
        NSSpeechRecognitionUsageDescription: "Transcribe the lecture on this device."
        LSSupportsOpeningDocumentsInPlace: true
        UIFileSharingEnabled: true
    settings: { base: { PRODUCT_BUNDLE_IDENTIFIER: com.lukemclaughlin.videonotes, TARGETED_DEVICE_FAMILY: "1,2" } }
```

## 3. Repository layout

```
VideoNotes/
├── project.yml                      XcodeGen spec (the two targets above)
├── App/                             SwiftUI layer (universal, platform-adaptive)
│   ├── Sources/
│   │   ├── VideoNotesApp.swift      @main, DocumentGroup over the .videonotes package
│   │   ├── Screens/                 ImportView, AnalyzeView, ReviewView, ExportView, SettingsView
│   │   ├── Components/              NoteCardView, FilmstripView, SketchView, OutlineRail, CostMeter
│   │   ├── ViewModels/              @Observable StudySetModel, RunModel, SettingsModel
│   │   └── Platform/                #if os(macOS)/#if os(iOS) shims (import pickers, share, window)
│   ├── Resources/                   Assets.xcassets (AppIcon from ../assets/logo.svg)
│   ├── Info-macOS.plist / Info-iOS.plist
│   └── VideoNotes-macOS.entitlements
├── Engine/                          PURE, testable Swift package "VideoNotesEngine" (no SwiftUI)
│   ├── Package.swift
│   ├── Sources/VideoNotesEngine/
│   │   ├── Model/                   StudySet, NoteCard, Keyframe, Segment, Recipe (Codable structs)
│   │   ├── Video/                   AVFoundation decode + two-rate sampling
│   │   ├── Scoring/                 sharpness, ink-density, stability, occlusion, legibility (vImage/CoreImage/Vision)
│   │   ├── Hash/                    dHash/pHash, hamming
│   │   ├── Select/                  keyframe picker (the completeness rule)
│   │   ├── Dedup/                   cross-video clustering
│   │   ├── Transcribe/             Speech / whisper.cpp / provider transcription + alignment
│   │   ├── Understand/             Vision OCR (on-device) + VLM structure (provider)
│   │   ├── Notes/                   note generation (provider), faithfulness checks
│   │   ├── Sketch/                  Core Graphics renderers: graph, chart, table, timeline, formula + StyleToken
│   │   ├── AI/                      provider clients (URLSession), capability routing, Keychain
│   │   ├── Export/                  PDF, DOCX, PPTX, MD, HTML, EPUB, Anki, LaTeX, RTF, JSON
│   │   ├── Assemble/               sections, front/back matter, quiz, glossary
│   │   └── Pipeline/               orchestration, AsyncStream progress, checkpoints
│   └── Tests/VideoNotesEngineTests/  XCTest / Swift Testing + fixtures
├── Design/                          design tokens, Liquid Glass surfaces, icon svg/png
└── assets/                          logo.svg, logo-mark.svg, wordmark.svg (icon source)
```

Hard rule, same as Luke's other engine apps: the `Engine` package contains no SwiftUI and no view code. It is pure functions and actors over data, depending only on Apple system frameworks. That is what makes selection reproducible and the whole engine unit-testable. Sketch rendering lives in the engine (Core Graphics, not SwiftUI `Canvas`) so it is testable and reusable by the PDF/DOCX/EPUB exporters; the app mirrors it live with a SwiftUI `Canvas` for interactivity.

## 4. Dependencies

System frameworks (no package needed): AVFoundation, Vision, CoreImage, Accelerate/vImage, Metal/MetalPerformanceShaders, Speech, PDFKit, CoreGraphics, PencilKit (iPad), Security (Keychain), Observation.

Swift packages (SPM, kept minimal):

| Concern | Package |
| --- | --- |
| Zip containers (DOCX, PPTX, EPUB, Anki media) | ZIPFoundation |
| SQLite (Anki `.apkg` collection db) | GRDB.swift (or SQLite.swift) |
| LaTeX typesetting | SwiftMath (iosMath) |
| whisper.cpp transcription (optional, bundled model) | a whisper.cpp SwiftPM wrapper or a prebuilt xcframework |
| On-device generative sketches (optional) | apple/ml-stable-diffusion (Core ML) |

Provider SDKs are deliberately avoided: the AI layer uses `URLSession` directly (matching how Luke's other apps hand-roll LLM connections), so there is no third-party SDK surface and no lock-in.

## 5. Data model

Pure `Codable` Swift value types in `Engine/Model`, the single source of truth for every stage and exporter.

```swift
struct StudySet: Codable, Identifiable {
    let id: UUID
    var title: String
    var source: SourceRef            // file bookmark, duration, resolution, language
    var recipe: Recipe               // the settings used (reproducible)
    var summary: String
    var sections: [Section]          // ordered chapters, each references card ids
    var glossary: [GlossaryTerm]
    var quiz: [QuizItem]
    var flashcards: [Flashcard]
    var createdAt: Date; var updatedAt: Date
}

struct NoteCard: Codable, Identifiable {
    let id: UUID
    var time: CMTimeRange            // source window
    var alsoSeenAt: [CMTime]         // dedup back-references
    var contentType: ContentType     // slide, board, code, document, chart, ...
    var keyframe: AssetRef           // full-res source frame (kept, shown dim/optional)
    var understanding: Understanding // Vision OCR + VLM structure (cached)
    var notes: Notes                 // structured, editable
    var illustration: Illustration   // .vector | .generative | .formula | .source
    var include: Bool
    var userEdited: Bool             // protects from bulk regeneration
}

enum Illustration: Codable {
    case vector(VectorSpec, asset: AssetRef, alt: String)     // reconstructed diagram/chart/table
    case formula(latex: String, asset: AssetRef, alt: String) // SwiftMath render
    case generative(prompt: ImagePrompt, asset: AssetRef, alt: String)
    case source(AssetRef)                                     // dim reference frame
    case none
}

struct Recipe: Codable {             // the reproducible "settings" == preset
    var samplingFPS: Double; var sensitivity: Double
    var noteDensity: NoteDensity     // terse | balanced | detailed
    var style: StyleToken; var language: String; var offline: Bool
    var routing: CapabilityRouting   // which provider does what
    var promptVersions: [Stage: String]  // for cache keys
}
```

`Recipe` is the run's settings and the reproducibility unit (pipeline == recipe, as in Luke's other engines). Editing a card sets `userEdited` so bulk "regenerate all" never clobbers hand-tuned work. The model holds asset refs, not bytes. Optional attached inputs (a source slide deck, a transcript) are referenced on `SourceRef`, and when present drive multi-input fusion (`ENGINE.md` §13): each `NoteCard` may carry a `slideRef` to its matched slide for exact text and vectors.

## 6. Persistence: a document-based app

VideoNotes is a `DocumentGroup` app over a custom package document, which gives native open/save, iCloud Drive, Files.app, versioning, and drag-and-drop on all three platforms for free.

- A `.videonotes` document is a **file package** (a directory presented as one file), declared as an exported `UTType` conforming to `com.apple.package`.
- Implemented as a `ReferenceFileDocument` (or `FileDocument`) backed by a `FileWrapper` directory:

```
MyLecture.videonotes/            (a package: one icon in Finder/Files)
├── studyset.json                the StudySet model
├── transcript.json              timestamped transcript
├── keyframes/                   full-res kept frames (heic/jpeg)
├── illustrations/               rendered pdf/svg (vector) or png (generative)
├── cache/                       per-stage AI cache keyed by content hash
├── journal.jsonl               checkpoint log for resume
└── source.bookmark             security-scoped bookmark to the original video
```

The original video is referenced by a security-scoped bookmark, not copied, so projects stay small; re-selecting frames requires the video to be reachable, editing and export do not.

Because it is a document, a study set syncs via iCloud Drive across the user's devices for free. Conflicts are resolved without silent lossy merges: the model is a set of independently identified cards, so a conflict keeps the newer card-set and preserves the other version rather than blindly merging text (`SECURITY.md` T7).

## 7. Provider / capability layer (BYO-key)

Follows Luke's connection-agnostic rule and Recast's capability-graph pattern. Capabilities are decoupled from providers; the app routes each capability to the best available backend. All network access is in the engine's `AI` module via `URLSession`, never in the UI.

**Capabilities**: `vision` (semantic structure), `notes`, `transcribe`, `imageGen`. Note that on-device OCR (Vision) and on-device transcription (Speech/whisper) mean two of these often need no provider at all.

| Backend | vision | notes | transcribe | imageGen |
| --- | --- | --- | --- | --- |
| On-device Apple (Vision OCR, Speech) | text + layout | no | yes | no |
| Anthropic (Claude) | yes | yes | no | no |
| OpenAI | yes | yes | yes | yes |
| Google (Gemini) | yes | yes | yes | yes |
| OpenAI-compatible (Ollama / LM Studio / MLX server) | if model supports | yes | via local whisper | if model supports |
| On-device Core ML (`ml-stable-diffusion`) | no | no | no | yes (offline) |

- **Routing** (`AI/Capabilities`): per capability, pick the best connected backend by a quality/cost/offline policy, user-overridable in Settings. Missing capabilities degrade gracefully: no `imageGen` gives vector/formula illustrations only; no `vision` VLM still yields Vision-OCR + transcript-grounded notes with source thumbnails.
- **Keys** are stored with Keychain Services (per Luke's keychain practice), never written into the document, never logged, never shown to the view layer.
- **Offline mode** hard-disables every network backend and routes to on-device only (Vision OCR + Speech/whisper + vector illustrations, optionally Core ML generation). The UI shows an explicit "offline, nothing leaves this device" state.
- **Structured output**: vision and notes calls request JSON and decode into the typed `Understanding`/`Notes` structs, retrying on decode failure rather than string-parsing. The exact schemas, prompts, faithfulness rules, and prompt-injection defences are specified in `PROMPTS.md`.
- **Concurrency + resilience**: an actor-guarded bounded queue (default 4 to 6 in flight via `TaskGroup`) with per-call retry and backoff; one failure never aborts the run.
- **Cost optimizations**: keyframes are downscaled before upload (long edge tuned per provider); text-only frames with confident OCR skip the VLM entirely; simple frames are batched per call; routing is tiered (a cheap model triages, the strong model handles only complex diagrams). Cost is estimated up front, metered live, and bounded by a user **budget cap** that, when hit, degrades to on-device rather than overspending. With no key connected, the on-device path (Vision OCR + local transcription + vector illustrations) is the default and produces a complete study set.

## 8. Export subsystem

Every exporter is a pure function `(StudySet, ExportOptions) -> Data/FileWrapper` in `Engine/Export`. A shared layout (a SwiftUI view rendered by `ImageRenderer`, plus a Core Graphics path for pure-engine contexts) is the canonical page design.

| Target | How, natively |
| --- | --- |
| **PDF** | Render the study layout with `ImageRenderer` to a PDF `CGContext` (or `NSPrintOperation`/`UIPrintPageRenderer`). Vector sketches and SwiftMath formulas stay vector; real pagination and TOC. Highest fidelity. |
| **HTML** | Emit a single self-contained file: inline CSS, inline SVG for vector sketches (the Core Graphics renderer also serialises to SVG), images as data URIs. |
| **Markdown** | GitHub/Obsidian-flavoured MD plus an `assets/` folder; callouts for definitions, `$$` math, linked images. Plain string generation. |
| **LaTeX** | Article template, native math, TikZ or embedded PDF for diagrams. String generation. |
| **RTF** | Build an `NSAttributedString` and export via `NSAttributedString.data(from:documentAttributes:)` with `.rtf`. Native, no dependency. |
| **DOCX** | Write the OOXML package (`word/document.xml` + rels + styles) with `ZIPFoundation`; formulas as OMML or embedded vector, sketches as embedded PDF/PNG. |
| **PPTX** | Write the OOXML presentation package with `ZIPFoundation`, one card per slide, section dividers, title slide. |
| **EPUB** | OPF + nav + one XHTML per section + embedded SVG, zipped with `ZIPFoundation`; alt-text included. |
| **Anki `.apkg`** | Build the Anki SQLite collection with GRDB (notes/cards/models), bundle media, zip with `ZIPFoundation`. Front = question from points/definitions, back = answer + illustration; cloze for formulas. A headline student feature. |
| **JSON** | Encode the `StudySet` verbatim (`Codable`). Re-importable. |
| **Plain text** | Minimal serialiser. |
| **ODT and more (macOS only)** | If `pandoc` is on the path, offer conversions via `Process`. Not available on iOS. |
| **Notion** | Paste-ready Markdown, or a direct page push if a token is connected. Never default. |

Delivery is platform-native: macOS writes to a user-chosen location or shows a save panel; iOS/iPadOS present a `ShareLink` / share sheet and support "Open in" and Files. Batch export ("PDF plus Anki plus Markdown at once") is one action.

## 9. UI structure (design language in `DESIGN.md`)

- **Universal SwiftUI**, one view layer with `#if os()` shims in `App/Platform`. `@Observable` view models (`RunModel`, `StudySetModel`, `SettingsModel`) drive the screens; the engine streams progress via `AsyncStream` that the UI awaits.
- **Screens**: Home/Library, Import, Analyze, Review/Edit, Study, Export, Settings. Review/Edit is the heart: an outline plus keyframe filmstrip on one side (`NavigationSplitView` on iPad/macOS, stacked navigation on iPhone), a column of editable `NoteCardView`s (scrub-to-source mini-player, inline tutor actions, Pencil annotation), and a per-card inspector (regenerate, switch illustration mode, edit vector nodes/labels, provenance). Study is the active-recall / spaced-repetition (FSRS) mode.
- **Analyze** is the signature view: the holographic Scan, where candidate frames stream past a scan line, a targeting reticle locks onto content, telemetry ticks in monospaced digits, rejected frames dim and fall away, and kept keyframes fly into a forming node-lattice outline (`matchedGeometryEffect`). Driven by real engine `AsyncStream` events. Full choreography in `DESIGN.md` §7.
- **Aesthetic**: the Holographic Study HUD (see `DESIGN.md`): a two-surface system where Liquid Glass, a scanning reticle, and holographic cyan / arc-gold accents form the chrome, while note content sits on a calm, legible study surface. Default is light study content in a subtle glass HUD; an optional Immersive HUD theme goes full forced-dark. Reduce Motion, Reduce Transparency, Dynamic Type, dyslexia font, keyboard, and VoiceOver are all first-class.
- **iPad**: PencilKit annotation over notes and sketches; drag-and-drop video in; multi-column layout. **iPhone**: import, watch progress, review, study, and export on the go.
- The app icon and in-app mark are generated into `Assets.xcassets` from `assets/logo.svg` and `assets/logo-mark.svg` (the HUD reticle-and-core) via the `Design` icon pipeline; `assets/logo-classic.svg` is the light alternate.

## 10. Per-platform behaviour

| Concern | macOS | iPadOS | iOS (iPhone) |
| --- | --- | --- | --- |
| Import | drag-drop, open panel, Files | `PhotosPicker`, Files, drag-drop | `PhotosPicker`, Files, share-in |
| Processing | full power, large videos, long runs | strong; watch thermal/memory on 2h inputs | shorter clips favoured; chunk and checkpoint |
| Transcription | whisper.cpp or Speech or provider | same | Speech or provider (bundled whisper optional) |
| Annotation | pointer editing | PencilKit + touch | touch |
| Export delivery | save panel / Finder, optional pandoc | share sheet, Files, "Open in" | share sheet, Files |
| Sandbox | app-sandbox on, security-scoped bookmarks | on | on |
| Optional on-device generation | Core ML SD if enabled | high-end iPad only | usually provider-only |
| Background run + notify | Dock progress + local notification | background task + notification | background task + notification |

Long-video handling on iOS is explicit: frames are sampled and scored in autorelease-pooled batches through an `AsyncSequence`, downscaled for scoring, and the run is checkpointed so a backgrounded or thermally-throttled session resumes.

## 11. Testing

Pure engine, thoroughly tested with XCTest / Swift Testing (Luke's convention: an `Engine` package with a `Tests` target), no UI and no network required:

- **Selection**: segmentation boundaries, dHash/pHash, dedup clustering, and each scorer on crafted `CGImage` fixtures (blurred, half-written, occluded, finished). The flagship tests: a scripted "whiteboard fills then erases" frame sequence asserts the finished-before-erase frame is chosen; a "slide shown twice" sequence asserts a single card.
- **Sketch**: golden tests for the Core Graphics renderers (graph, chart, table, timeline, formula) comparing rendered PDF/SVG output.
- **Export**: golden-file tests per format from a fixture `StudySet`; structural assertions (valid DOCX/PPTX/EPUB/APKG zips, PDF page count, SQLite schema for Anki, math present).
- **Providers**: protocol-mocked; routing, structured-decode, and degradation paths (no imageGen, no vision, offline) tested without network.
- **Fixtures**: short self-recorded or public-domain clips with hand-labelled expected keyframes drive the precision/recall regression metric from `SPEC.md`.
- **Evaluation harness** (`EVALUATION.md`): deterministic metrics (selection F1, completeness, dedup, export validity) run in CI and gate every commit; model-dependent metrics (understanding, note faithfulness via adversarial judge panels, illustration accuracy) run as a pinned, human-calibrated job and gate releases.

Plus a UI smoke test that the app launches and a canned fixture produces a `StudySet` end to end on both targets.

## 12. Performance

- AVFoundation frame generation is async and hardware-accelerated; scoring runs on a bounded concurrent queue across cores (vImage/Metal), memory kept bounded by streaming and autorelease pools regardless of video length.
- Two-rate sampling (coarse scan, full-rate refine only near chosen moments) keeps decode proportional to content, not runtime; sampling density also adapts to content type (a static slide deck needs far fewer samples than a whiteboard).
- Stages overlap: transcription runs alongside scanning, and per-keyframe understanding/notes/sketch pipeline as each frame is selected, so cards begin assembling before the scan finishes.
- AI stages: bounded concurrency, per-stage caching keyed by content hash, resumable journal; edits and re-exports are near-instant because nothing re-runs.
- Target: a 60-minute 1080p lecture scanned deterministically in under 3 minutes on Apple silicon (Mac and recent iPad); generation streamed and cancellable.

## 13. Security, privacy, distribution

- App-sandbox on (both platforms), security-scoped bookmarks for the source video, network entitlement only for the (optional) provider layer. Keys in Keychain only.
- Video and the full frame set never leave the device. Only selected keyframes plus aligned transcript snippets go to the chosen cloud provider, and only when connected. Offline mode sends nothing and says so. Optional on-screen PII redaction (Vision-detected emails/names blurred) before any upload. No telemetry without opt-in. Documents contain no keys.
- **Distribution**: macOS as a notarised, direct-download DMG (unsigned for first internal builds, matching Alembic and the other siblings in `DMG_Applications`); iOS/iPadOS via TestFlight then the App Store. BYO-key plus a genuine on-device offline mode fits App Store review (the user supplies their own key, and the app is fully functional offline). No backend, so no per-user running cost.

---

See `ENGINE.md` for the algorithms (now with the on-device framework mapping), `DESIGN.md` for the Holographic Study HUD and motion system, `PROMPTS.md` for the model contracts, `EVALUATION.md` for how quality is measured and gated, `SECURITY.md` for the threat model, `SPEC.md` for product requirements, `AUDIT.md` and `AUDIT-2.md` for the reviews that shaped this, and `ROADMAP.md` for the build order.
