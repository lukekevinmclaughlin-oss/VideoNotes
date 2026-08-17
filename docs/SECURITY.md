# VideoNotes Security and Privacy Model

Date: 13 July 2026  
Scope: the implementation in this repository

This document describes protections that exist in the current app. It deliberately separates shipped behavior from possible future cloud or library features.

## Assets and boundaries

VideoNotes handles source video/audio, extracted speech, recognized on-screen text, source-derived sketches, generated notes, source file references and exported documents. Media and its text are untrusted input.

The current note pipeline is on-device and deterministic. It does not send lecture content to a generative-model provider, expose tools to media content, execute text found in a frame, follow detected links or interpret extracted text as instructions. StoreKit is the only service boundary used for subscription products and transactions.

The macOS app runs in the App Sandbox and can access user-selected files. Media decoding, speech recognition, OCR and image handling use Apple frameworks rather than bundled general-purpose media parsers.

## Implemented controls

### Untrusted media and extracted text

- Source content is treated only as evidence for a note; it is never an executable command or destination.
- Detected URLs, paths, markup and code remain inert text. Exported HTML is escaped and script-free; Markdown neutralizes raw HTML and escapes inline, heading and table syntax derived from source text.
- Extraction and rendering failures are surfaced without replacing the last usable result.
- Snapshot decoding has schema, size, count, finite-number and string-length validation before recovered content is accepted.

### Grounding and output integrity

- `GroundingAuditor` accepts an illustration only when its complete stroke payload exactly matches a traced source moment and its timestamp is relevant to the cited section. Plausible similarity is not sufficient.
- Hero artwork is restricted to the same strict opening-source window used by the auditor; later B-roll cannot silently become cover evidence.
- Synthesized summaries are explicitly marked for review, and semantic exports retain evidence timestamps and review warnings.
- Measured continuation pages preserve oversized semantic content instead of clipping or destructively truncating claims.
- All 14 presentation formats retain every source section exactly once. Specialized study formats use stable ordering/grouping only and do not invent questions, decisions, actions or tasks.
- Tagged PDFs carry searchable Unicode text and metadata. Decorative illustrated content is explicitly marked non-structure before any Core Text drawing; the invisible source-ordered layer provides heading/paragraph tags and `ActualText`, preventing duplicate or conflicting reading structures. A focused regression asserts that the semantic layer does not change rendered pixels; its latest integrated result is pending with the rest of the expanded suite.

### Semantic interchange and fallback

- The JSON export is a schema-versioned typed envelope rather than a visual-page summary. It preserves document title, subtitle, language, source/provenance metadata, presentation identifier, evidence coverage, hero sketch and complete typed payloads for concept, methods, process, comparison, quote, definition and summary sections.
- Decoding rejects unsupported schema versions, noncontiguous indexes, contradictory review/source-time flags or section payloads that cannot reconstruct a valid `NoteSection`. A valid export round-trips to the exact original `NoteDocument`.
- Accessible HTML uses semantic sections/articles, ordered and unordered lists, tables, block quotations/citations and definition lists with language attributes; all source content is escaped.
- Semantic exports depend on the typed document rather than page images or a PDF URL. If visual rendering fails, Markdown, plain text, HTML and JSON remain available while PDF/PNG correctly remain unavailable.

### Local recovery data

- The recovery snapshot contains the semantic note document, transcript, OCR-derived visual moments/sketches, style, page position and a bookmark/path reference to the selected source.
- Source media bytes are not copied into the snapshot.
- New snapshots use a versioned AES-256-GCM envelope with a random nonce and authenticated version, algorithm and key fingerprint. The separate 256-bit key is stored as a device-bound, non-synchronizing Keychain item available after first unlock.
- Legacy SHA-256 integrity envelopes are decoded and validated, then migrated atomically. A Keychain or write failure leaves the original legacy bytes intact so migration can retry.
- Encrypted reads never create or replace a missing key. Missing or transiently unavailable keys preserve the ciphertext for a later retry; wrong-key and authentication failures are reported distinctly.
- Snapshot input and envelope sizes are bounded to 64 MB.
- Writes are atomic and revision-ordered. Invalid or corrupt snapshots are quarantined instead of repeatedly crash-looping recovery.
- Recovery files use owner-only `0600` permissions in a `0700` directory and are excluded from backups.
- iOS applies complete-until-first-authentication Data Protection.
- **Start New** removes both active and quarantined ciphertexts before deleting the Keychain key, preventing an undeletable recovery file from being stranded without its key.
- The device-bound key improves local confidentiality but intentionally prevents recovery-file migration to another device. Exported notes remain the user-controlled portable format.

### Source access and deletion

- Security-scoped bookmarks are used where available, with a path fallback so a missing source can be reported clearly.
- A moved or unavailable source does not prevent the already-generated notes from being restored, but source preview and re-analysis remain unavailable.
- User-created exports are retained at the user-selected destination and are not silently deleted by VideoNotes.

### Purchases

- Subscription price, period and introductory-offer text come from StoreKit rather than hard-coded eligibility claims.
- Verified StoreKit transactions unlock access; unverified transactions are rejected.
- Pending, cancelled, unavailable and restore states are explicit, and duplicate purchase actions are guarded.
- The local `.storekit` fixture is included only in test bundles and is absent from release app bundles.

### Data collection and supply chain

- The app contains no third-party analytics or advertising SDK.
- The privacy manifest declares no tracking or collected-data categories.
- The current project uses Apple platform frameworks plus locally built engine code; bundled fonts include their licenses.

### Localization and automated validation

- Current runtime UI keys, plural forms and the speech-permission description are packaged in English and German with stable nonlocalized format identifiers.
- The current source inventory contains 77 engine tests, 46 app-hosted tests for macOS, the same 46 for iOS and four UI tests. Final integrated results for the expanded inventory are pending and should be recorded separately from this count.
- The four matching macOS UI flows compile with `build-for-testing`; executing them requires Xcode/XCTRunner Accessibility authorization on the host.
- `scripts/ci-verify.sh` also performs both Release builds, both static analyses and a StoreKit-fixture leakage check. Every Xcode test/build/analyze step treats Swift/compiler warnings as errors. App-hosted units run with parallel testing disabled and one worker, including on macOS. A pinned workflow calls the script, but it is not an active provenance gate while this directory is outside version control.

## Known limitations and release gates

- Complete physical-device endurance and memory testing with unusually long, high-resolution and malformed media.
- Extend the existing UI automation to system permission prompts, VoiceOver, StoreKit purchase/restore UI and destructive recovery confirmation; complete hands-on VoiceOver and Dynamic Type review on representative devices.
- Validate StoreKit expiration, revocation, billing retry, offer ineligibility and sandbox/App Store Connect parity.
- Complete professional German and localized legal review before relying on the new runtime catalog in market-facing claims.
- Establish version control, dependency review and CI artifact provenance before public distribution; the checked-in script/workflow is reproducible configuration, not evidence that hosted CI has run.

## Future features are not current guarantees

Provider API keys, cloud model calls, a privacy dashboard, PII redaction, iCloud project sync, a `.videonotes` document package, shared libraries and optional model downloads are design ideas referenced by older planning documents; they are **not implemented in the current app**. If any are added, this threat model and the user-facing privacy policy must be revised before release.
