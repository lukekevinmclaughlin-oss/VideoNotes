import CryptoKit
import Security
import SketchnoteEngine
import UniformTypeIdentifiers
import XCTest

@testable import VideoNotes

@MainActor
final class VideoNotesAppTests: XCTestCase {
  func testFreshWorkspaceCannotExportStaleOrMissingOutput() {
    let model = StudioModel(snapshotStore: makeTemporaryStore())

    XCTAssertFalse(model.isExportReady)
    XCTAssertNil(model.pdfData())
    XCTAssertNil(model.semanticNotes(format: .markdown))
    XCTAssertThrowsError(try model.exportPNGs(to: FileManager.default.temporaryDirectory)) {
      XCTAssertEqual(
        $0.localizedDescription, "Wait for the current note format to finish rendering.")
    }
  }

  func testGroundingReportFlagsSynthesizedSectionsForReview() {
    let report = StudioModel.GroundingReport(
      duration: 120, transcriptSegments: 8, visualMoments: 4, tracedVisuals: 2,
      citedSections: 5, synthesizedSections: 1)

    XCTAssertTrue(report.requiresReview)
    XCTAssertEqual(report.totalSections, 6)
    XCTAssertEqual(report.citationLabel, "5 of 6 sections source-cited")
    XCTAssertEqual(report.coverageLabel, "Speech + visual evidence")
  }

  func testFullyGroundedReportDoesNotOverstateMissingModalities() {
    let report = StudioModel.GroundingReport(
      duration: 75, transcriptSegments: 3, visualMoments: 2, tracedVisuals: 1,
      citedSections: 4, synthesizedSections: 0)

    XCTAssertFalse(report.requiresReview)
    XCTAssertEqual(report.citationLabel, "4 of 4 sections source-cited")
  }

  func testEverySemanticFormatProducesNonemptyEvidenceAwareOutput() throws {
    let document = NoteDocument(
      title: "Sample", sections: [
        .summary(heading: "Uncited Review", points: ["Check this synthesis."], sourceTime: nil),
        .concept(
          heading: "Grounded <Concept>", body: "Evidence & explanation", points: [],
          iconHints: [], quote: nil, sourceTime: 61),
      ])

    for format in SemanticNoteExportFormat.allCases {
      let data = try XCTUnwrap(
        SemanticNoteExporter.make(
          format: format, document: document, sourceName: "Sample.mov",
          presentationFormat: .evidenceFirst,
          evidenceCoverage: "1 of 2 sections source-cited"))
      XCTAssertFalse(data.isEmpty, "\(format) export was empty")
    }
  }

  func testHTMLExportEscapesSourceTextAndIncludesTimestamp() throws {
    let document = NoteDocument(
      title: "Safety", sections: [
        .concept(
          heading: "A < B", body: "Use A & B", points: [], iconHints: [], quote: nil,
          sourceTime: 61)
      ])
    let data = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .html, document: document, sourceName: "Safety.mov",
        presentationFormat: .detailed, evidenceCoverage: "Source-cited"))
    let html = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(html.contains("A &lt; B"))
    XCTAssertTrue(html.contains("Use A &amp; B"))
    XCTAssertTrue(html.contains("01:01"))
    XCTAssertFalse(html.contains("<h2>A < B</h2>"))
  }

  func testJSONExportIsStructuredAndMarksUncitedPages() throws {
    let document = NoteDocument(
      title: "Sample", sections: [
        .summary(heading: "Review", points: ["Verify me"], sourceTime: nil)
      ])
    let data = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .json, document: document, sourceName: "Sample.mov",
        presentationFormat: .studyGuide, evidenceCoverage: "0 of 1 sections source-cited"))
    let export = try JSONDecoder().decode(SemanticNoteExportEnvelope.self, from: data)

    XCTAssertEqual(export.presentationFormat, "studyGuide")
    XCTAssertEqual(export.sections.first?.requiresReview, true)
  }

  func testVersionedSemanticJSONRoundTripsEveryTypedSectionWithoutFlattening() throws {
    let sketch = [
      SketchStroke(points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)])
    ]
    let document = NoteDocument(
      title: "Typed lesson", subtitle: "Complete semantics", language: "en",
      sections: [
        .concept(
          heading: "Concept", body: "Exact body", points: ["Claim A", "Claim B"],
          iconHints: ["brain"], quote: "Embedded quote", sourceTime: 1, sketch: sketch),
        .methods(
          heading: "Methods",
          columns: [
            MethodColumn(
              title: "Method one", tagline: "Tagline", summary: "Summary",
              steps: ["First", "Second"], iconHints: ["gear"])
          ], sourceTime: 2),
        .process(
          heading: "Process", steps: ["Do this", "Then that"], iconHints: ["arrow"],
          sourceTime: 3, sketch: sketch),
        .comparison(
          heading: "Compare", leftTitle: "Left", leftPoints: ["L1"],
          rightTitle: "Right", rightPoints: ["R1"], sourceTime: 4, sketch: sketch),
        .quote(text: "Verbatim", attribution: "Speaker", sourceTime: 5),
        .definition(term: "Term", meaning: "Meaning", sourceTime: 6),
        .summary(heading: "Summary", points: ["Review"], sourceTime: nil),
      ], heroSketch: sketch)

    let data = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .json, document: document, sourceName: "Source file",
        presentationFormat: .studyGuide, evidenceCoverage: "6 of 7 sections source-cited"))
    let decoded = try JSONDecoder().decode(SemanticNoteExportEnvelope.self, from: data)

    XCTAssertEqual(decoded.schemaVersion, SemanticNoteExportEnvelope.currentSchemaVersion)
    XCTAssertEqual(decoded.source, "Source file")
    XCTAssertEqual(decoded.documentTitle, document.title)
    XCTAssertEqual(decoded.documentSubtitle, document.subtitle)
    XCTAssertEqual(decoded.language, "en")
    XCTAssertEqual(decoded.presentationFormat, NotePresentationFormat.studyGuide.rawValue)
    XCTAssertEqual(decoded.heroSketch, document.heroSketch)
    XCTAssertEqual(decoded.sections.map(\.requiresReview), [false, false, false, false, false, false, true])
    XCTAssertEqual(decoded.noteDocument, document)
  }

  func testSemanticJSONRejectsUnsupportedVersionsAndContradictoryReviewFlags() throws {
    let document = NoteDocument(
      title: "Validated", sections: [
        .summary(heading: "Grounded", points: ["Exact"], sourceTime: 2)
      ])
    let data = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .json, document: document, sourceName: "source.mov",
        presentationFormat: .detailed, evidenceCoverage: "Verified"))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    object["schemaVersion"] = 99
    let futureData = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try JSONDecoder().decode(SemanticNoteExportEnvelope.self, from: futureData))

    object["schemaVersion"] = SemanticNoteExportEnvelope.currentSchemaVersion
    var sections = try XCTUnwrap(object["sections"] as? [[String: Any]])
    sections[0]["requiresReview"] = true
    object["sections"] = sections
    let contradictoryData = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try JSONDecoder().decode(SemanticNoteExportEnvelope.self, from: contradictoryData))
  }

  func testSemanticMarkdownNeutralizesRawHTMLAndKeepsTablesWellFormed() throws {
    let document = NoteDocument(
      title: "# Lesson <script>alert(1)</script>",
      sections: [
        .comparison(
          heading: "A | B", leftTitle: "Left | side", leftPoints: ["<b>one</b>"],
          rightTitle: "Right", rightPoints: ["line one\nline two"], sourceTime: 8)
      ])
    let data = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .markdown, document: document, sourceName: "source.mov",
        presentationFormat: .detailed, evidenceCoverage: "Verified"))
    let markdown = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(markdown.contains("# \\# Lesson &lt;script&gt;alert(1)&lt;/script&gt;"))
    XCTAssertTrue(markdown.contains("Left \\| side"))
    XCTAssertTrue(markdown.contains("line one line two"))
    XCTAssertFalse(markdown.contains("<script>"))
    XCTAssertFalse(markdown.contains("Left | side | Right"))
  }

  func testSemanticHTMLUsesTypedAccessibleElementsAndEscapesSourceContent() throws {
    let document = NoteDocument(
      title: "Safe <Lesson>", language: "de",
      sections: [
        .process(
          heading: "Steps <now>", steps: ["A & B"], iconHints: [], sourceTime: 1),
        .comparison(
          heading: "Compare", leftTitle: "A", leftPoints: ["one"], rightTitle: "B",
          rightPoints: ["two"], sourceTime: 2),
        .quote(text: "Quoted", attribution: "Source", sourceTime: 3),
        .definition(term: "Term", meaning: "Meaning", sourceTime: 4),
      ])
    let data = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .html, document: document, sourceName: "Safe <Lesson>",
        presentationFormat: .detailed, evidenceCoverage: "Verified"))
    let html = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(html.contains("<html lang=\"de\">"))
    XCTAssertTrue(html.contains("<ol><li>A &amp; B</li></ol>"))
    XCTAssertTrue(html.contains("<table>"))
    XCTAssertTrue(html.contains("<blockquote>"))
    XCTAssertTrue(html.contains("<dl>"))
    XCTAssertTrue(html.contains("Safe &lt;Lesson&gt;"))
    XCTAssertFalse(html.contains("<title>Safe <Lesson></title>"))
  }

  func testSemanticFormatsResolveToExportableContentTypes() {
    for format in SemanticNoteExportFormat.allCases {
      XCTAssertFalse(format.contentType.identifier.isEmpty)
    }
    XCTAssertTrue(SemanticExportDocument.readableContentTypes.contains(.plainText))
  }

  func testProjectSnapshotRoundTripPreservesSemanticProjectAndStyle() throws {
    let store = makeTemporaryStore()
    let snapshot = makeSnapshot(
      sourceReference: ProjectSourceReference(
        bookmarkData: Data([1, 2, 3]), fallbackPath: "/private/source.mov"))

    try store.save(snapshot)
    let recovered = try XCTUnwrap(store.load())

    XCTAssertEqual(recovered, snapshot)
    XCTAssertEqual(recovered.content.extractedContent.transcript.first?.text, "Recovered evidence")
    XCTAssertEqual(
      recovered.style.presentationFormat, NotePresentationFormat.evidenceFirst.rawValue)
    XCTAssertEqual(recovered.style.pdfPageFormat, PDFPageFormat.a4.rawValue)
  }

  func testSnapshotFileUsesAuthenticatedEncryptionAndFreshNonces() throws {
    let keyProvider = TestProjectSnapshotKeyProvider(key: testKey(0x11))
    let store = makeTemporaryStore(keyProvider: keyProvider)
    let snapshot = makeSnapshot(sourceReference: nil)

    try store.save(snapshot)
    let firstData = try Data(contentsOf: store.snapshotURL)
    let firstEnvelope = try decodeEncryptedEnvelope(firstData)
    try store.save(snapshot)
    let secondData = try Data(contentsOf: store.snapshotURL)
    let secondEnvelope = try decodeEncryptedEnvelope(secondData)

    XCTAssertEqual(firstEnvelope.version, 2)
    XCTAssertEqual(firstEnvelope.algorithm, "AES.GCM.256")
    XCTAssertEqual(firstEnvelope.keyIdentifier.count, 16)
    XCTAssertNotEqual(firstEnvelope.sealedPayload, secondEnvelope.sealedPayload)
    XCTAssertNil(firstData.range(of: Data("Recovered evidence".utf8)))
    XCTAssertNil(firstData.range(of: Data("Grounded Concept".utf8)))
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(keyProvider.loadCount, 3)
  }

  func testKeychainProviderCreatesAndReusesKeyThroughInjectedBoundary() throws {
    let keychain = TestProjectSnapshotKeychainAccess()
    let provider = KeychainProjectSnapshotKeyProvider(
      service: "test.service", account: "test.account", keychain: keychain)

    let created = try provider.loadOrCreateKey()
    let reused = try provider.loadOrCreateKey()

    XCTAssertEqual(created.count, 32)
    XCTAssertEqual(reused, created)
    XCTAssertEqual(keychain.addCount, 1)
    XCTAssertEqual(keychain.lastService, "test.service")
    XCTAssertEqual(keychain.lastAccount, "test.account")
  }

  func testKeychainProviderUsesWinnerOfConcurrentCreateRace() throws {
    let winner = testKey(0x19)
    let keychain = TestProjectSnapshotKeychainAccess(
      addStatus: errSecDuplicateItem, raceWinnerKey: winner)
    let provider = KeychainProjectSnapshotKeyProvider(keychain: keychain)

    XCTAssertEqual(try provider.loadOrCreateKey(), winner)
    XCTAssertEqual(keychain.readCount, 2)
    XCTAssertEqual(keychain.addCount, 1)
  }

  func testKeychainProviderRejectsMalformedKeyAndPropagatesAvailability() throws {
    let malformedKeychain = TestProjectSnapshotKeychainAccess(storedKey: Data([1, 2, 3]))
    let malformedProvider = KeychainProjectSnapshotKeyProvider(keychain: malformedKeychain)
    XCTAssertThrowsError(try malformedProvider.loadOrCreateKey()) { error in
      XCTAssertEqual(error as? ProjectSnapshotKeyProviderError, .invalidKeyMaterial)
    }

    let unavailableKeychain = TestProjectSnapshotKeychainAccess(
      readStatus: errSecInteractionNotAllowed)
    let unavailableProvider = KeychainProjectSnapshotKeyProvider(keychain: unavailableKeychain)
    XCTAssertThrowsError(try unavailableProvider.loadOrCreateKey()) { error in
      XCTAssertEqual(
        error as? ProjectSnapshotKeyProviderError,
        .unavailable(errSecInteractionNotAllowed))
    }
  }

  func testKeychainProviderDeletionIsIdempotentAndSurfacesFailure() throws {
    let missingKeychain = TestProjectSnapshotKeychainAccess(deleteStatus: errSecItemNotFound)
    XCTAssertNoThrow(
      try KeychainProjectSnapshotKeyProvider(keychain: missingKeychain).deleteKey())

    let unavailableKeychain = TestProjectSnapshotKeychainAccess(
      deleteStatus: errSecInteractionNotAllowed)
    XCTAssertThrowsError(
      try KeychainProjectSnapshotKeyProvider(keychain: unavailableKeychain).deleteKey()
    ) { error in
      XCTAssertEqual(
        error as? ProjectSnapshotKeyProviderError,
        .unavailable(errSecInteractionNotAllowed))
    }
  }

  func testLegacyPlaintextSnapshotMigratesAtomicallyToEncryptedV2() throws {
    let keyProvider = TestProjectSnapshotKeyProvider(key: testKey(0x22))
    let store = makeTemporaryStore(keyProvider: keyProvider)
    let snapshot = makeSnapshot(sourceReference: nil)
    let legacyData = try makeLegacyEnvelope(snapshot)
    try FileManager.default.createDirectory(
      at: store.directoryURL, withIntermediateDirectories: true)
    try legacyData.write(to: store.snapshotURL, options: .atomic)

    XCTAssertEqual(try store.load(), snapshot)

    let migratedData = try Data(contentsOf: store.snapshotURL)
    XCTAssertNotEqual(migratedData, legacyData)
    XCTAssertEqual(try decodeEncryptedEnvelope(migratedData).version, 2)
    XCTAssertNil(migratedData.range(of: Data("Recovered evidence".utf8)))
    XCTAssertEqual(try store.load(), snapshot)
  }

  func testLegacyMigrationFailurePreservesOriginalBytesAndStillRecovers() throws {
    let keyProvider = TestProjectSnapshotKeyProvider(key: testKey(0x33))
    keyProvider.loadFailure = .unavailable(errSecInteractionNotAllowed)
    let store = makeTemporaryStore(keyProvider: keyProvider)
    let snapshot = makeSnapshot(sourceReference: nil)
    let legacyData = try makeLegacyEnvelope(snapshot)
    try FileManager.default.createDirectory(
      at: store.directoryURL, withIntermediateDirectories: true)
    try legacyData.write(to: store.snapshotURL, options: .atomic)

    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(try Data(contentsOf: store.snapshotURL), legacyData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.quarantinedSnapshotURL.path))

    keyProvider.loadFailure = nil
    XCTAssertEqual(try store.load(), snapshot)
    XCTAssertEqual(try decodeEncryptedEnvelope(Data(contentsOf: store.snapshotURL)).version, 2)
  }

  func testCiphertextTamperingFailsAuthentication() throws {
    let store = makeTemporaryStore()
    try store.save(makeSnapshot(sourceReference: nil))
    var envelope = try decodeEncryptedEnvelope(Data(contentsOf: store.snapshotURL))
    envelope.sealedPayload[envelope.sealedPayload.index(before: envelope.sealedPayload.endIndex)] ^=
      1
    try encodeEnvelope(envelope).write(to: store.snapshotURL, options: .atomic)

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? ProjectSnapshotError, .authenticationFailed)
    }
  }

  func testSuccessfulNewSaveDoesNotDeleteQuarantinedRecoveryBytes() throws {
    let store = makeTemporaryStore()
    try store.save(makeSnapshot(sourceReference: nil))
    store.quarantineUnreadableSnapshot()
    let quarantinedData = try Data(contentsOf: store.quarantinedSnapshotURL)

    try store.save(makeSnapshot(sourceReference: nil))

    XCTAssertEqual(try Data(contentsOf: store.quarantinedSnapshotURL), quarantinedData)
    XCTAssertEqual(try store.load(), makeSnapshot(sourceReference: nil))
  }

  func testWrongKeyIsDistinguishedAndQuarantinedByStudioModel() throws {
    let directory = makeTemporaryDirectory()
    let originalStore = ProjectSnapshotStore(
      directoryURL: directory,
      keyProvider: TestProjectSnapshotKeyProvider(key: testKey(0x44)))
    try originalStore.save(makeSnapshot(sourceReference: nil))
    let wrongKeyStore = ProjectSnapshotStore(
      directoryURL: directory,
      keyProvider: TestProjectSnapshotKeyProvider(key: testKey(0x45)))

    XCTAssertThrowsError(try wrongKeyStore.load()) { error in
      XCTAssertEqual(error as? ProjectSnapshotError, .encryptionKeyMismatch)
    }

    let model = StudioModel(snapshotStore: wrongKeyStore)
    XCTAssertEqual(model.phase, .empty)
    XCTAssertTrue(model.sessionNotice?.contains("different recovery key") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: wrongKeyStore.snapshotURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: wrongKeyStore.quarantinedSnapshotURL.path))
  }

  func testTransientKeychainFailureKeepsEncryptedSnapshotForRetry() throws {
    let keyProvider = TestProjectSnapshotKeyProvider(key: testKey(0x55))
    let store = makeTemporaryStore(keyProvider: keyProvider)
    let snapshot = makeSnapshot(sourceReference: nil)
    try store.save(snapshot)
    let encryptedData = try Data(contentsOf: store.snapshotURL)
    keyProvider.loadFailure = .unavailable(errSecInteractionNotAllowed)

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(
        error as? ProjectSnapshotError,
        .encryptionKeyUnavailable(errSecInteractionNotAllowed))
    }

    let model = StudioModel(snapshotStore: store)
    XCTAssertEqual(model.phase, .empty)
    XCTAssertTrue(model.sessionNotice?.contains("kept safely in place") == true)
    XCTAssertEqual(try Data(contentsOf: store.snapshotURL), encryptedData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.quarantinedSnapshotURL.path))

    keyProvider.loadFailure = nil
    XCTAssertEqual(try store.load(), snapshot)
  }

  func testMissingKeyDoesNotCreateReplacementOrQuarantineSnapshot() throws {
    let keyProvider = TestProjectSnapshotKeyProvider(key: testKey(0x56))
    let store = makeTemporaryStore(keyProvider: keyProvider)
    try store.save(makeSnapshot(sourceReference: nil))
    let encryptedData = try Data(contentsOf: store.snapshotURL)
    keyProvider.discardKey()

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? ProjectSnapshotError, .encryptionKeyMissing)
    }
    XCTAssertNil(keyProvider.currentKey, "Loading must not create a replacement key")

    let model = StudioModel(snapshotStore: store)
    XCTAssertEqual(model.phase, .empty)
    XCTAssertTrue(model.sessionNotice?.contains("could not be found") == true)
    XCTAssertEqual(try Data(contentsOf: store.snapshotURL), encryptedData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.quarantinedSnapshotURL.path))
    XCTAssertNil(keyProvider.currentKey)
  }

  func testResetRemovesCiphertextsBeforeRetiringEncryptionKey() throws {
    let directory = makeTemporaryDirectory()
    let keyProvider = TestProjectSnapshotKeyProvider(key: testKey(0x66))
    keyProvider.pathsObservedDuringDelete = [
      directory.appendingPathComponent("CurrentProject.vnsnapshot"),
      directory.appendingPathComponent("UnrecoverableProject.vnsnapshot"),
    ]
    let store = ProjectSnapshotStore(directoryURL: directory, keyProvider: keyProvider)
    try store.save(makeSnapshot(sourceReference: nil))
    try Data("diagnostic ciphertext".utf8).write(
      to: store.quarantinedSnapshotURL, options: .atomic)

    try store.remove()

    XCTAssertEqual(keyProvider.deleteCount, 1)
    XCTAssertTrue(keyProvider.allObservedPathsWereAbsentDuringDelete)
    XCTAssertNil(keyProvider.currentKey)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.quarantinedSnapshotURL.path))
  }

  func testKeyDeletionFailureSurfacesAfterSnapshotDataIsRemoved() throws {
    let keyProvider = TestProjectSnapshotKeyProvider(key: testKey(0x77))
    keyProvider.deleteFailure = .unavailable(errSecInteractionNotAllowed)
    let store = makeTemporaryStore(keyProvider: keyProvider)
    try store.save(makeSnapshot(sourceReference: nil))

    XCTAssertThrowsError(try store.remove()) { error in
      XCTAssertEqual(
        error as? ProjectSnapshotError,
        .encryptionKeyUnavailable(errSecInteractionNotAllowed))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    XCTAssertEqual(keyProvider.currentKey, testKey(0x77))
  }

  func testEncryptedSnapshotRetainsPrivateFileAttributes() throws {
    let store = makeTemporaryStore()
    try store.save(makeSnapshot(sourceReference: nil))

    #if os(macOS)
      let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: store.directoryURL.path)
      let snapshotAttributes = try FileManager.default.attributesOfItem(
        atPath: store.snapshotURL.path)
      XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
      XCTAssertEqual((snapshotAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    #endif
    let resourceValues = try store.snapshotURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
  }

  func testCorruptSnapshotFailsSafelyAndCanBeQuarantined() throws {
    let store = makeTemporaryStore()
    try FileManager.default.createDirectory(
      at: store.directoryURL, withIntermediateDirectories: true)
    try Data("not a VideoNotes snapshot".utf8).write(to: store.snapshotURL, options: .atomic)

    XCTAssertThrowsError(try store.load())
    store.quarantineUnreadableSnapshot()

    XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.quarantinedSnapshotURL.path))
    XCTAssertNil(try store.load())
  }

  func testStudioModelRestoresUsableNotesWhenOriginalSourceIsMissing() async throws {
    let store = makeTemporaryStore()
    let missingSource = store.directoryURL.appendingPathComponent("moved-source.mov")
    try store.save(
      makeSnapshot(
        sourceReference: ProjectSourceReference(
          bookmarkData: nil, fallbackPath: missingSource.path)))

    let model = StudioModel(snapshotStore: store)

    XCTAssertEqual(model.sourceName, "Recovery Lecture")
    XCTAssertNil(model.sourceURL)
    XCTAssertEqual(model.sourceEvidence.map(\.detail), ["Recovered evidence", "Visible concept"])
    XCTAssertFalse(model.readingPages.isEmpty)
    XCTAssertEqual(
      model.currentPage, 0, "Restored positions are clamped to the recovered page count")
    XCTAssertTrue(
      model.sessionNotice?.contains("original media is no longer available") == true)
    XCTAssertFalse(model.sessionNoticeIsSuccess)
    XCTAssertTrue(model.phase == .illustrating || model.phase == .ready)

    let becameExportable = await waitUntil { model.isExportReady }
    XCTAssertTrue(becameExportable, "Recovered semantic notes did not rerender into usable output")
    XCTAssertFalse(model.pdfData()?.isEmpty ?? true)
    XCTAssertFalse(model.semanticNotes(format: .markdown)?.isEmpty ?? true)
  }

  func testStudioModelQuarantinesCorruptAutosaveAndStartsEmpty() throws {
    let store = makeTemporaryStore()
    try FileManager.default.createDirectory(
      at: store.directoryURL, withIntermediateDirectories: true)
    try Data([0x00, 0xFF, 0x13, 0x37]).write(to: store.snapshotURL, options: .atomic)

    let model = StudioModel(snapshotStore: store)

    XCTAssertEqual(model.phase, .empty)
    XCTAssertTrue(model.pages.isEmpty)
    XCTAssertTrue(model.sourceEvidence.isEmpty)
    XCTAssertTrue(model.sessionNotice?.contains("damaged or incompatible") == true)
    XCTAssertFalse(model.sessionNoticeIsSuccess)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.quarantinedSnapshotURL.path))
  }

  func testStudioModelMarksCleanAutosaveRestoreAsSuccessfulFeedback() throws {
    let store = makeTemporaryStore()
    try FileManager.default.createDirectory(
      at: store.directoryURL, withIntermediateDirectories: true)
    let source = store.directoryURL.appendingPathComponent("source.mov")
    try Data("fixture".utf8).write(to: source)
    try store.save(
      makeSnapshot(
        sourceReference: ProjectSourceReference(bookmarkData: nil, fallbackPath: source.path)))

    let model = StudioModel(snapshotStore: store)

    XCTAssertTrue(model.sessionNotice?.contains("Restored") == true)
    XCTAssertTrue(model.sessionNoticeIsSuccess)
  }

  func testSourceReferenceUsesExistingLocalFallbackAndRejectsMissingFile() throws {
    let store = makeTemporaryStore()
    try FileManager.default.createDirectory(
      at: store.directoryURL, withIntermediateDirectories: true)
    let source = store.directoryURL.appendingPathComponent("source.mov")
    try Data("fixture".utf8).write(to: source)

    let available = ProjectSourceReference(bookmarkData: nil, fallbackPath: source.path).resolve()
    let missing = ProjectSourceReference(
      bookmarkData: nil, fallbackPath: source.appendingPathExtension("missing").path
    ).resolve()

    XCTAssertEqual(available, .available(source.standardizedFileURL, bookmarkWasStale: true))
    XCTAssertEqual(missing, .unavailable)
  }

  func testSnapshotValidationRejectsInvalidAndUnboundedState() {
    var snapshot = makeSnapshot(sourceReference: nil)
    snapshot.style.paletteIndex = Int.max
    snapshot.currentPage = -1

    XCTAssertThrowsError(try snapshot.validate()) { error in
      XCTAssertEqual(error as? ProjectSnapshotError, .invalidContents)
    }
  }

  func testLifecycleFlushPersistsLatestStyleAndPagePosition() async throws {
    let store = makeTemporaryStore()
    try store.save(makeSnapshot(sourceReference: nil))
    let model = StudioModel(snapshotStore: store)

    model.presentationFormat = .detailed
    model.pdfPageFormat = .usLetter
    model.compact = false
    model.currentPage = 1
    model.persistProjectForLifecycleTransition()

    let persisted = await waitForSnapshot(in: store) { snapshot in
      snapshot.style.presentationFormat == NotePresentationFormat.detailed.rawValue
        && snapshot.style.pdfPageFormat == PDFPageFormat.usLetter.rawValue
        && !snapshot.style.compact && snapshot.currentPage == 1
    }
    XCTAssertTrue(persisted, "Foreground changes were not flushed into the recovery snapshot")
  }

  func testResetRemovesPrivateRecoveryData() async throws {
    let store = makeTemporaryStore()
    try store.save(makeSnapshot(sourceReference: nil))
    let model = StudioModel(snapshotStore: store)

    model.reset()

    let removed = await waitUntil {
      !FileManager.default.fileExists(atPath: store.snapshotURL.path)
        && !FileManager.default.fileExists(atPath: store.quarantinedSnapshotURL.path)
    }
    XCTAssertTrue(removed, "Start New left private recovery data on disk")
  }

  private func makeTemporaryStore(
    keyProvider: TestProjectSnapshotKeyProvider = TestProjectSnapshotKeyProvider(
      key: Data(repeating: 0xA5, count: 32))
  ) -> ProjectSnapshotStore {
    ProjectSnapshotStore(directoryURL: makeTemporaryDirectory(), keyProvider: keyProvider)
  }

  private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VideoNotesTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func makeSnapshot(sourceReference: ProjectSourceReference?) -> ProjectSnapshot {
    let content = ExtractedContent(
      sourceName: "Recovery Lecture", duration: 90,
      transcript: [TranscriptSegment(start: 3, end: 7, text: "Recovered evidence")],
      visuals: [VisualMoment(time: 12, lines: ["Visible concept"])])
    let document = NoteDocument(
      title: "Recovery Lecture", subtitle: "Private local project",
      sections: [
        .concept(
          heading: "Grounded Concept", body: "The recovered explanation.",
          points: ["One retained point"], iconHints: ["shield"], quote: nil,
          sourceTime: 3)
      ])
    return ProjectSnapshot(
      savedAt: Date(timeIntervalSince1970: 1_800_000_000), sourceName: "Recovery Lecture",
      sourceReference: sourceReference, document: document, content: content, baseSeed: 42,
      style: ProjectSnapshot.Style(
        paletteIndex: 0, compact: true,
        presentationFormat: NotePresentationFormat.evidenceFirst.rawValue,
        pdfPageFormat: PDFPageFormat.a4.rawValue, seedBump: 5),
      currentPage: 1)
  }

  private func waitForSnapshot(
    in store: ProjectSnapshotStore,
    matching predicate: @escaping (ProjectSnapshot) -> Bool
  ) async -> Bool {
    await waitUntil {
      guard let snapshot = try? store.load() else { return false }
      return predicate(snapshot)
    }
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ predicate: @escaping () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while clock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return predicate()
  }

  private func testKey(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: 32)
  }

  private struct TestEncryptedEnvelope: Codable {
    var version: Int
    var algorithm: String
    var keyIdentifier: Data
    var sealedPayload: Data
  }

  private struct TestLegacyEnvelope: Codable {
    var version: Int
    var payload: Data
    var checksum: Data
  }

  private func decodeEncryptedEnvelope(_ data: Data) throws -> TestEncryptedEnvelope {
    try JSONDecoder().decode(TestEncryptedEnvelope.self, from: data)
  }

  private func encodeEnvelope(_ envelope: TestEncryptedEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(envelope)
  }

  private func makeLegacyEnvelope(_ snapshot: ProjectSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(snapshot)
    return try encoder.encode(
      TestLegacyEnvelope(
        version: 1, payload: payload, checksum: Data(SHA256.hash(data: payload))))
  }
}

private final class TestProjectSnapshotKeyProvider: ProjectSnapshotKeyProvider,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var key: Data?
  private var storedLoadFailure: ProjectSnapshotKeyProviderError?
  private var storedDeleteFailure: ProjectSnapshotKeyProviderError?
  private var storedLoadCount = 0
  private var storedDeleteCount = 0
  private var observedPaths: [URL] = []
  private var storedAllObservedPathsWereAbsentDuringDelete = false

  init(key: Data) { self.key = key }

  var loadFailure: ProjectSnapshotKeyProviderError? {
    get { lock.withLock { storedLoadFailure } }
    set { lock.withLock { storedLoadFailure = newValue } }
  }

  var deleteFailure: ProjectSnapshotKeyProviderError? {
    get { lock.withLock { storedDeleteFailure } }
    set { lock.withLock { storedDeleteFailure = newValue } }
  }

  var pathsObservedDuringDelete: [URL] {
    get { lock.withLock { observedPaths } }
    set { lock.withLock { observedPaths = newValue } }
  }

  var currentKey: Data? { lock.withLock { key } }
  var loadCount: Int { lock.withLock { storedLoadCount } }
  var deleteCount: Int { lock.withLock { storedDeleteCount } }
  var allObservedPathsWereAbsentDuringDelete: Bool {
    lock.withLock { storedAllObservedPathsWereAbsentDuringDelete }
  }

  func discardKey() { lock.withLock { key = nil } }

  func loadKey() throws -> Data? {
    try lock.withLock {
      storedLoadCount += 1
      if let storedLoadFailure { throw storedLoadFailure }
      return key
    }
  }

  func loadOrCreateKey() throws -> Data {
    if let existing = try loadKey() { return existing }
    return lock.withLock {
      let newKey = Data(repeating: 0xC3, count: 32)
      key = newKey
      return newKey
    }
  }

  func deleteKey() throws {
    try lock.withLock {
      storedDeleteCount += 1
      storedAllObservedPathsWereAbsentDuringDelete = observedPaths.allSatisfy {
        !FileManager.default.fileExists(atPath: $0.path)
      }
      if let storedDeleteFailure { throw storedDeleteFailure }
      key = nil
    }
  }
}

private final class TestProjectSnapshotKeychainAccess: ProjectSnapshotKeychainAccess,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedKey: Data?
  private var storedReadStatus: OSStatus
  private var storedAddStatus: OSStatus
  private var storedDeleteStatus: OSStatus
  private let raceWinnerKey: Data?
  private var storedReadCount = 0
  private var storedAddCount = 0
  private var storedLastService: String?
  private var storedLastAccount: String?

  init(
    storedKey: Data? = nil, readStatus: OSStatus = errSecSuccess,
    addStatus: OSStatus = errSecSuccess, deleteStatus: OSStatus = errSecSuccess,
    raceWinnerKey: Data? = nil
  ) {
    self.storedKey = storedKey
    storedReadStatus = readStatus
    storedAddStatus = addStatus
    storedDeleteStatus = deleteStatus
    self.raceWinnerKey = raceWinnerKey
  }

  var readCount: Int { lock.withLock { storedReadCount } }
  var addCount: Int { lock.withLock { storedAddCount } }
  var lastService: String? { lock.withLock { storedLastService } }
  var lastAccount: String? { lock.withLock { storedLastAccount } }

  func read(service: String, account: String) -> (data: Data?, status: OSStatus) {
    lock.withLock {
      storedReadCount += 1
      storedLastService = service
      storedLastAccount = account
      guard storedReadStatus == errSecSuccess else { return (nil, storedReadStatus) }
      guard let storedKey else { return (nil, errSecItemNotFound) }
      return (storedKey, errSecSuccess)
    }
  }

  func add(_ key: Data, service: String, account: String) -> OSStatus {
    lock.withLock {
      storedAddCount += 1
      storedLastService = service
      storedLastAccount = account
      if storedAddStatus == errSecSuccess {
        storedKey = key
      } else if storedAddStatus == errSecDuplicateItem, let raceWinnerKey {
        storedKey = raceWinnerKey
      }
      return storedAddStatus
    }
  }

  func delete(service: String, account: String) -> OSStatus {
    lock.withLock {
      storedLastService = service
      storedLastAccount = account
      if storedDeleteStatus == errSecSuccess { storedKey = nil }
      return storedDeleteStatus
    }
  }
}
