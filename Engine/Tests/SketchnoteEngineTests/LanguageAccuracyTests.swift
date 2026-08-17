import Foundation
import XCTest

@testable import SketchnoteEngine

final class LanguageAccuracyTests: XCTestCase {
  func testEnglishTranscriptProducesEnglishLanguageMetadata() throws {
    let document = try HeuristicStructurer.structure(
      content(
        transcript: [
          TranscriptSegment(
            start: 0, end: 8,
            text: "The model learns from examples and the data determines the final result.")
        ]))

    XCTAssertEqual(document.language, "en")
  }

  func testGermanTranscriptProducesGermanMetadataLocalizedSummaryAndPreservesEvidence() throws {
    let rawOpening =
      "Also im Grunde verbessern sorgfältig geprüfte Trainingsdaten die Qualität des Modells."
    let rawClosing =
      "Danach vergleichen wir das Ergebnis mit unabhängigen Beispielen aus der Praxis."
    let document = try HeuristicStructurer.structure(
      content(
        transcript: [
          TranscriptSegment(start: 0, end: 8, text: rawOpening),
          TranscriptSegment(start: 15, end: 24, text: rawClosing),
        ],
        visuals: [VisualMoment(time: 1, lines: ["Machine Learning Overview"])],
        duration: 30))

    XCTAssertEqual(document.language, "de")
    XCTAssertTrue(
      document.sections.contains {
        if case .concept(_, let body, _, _, _, _, _) = $0 { return body == rawOpening }
        return false
      }, "the original transcript sentence must remain unchanged as evidence")
    XCTAssertTrue(
      document.sections.contains {
        if case .summary(let heading, _, _) = $0 {
          return heading == "Wichtigste Erkenntnisse"
        }
        return false
      })
  }

  func testGermanCompressionAndKeywordFilteringAreLocaleAware() {
    XCTAssertEqual(
      HeuristicStructurer.compress(
        "Also im Grunde lernt das Modell aus geprüften Beispielen.", language: .german),
      "Lernt das Modell aus geprüften Beispielen")
    XCTAssertEqual(
      Keywords.contentWords("Die Daten und das Modell sind wichtig", language: .german),
      ["daten", "modell", "wichtig"])
    XCTAssertTrue(
      HeuristicStructurer.headingSuggestsList(
        "Drei Methoden für zuverlässige Ergebnisse", language: .german))
    XCTAssertEqual(
      HeuristicStructurer.versusSplit(
        "Lokales Modell im Vergleich zu Cloud-Modell", language: .german)?.0,
      "Lokales Modell")
  }

  func testGermanListMarkerBuildsProcessSection() throws {
    let document = try HeuristicStructurer.structure(
      content(
        transcript: [
          TranscriptSegment(
            start: 0, end: 5,
            text: "Zuerst sammeln wir geprüfte Beispiele für das Training."),
          TranscriptSegment(
            start: 6, end: 11,
            text: "Danach bewerten wir das trainierte Modell mit neuen Daten."),
        ],
        visuals: [VisualMoment(time: 1, lines: ["Zwei Schritte für das Training"])],
        duration: 15))

    XCTAssertTrue(
      document.sections.contains {
        if case .process(let heading, let steps, _, _, _) = $0 {
          return heading == "Zwei Schritte für das Training" && steps.count == 2
        }
        return false
      })
  }

  func testGermanVersusAndDefinitionMarkersBuildSemanticSections() throws {
    let comparison = try HeuristicStructurer.structure(
      content(
        transcript: [
          TranscriptSegment(
            start: 0, end: 5,
            text: "Überwachtes Lernen nutzt gekennzeichnete Beispiele für das Training."),
          TranscriptSegment(
            start: 6, end: 11,
            text: "Unüberwachtes Lernen erkennt Strukturen in Daten ohne Kennzeichnungen."),
        ],
        visuals: [
          VisualMoment(
            time: 1, lines: ["Überwachtes Lernen gegen Unüberwachtes Lernen"])
        ], duration: 15))
    XCTAssertTrue(
      comparison.sections.contains {
        if case .comparison = $0 { return true }
        return false
      })

    let definitionSpan = HeuristicStructurer.Span(
      start: 0, end: 8,
      sentences: [
        TranscriptSegment(
          start: 0, end: 8,
          text: "Maschinelles Lernen bedeutet das Erkennen von Mustern in geprüften Daten.")
      ], slide: nil)
    let definition = HeuristicStructurer.makeSection(from: definitionSpan, language: .german)
    guard case .definition(let term, let meaning, _) = definition else {
      return XCTFail("expected a German definition section")
    }
    XCTAssertEqual(term, "Maschinelles Lernen")
    XCTAssertEqual(meaning, "das Erkennen von Mustern in geprüften Daten.")
  }

  func testGermanQuoteMarkerKeepsTheVerbatimQuote() throws {
    let quote =
      "Entscheidend ist, dass jedes Ergebnis mit unabhängigen Quelldaten überprüft werden muss."
    let document = try HeuristicStructurer.structure(
      content(
        transcript: [
          TranscriptSegment(
            start: 0, end: 5,
            text: "Wir prüfen das trainierte Modell anschließend mit neuen Beispielen."),
          TranscriptSegment(start: 6, end: 14, text: quote),
        ], duration: 18))

    let retainedQuotes = document.sections.flatMap { section -> [String] in
      switch section {
      case .concept(_, _, _, _, let value, _, _): return value.map { [$0] } ?? []
      case .quote(let value, _, _): return [value]
      default: return []
      }
    }
    XCTAssertEqual(retainedQuotes, [quote])
  }

  func testGermanVisualOnlyFallbackHeadingIsLocalized() throws {
    let document = try HeuristicStructurer.structure(
      content(
        visuals: [
          VisualMoment(time: 0, lines: ["Drei Schritte für das Lernen"]),
          VisualMoment(time: 20, lines: []),
        ], duration: 30))

    XCTAssertEqual(document.language, "de")
    XCTAssertTrue(document.sections.contains { $0.heading == "Auf dem Bildschirm um 00:20" })
  }

  func testUnsupportedLanguageSafelyRemainsUndetermined() throws {
    let document = try HeuristicStructurer.structure(
      content(
        transcript: [
          TranscriptSegment(start: 0, end: 5, text: "这是一个关于机器学习和可靠数据的课程。")
        ]))

    XCTAssertEqual(document.language, "und")
  }

  func testSpeechFallbackNeverCrossesTheRequestedLanguageFamily() {
    let supported: Set<Locale> = [
      Locale(identifier: "de-DE"), Locale(identifier: "en-US"), Locale(identifier: "fr-FR"),
    ]

    let german = Transcriber.recognitionLocale(
      requested: Locale(identifier: "de-AT"), supported: supported)
    XCTAssertEqual(german?.language.languageCode?.identifier, "de")
    XCTAssertNotEqual(german?.language.languageCode?.identifier, "en")

    let unsupported = Transcriber.recognitionLocale(
      requested: Locale(identifier: "ja-JP"), supported: supported)
    XCTAssertNil(unsupported)

    let frenchOnly: Set<Locale> = [Locale(identifier: "fr-CA"), Locale(identifier: "en-US")]
    let french = Transcriber.recognitionLocale(
      requested: Locale(identifier: "fr-FR"), supported: frenchOnly)
    XCTAssertEqual(french?.language.languageCode?.identifier, "fr")
  }

  func testSpeechLocalePrefersRequestThenSourceThenDevice() {
    let device = Locale(identifier: "en-US")
    let source = Transcriber.preferredLocale(
      requested: nil, sourceLanguageTag: "de-DE", deviceLocale: device)
    XCTAssertEqual(source.language.languageCode?.identifier, "de")

    let requested = Transcriber.preferredLocale(
      requested: Locale(identifier: "fr-FR"), sourceLanguageTag: "de-DE",
      deviceLocale: device)
    XCTAssertEqual(requested.language.languageCode?.identifier, "fr")

    let fallback = Transcriber.preferredLocale(
      requested: nil, sourceLanguageTag: "und", deviceLocale: device)
    XCTAssertEqual(fallback.language.languageCode?.identifier, "en")
  }

  private func content(
    transcript: [TranscriptSegment] = [], visuals: [VisualMoment] = [], duration: Double = 60
  ) -> ExtractedContent {
    ExtractedContent(
      sourceName: "Sprachtest", duration: duration, transcript: transcript, visuals: visuals)
  }
}
