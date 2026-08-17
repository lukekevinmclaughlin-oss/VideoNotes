import XCTest
import SketchnoteEngine

@testable import VideoNotes

@MainActor
final class GroundingAuditAppTests: XCTestCase {
  func testVerifiedSourceIllustrationsDoNotAddReviewWarning() {
    let report = StudioModel.GroundingReport(
      duration: 60, transcriptSegments: 4, visualMoments: 3, tracedVisuals: 2,
      citedSections: 3, synthesizedSections: 0, sourceIllustrations: 2,
      verifiedSourceIllustrations: 2)

    XCTAssertEqual(report.illustrationLabel, "2 source-matched drawings")
    XCTAssertFalse(report.requiresReview)
  }

  func testUnverifiedSourceIllustrationRequiresReview() {
    let report = StudioModel.GroundingReport(
      duration: 60, transcriptSegments: 4, visualMoments: 3, tracedVisuals: 2,
      citedSections: 3, synthesizedSections: 0, sourceIllustrations: 2,
      verifiedSourceIllustrations: 1)

    XCTAssertEqual(report.illustrationLabel, "1 of 2 drawings source-matched")
    XCTAssertTrue(report.requiresReview)
  }

  func testSemanticExportsCarryDetectedSourceLanguage() throws {
    let document = NoteDocument(
      title: "Lektion", language: "de",
      sections: [
        .concept(
          heading: "Datenqualität", body: "Geprüfte Beispiele", points: [], iconHints: [],
          quote: nil, sourceTime: 4)
      ])

    let html = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .html, document: document, sourceName: "Lektion.mov",
        presentationFormat: .evidenceFirst, evidenceCoverage: "Source-cited"))
    XCTAssertTrue(try XCTUnwrap(String(data: html, encoding: .utf8)).contains("<html lang=\"de\">"))

    let json = try XCTUnwrap(
      SemanticNoteExporter.make(
        format: .json, document: document, sourceName: "Lektion.mov",
        presentationFormat: .evidenceFirst, evidenceCoverage: "Source-cited"))
    let export = try JSONDecoder().decode(SemanticNoteExportEnvelope.self, from: json)
    XCTAssertEqual(export.language, "de")
  }
}
