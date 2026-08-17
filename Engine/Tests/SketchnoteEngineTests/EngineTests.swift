import CoreGraphics
import PDFKit
import XCTest

@testable import SketchnoteEngine

final class SNMTests: XCTestCase {
  func testSanitizePreservesSectionsAndClaimPayloads() {
    let originalPoints = (0..<12).map { "Point \($0) " + String(repeating: "x", count: 200) }
    let sections = (0..<15).map { i in
      NoteSection.concept(
        heading: String(repeating: "H", count: 300),
        body: "Complete explanatory body \(i) " + String(repeating: "evidence ", count: 80),
        points: originalPoints,
        iconHints: [], quote: nil, sourceTime: Double(i))
    }
    let doc = SNMValidation.sanitize(
      NoteDocument(title: String(repeating: "T", count: 200), sections: sections))
    XCTAssertEqual(doc.sections.count, sections.count)
    XCTAssertLessThanOrEqual(doc.title.count, SNMLimits.maxHeadingLength + 1)
    if case .concept(let h, let body, let points, _, _, _, _) = doc.sections[0] {
      XCTAssertLessThanOrEqual(h.count, SNMLimits.maxHeadingLength + 1)
      XCTAssertEqual(
        body, "Complete explanatory body 0 " + String(repeating: "evidence ", count: 80))
      XCTAssertEqual(points, originalPoints)
    } else {
      XCTFail("expected concept")
    }
  }

  func testClipCutsAtWordBoundary() {
    let clipped = SNMValidation.clip("alpha bravo charlie delta echo foxtrot", 20)
    XCTAssertTrue(clipped.hasSuffix("…"))
    XCTAssertFalse(clipped.dropLast().hasSuffix(" "))
    XCTAssertLessThanOrEqual(clipped.count, 21)
  }

  func testRoundTripCodable() throws {
    let doc = NoteDocument(
      title: "T", subtitle: "S",
      sections: [
        .concept(
          heading: "H", body: "B", points: ["p"], iconHints: ["brain"], quote: "Q", sourceTime: 1),
        .methods(heading: "M", columns: [MethodColumn(title: "C", steps: ["s"])], sourceTime: 2),
        .quote(text: "quoted", attribution: "someone", sourceTime: 3),
        .summary(heading: "Key", points: ["a", "b"], sourceTime: nil),
      ])
    let data = try JSONEncoder().encode(doc)
    let back = try JSONDecoder().decode(NoteDocument.self, from: data)
    XCTAssertEqual(doc, back)
  }
}

final class StructurerTests: XCTestCase {
  func content(
    transcript: [TranscriptSegment] = [], visuals: [VisualMoment] = [], duration: Double = 300
  ) -> ExtractedContent {
    ExtractedContent(
      sourceName: "Test Lecture", duration: duration, transcript: transcript, visuals: visuals)
  }

  func testThrowsOnEmptyContent() {
    XCTAssertThrowsError(try HeuristicStructurer.structure(content()))
  }

  func testSlideOnlyProducesSections() throws {
    let visuals = [
      VisualMoment(
        time: 10,
        lines: ["Neural Networks 101", "Weights encode relationships", "Layers transform input"]),
      VisualMoment(
        time: 120,
        lines: [
          "Forward Propagation", "1. Weighted sum", "2. Activation", "3. Output to next layer",
        ]),
      VisualMoment(time: 240, lines: ["Gradient Descent", "Loss measures error"]),
    ]
    let doc = try HeuristicStructurer.structure(content(visuals: visuals))
    XCTAssertEqual(doc.title, "Neural Networks 101")
    XCTAssertGreaterThanOrEqual(doc.sections.count, 2)
    // slide 2 is enumerated → process section with 3 steps
    let process = doc.sections.compactMap { section -> [String]? in
      if case .process(_, let steps, _, _, _) = section { return steps }
      return nil
    }
    XCTAssertTrue(process.contains { $0.count == 3 }, "expected a 3-step process section")
  }

  func testTranscriptOnlySegmentsByPauses() throws {
    var segments: [TranscriptSegment] = []
    var t = 0.0
    for block in 0..<3 {
      for s in 0..<4 {
        segments.append(
          TranscriptSegment(
            start: t, end: t + 4,
            text: "Topic \(block) sentence \(s) about neural networks and learning systems."))
        t += 4.2
      }
      t += 6  // pause > 2.5 s → boundary
    }
    let doc = try HeuristicStructurer.structure(content(transcript: segments, duration: t))
    XCTAssertGreaterThanOrEqual(doc.sections.count, 3)
  }

  func testDeterminism() throws {
    let visuals = [
      VisualMoment(time: 5, lines: ["Title Slide", "Some point about data"]),
      VisualMoment(time: 60, lines: ["Second Slide", "More content here"]),
    ]
    let transcript = [
      TranscriptSegment(
        start: 0, end: 30, text: "The key is that models learn from examples and improve over time."
      )
    ]
    let a = try HeuristicStructurer.structure(content(transcript: transcript, visuals: visuals))
    let b = try HeuristicStructurer.structure(content(transcript: transcript, visuals: visuals))
    XCTAssertEqual(a, b)
  }

  func testVersusHeadingMakesComparison() throws {
    let visuals = [
      VisualMoment(
        time: 5,
        lines: ["Supervised vs Unsupervised", "labels drive training", "clusters emerge from data"])
    ]
    let transcript = [
      TranscriptSegment(
        start: 1, end: 5, text: "Supervised learning uses labeled examples to train models."),
      TranscriptSegment(
        start: 6, end: 10, text: "Unsupervised learning finds structure without any labels."),
    ]
    let doc = try HeuristicStructurer.structure(content(transcript: transcript, visuals: visuals))
    let hasComparison = doc.sections.contains {
      if case .comparison = $0 { return true }
      return false
    }
    XCTAssertTrue(hasComparison)
  }

  func testPullQuoteAttachesOnce() throws {
    let transcript = [
      TranscriptSegment(
        start: 0, end: 8,
        text: "Machine learning models transform industries through automation and insight."),
      TranscriptSegment(
        start: 9, end: 20,
        text:
          "Basically what you have done is you have created a system that learns the patterns for them."
      ),
    ]
    let doc = try HeuristicStructurer.structure(content(transcript: transcript, duration: 30))
    var quotes = 0
    for section in doc.sections {
      if case .quote = section { quotes += 1 }
      if case .concept(_, _, _, _, .some, _, _) = section { quotes += 1 }
    }
    XCTAssertEqual(quotes, 1)
  }

  func testCompressStripsFiller() {
    XCTAssertEqual(
      HeuristicStructurer.compress("so basically the model learns."), "The model learns")
    XCTAssertEqual(
      HeuristicStructurer.compress("And then you upload the files."), "You upload the files")
  }

  func testInjectedTranscriptParsing() {
    let parsed = Transcriber.parseInjected("0|4.5|Hello world\n5|9|Second sentence\nbroken line")
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed[0].text, "Hello world")
    XCTAssertEqual(parsed[1].start, 5)
  }

  func testPrefixLikeSlideMerging() {
    XCTAssertTrue(
      FrameSampler.isPrefixLike(
        previous: ["Title", "Point 1"],
        current: ["Title", "Point 1", "Point 2"]))
    XCTAssertFalse(
      FrameSampler.isPrefixLike(
        previous: ["Other slide", "Text"],
        current: ["Title", "Point 1", "Point 2"]))
  }

  func testTextSimilarityMergesMinorOCRFluctuationButNotNewSlide() {
    let original = ["Training Loop", "Forward pass", "Calculate loss", "Update weights"]
    let fluctuation = ["Training Loop", "Forward pass", "Calculate loss", "Update weight"]
    let different = ["Accuracy vs Speed", "More compute", "Less detail"]
    XCTAssertGreaterThanOrEqual(FrameSampler.textSimilarity(original, fluctuation), 0.86)
    XCTAssertLessThan(FrameSampler.textSimilarity(original, different), 0.4)
  }

  func testRepresentativeFramesKeepEndpointsAndLargeChanges() {
    let hashes: [UInt64] = [0, 0, 0, UInt64.max, UInt64.max, 0, 0, 0]
    let selected = FrameSampler.representativeIndices(hashes, limit: 4)
    XCTAssertEqual(selected.first, 0)
    XCTAssertEqual(selected.last, hashes.count - 1)
    XCTAssertTrue(
      selected.contains(3) || selected.contains(4), "major scene change should be represented")
    XCTAssertEqual(selected, selected.sorted())
  }

  func testTextSignaturePreservesDecimalsOperatorsAndLines() {
    XCTAssertNotEqual(FrameSampler.textSignature(["12.3%"]), FrameSampler.textSignature(["123%"]))
    XCTAssertNotEqual(FrameSampler.textSignature(["A-B"]), FrameSampler.textSignature(["AB"]))
    XCTAssertNotEqual(
      FrameSampler.textSignature(["A", "BC"]), FrameSampler.textSignature(["AB", "C"]))
  }

  func testSameOCRDifferentVisualHashIsNotDuplicate() {
    let moments = [
      VisualMoment(time: 4, lines: ["Results", "Accuracy 91%"]),
      VisualMoment(time: 12, lines: ["Results", "Accuracy 91%"]),
    ]
    let result = FrameSampler.deduplicatedVisualMoments(moments, hashes: [0, UInt64.max])
    XCTAssertEqual(result, moments, "same title/text over different visuals must remain distinct")
  }

  func testExactOCRVisuallySimilarFrameIsDuplicate() {
    let moments = [
      VisualMoment(time: 4, lines: ["Results", "Accuracy 91%"]),
      VisualMoment(time: 12, lines: ["Results", "Accuracy 91%"]),
    ]
    let result = FrameSampler.deduplicatedVisualMoments(moments, hashes: [0, 1])
    XCTAssertEqual(result, [moments[0]])
  }

  func testPrefixRevealNearbyAndVisuallySimilarReplacesEarlier() {
    let moments = [
      VisualMoment(time: 4, lines: ["Training", "Forward pass"]),
      VisualMoment(time: 12, lines: ["Training", "Forward pass", "Update weights"]),
    ]
    let result = FrameSampler.deduplicatedVisualMoments(moments, hashes: [0, 1])
    XCTAssertEqual(result, [moments[1]])
  }

  func testPrefixLikeTextOutsideTimeWindowDoesNotMerge() {
    let moments = [
      VisualMoment(time: 4, lines: ["Overview", "Inputs"]),
      VisualMoment(time: 80, lines: ["Overview", "Inputs", "Unrelated result"]),
    ]
    let result = FrameSampler.deduplicatedVisualMoments(moments, hashes: [0, 1])
    XCTAssertEqual(result, moments)
  }

  func testPrefixLikeTextWithDistantHashDoesNotMerge() {
    let moments = [
      VisualMoment(time: 4, lines: ["Overview", "Inputs"]),
      VisualMoment(time: 12, lines: ["Overview", "Inputs", "Unrelated result"]),
    ]
    let result = FrameSampler.deduplicatedVisualMoments(moments, hashes: [0, UInt64.max])
    XCTAssertEqual(result, moments)
  }

  func testHeadingRemovalUsesChosenHeadingInsteadOfFirstOCRLine() {
    let span = HeuristicStructurer.Span(
      start: 0, end: 20, sentences: [],
      slide: VisualMoment(time: 2, lines: ["= 0.2", "Actual Heading", "Supported detail"]))
    let section = HeuristicStructurer.makeSection(from: span)
    guard case .concept(let heading, _, let points, _, _, _, _) = section else {
      return XCTFail("expected a concept section")
    }
    XCTAssertEqual(heading, "Actual Heading")
    XCTAssertFalse(points.contains("Actual Heading"))
    XCTAssertTrue(points.contains("Supported detail"))
  }

  func testHeroDoesNotBorrowLateTitledSketch() {
    let strokes = (0..<3).map { index in
      SketchStroke(points: [CGPoint(x: Double(index) * 0.1, y: 0), CGPoint(x: 1, y: 1)])
    }
    let late = VisualMoment(time: 200, lines: ["Late Topic"], sketch: strokes)
    let content = content(visuals: [late], duration: 300)
    XCTAssertNil(HeuristicStructurer.heroSketch(content))
  }

  func testHeroSelectionUsesSameStrictOpeningWindowAsGroundingAudit() {
    let strokes = (0..<3).map { index in
      SketchStroke(points: [
        CGPoint(x: Double(index) * 0.1, y: 0), CGPoint(x: 0.8, y: 0.8),
      ])
    }
    let inside = VisualMoment(time: 11, lines: ["Opening Topic"], sketch: strokes)
    let outside = VisualMoment(time: 13, lines: ["Later Topic"], sketch: strokes)

    XCTAssertEqual(GroundingAuditor.openingWindow(duration: 100), 12)
    XCTAssertEqual(
      HeuristicStructurer.heroSketch(content(visuals: [inside], duration: 100)), strokes)
    XCTAssertNil(HeuristicStructurer.heroSketch(content(visuals: [outside], duration: 100)))
  }

  func testSegmentNeverAttachesDistantFutureVisualToEarlierSpeech() {
    let transcript = [
      TranscriptSegment(start: 0, end: 5, text: "Opening concept about reliable evidence."),
      TranscriptSegment(start: 30, end: 35, text: "A later spoken topic after a long pause."),
    ]
    let visuals = [
      VisualMoment(time: 100, lines: ["Future Slide"]),
      VisualMoment(time: 200, lines: ["Even Later Slide"]),
    ]
    let spans = HeuristicStructurer.segment(
      content(transcript: transcript, visuals: visuals, duration: 240))
    XCTAssertNil(
      spans.first?.slide, "future visual evidence must not be attached to opening speech")
  }

  func testSectionSourceTimeMatchesActualVisualMoment() throws {
    let visual = VisualMoment(time: 12.5, lines: ["Grounded Slide", "A supported point"])
    let doc = try HeuristicStructurer.structure(content(visuals: [visual], duration: 30))
    XCTAssertEqual(doc.sections.first?.sourceTime, 12.5)
  }

  func testSegmentationUnionsVisualAndPauseBoundaries() {
    let transcript = [
      TranscriptSegment(start: 0, end: 5, text: "First spoken topic with useful detail."),
      TranscriptSegment(start: 30, end: 35, text: "Second spoken topic after a pause."),
    ]
    let visuals = [
      VisualMoment(time: 5, lines: ["Slide One"]),
      VisualMoment(time: 60, lines: ["Slide Two"]),
    ]
    let spans = HeuristicStructurer.segment(
      content(transcript: transcript, visuals: visuals, duration: 90))
    XCTAssertTrue(
      spans.contains { abs($0.start - 30) < 0.01 },
      "speech pause should remain a boundary when slides exist")
  }

  func testPersistentVisualHeaderDoesNotCreateASectionPerFrame() {
    let transcript = (0..<6).map { index in
      TranscriptSegment(
        start: Double(index * 8), end: Double(index * 8 + 7),
        text: "Spoken topic \(index) contains useful grounded explanation for the learner.")
    }
    let visuals = (0..<6).map { index in
      VisualMoment(
        time: Double(index * 9 + 2),
        lines: ["Course Studio", "Changing interface detail \(index)"])
    }

    let spans = HeuristicStructurer.segment(
      content(transcript: transcript, visuals: visuals, duration: 54))

    XCTAssertEqual(spans.count, 3)
    XCTAssertEqual(
      HeuristicStructurer.meaningfulVisualBoundaryTimes(visuals), [],
      "persistent app or deck chrome should not fragment the notes")
  }

  func testPersistentVisualHeaderIgnoresStudioAndDesktopChrome() {
    let visuals = [
      VisualMoment(time: 2, lines: ["LLM Academy"]),
      VisualMoment(time: 10, lines: ["LLM_Academy Studio (Desktop)", "Training view"]),
      VisualMoment(time: 20, lines: ["LLM Academy Mobile App", "Evaluation view"]),
    ]

    XCTAssertEqual(HeuristicStructurer.meaningfulVisualBoundaryTimes(visuals), [])
  }

  func testInterfaceChromeNoiseFilteringIsTranscriptAware() {
    XCTAssertTrue(
      FrameSampler.isInterfaceChromeNoise(
        "~/lukes/model/checkpoint", contextualWords: ["training", "evaluation"]))
    XCTAssertTrue(
      FrameSampler.isInterfaceChromeNoise(
        "Model: no model lo...", contextualWords: ["training", "evaluation"]))
    XCTAssertTrue(
      FrameSampler.isInterfaceChromeNoise(
        "Pictures", contextualWords: ["training", "evaluation"]))
    XCTAssertTrue(
      FrameSampler.isInterfaceChromeNoise("So 10", contextualWords: ["training", "evaluation"]))
    XCTAssertTrue(
      FrameSampler.isInterfaceChromeNoise("1 Q", contextualWords: ["training", "evaluation"]))
    XCTAssertFalse(
      FrameSampler.isInterfaceChromeNoise(
        "Evaluation metrics", contextualWords: ["training", "evaluation"]))
    XCTAssertFalse(
      FrameSampler.isInterfaceChromeNoise(
        "Context", contextualWords: ["context", "window", "model"]))
  }

  func testNarratedSpanDoesNotPromoteUnrelatedUIMenuToProcess() {
    let span = HeuristicStructurer.Span(
      start: 0, end: 20,
      sentences: [
        TranscriptSegment(
          start: 0, end: 10,
          text: "Evaluation metrics show whether training quality improved.")
      ],
      slide: VisualMoment(
        time: 5,
        lines: ["Course Studio", "1 Q", "2 Pictures", "3 Select a local model"]))

    let section = HeuristicStructurer.makeSection(from: span)

    guard case .concept(_, _, let points, _, _, _, _) = section else {
      return XCTFail("unrelated numbered interface chrome must not become a narrated process")
    }
    XCTAssertFalse(points.contains(where: { $0.localizedCaseInsensitiveContains("local model") }))
  }

  func testVisualOnlySpanStillUsesGroundedNumberedList() {
    let span = HeuristicStructurer.Span(
      start: 0, end: 20, sentences: [],
      slide: VisualMoment(
        time: 5,
        lines: ["Three Steps", "1. Collect evidence", "2. Verify the result"]))

    let section = HeuristicStructurer.makeSection(from: span)

    guard case .process(_, let steps, _, _, _) = section else {
      return XCTFail("a visual-only numbered slide should remain a process")
    }
    XCTAssertEqual(steps, ["Collect evidence", "Verify the result"])
  }

  func testRepeatedVisualHeaderDefersToSpokenTopicHeading() {
    let spans = [
      HeuristicStructurer.Span(
        start: 0, end: 10,
        sentences: [
          TranscriptSegment(
            start: 0, end: 8,
            text: "Dataset preparation creates reliable examples for training.")
        ],
        slide: VisualMoment(time: 2, lines: ["Course Studio", "Dataset view"])),
      HeuristicStructurer.Span(
        start: 10, end: 20,
        sentences: [
          TranscriptSegment(
            start: 10, end: 18,
            text: "Evaluation metrics reveal quality changes after training.")
        ],
        slide: VisualMoment(time: 12, lines: ["Course Studio", "Metrics view"])),
    ]

    let clarified = HeuristicStructurer.disambiguatingRepeatedVisualHeadings(in: spans)

    XCTAssertNotEqual(HeuristicStructurer.headingFor(clarified[0]), "Course Studio")
    XCTAssertNotEqual(HeuristicStructurer.headingFor(clarified[1]), "Course Studio")
    XCTAssertNotEqual(
      HeuristicStructurer.headingFor(clarified[0]),
      HeuristicStructurer.headingFor(clarified[1]))
  }

  func testComparisonMapsClaimsBySubjectNotNarrationOrder() throws {
    let visuals = [VisualMoment(time: 5, lines: ["Supervised vs Unsupervised"])]
    let transcript = [
      TranscriptSegment(
        start: 1, end: 4, text: "Unsupervised learning discovers clusters without labels."),
      TranscriptSegment(
        start: 5, end: 9, text: "Supervised learning trains from explicitly labeled examples."),
    ]
    let doc = try HeuristicStructurer.structure(
      content(transcript: transcript, visuals: visuals, duration: 20))
    guard
      let comparison = doc.sections.first(where: {
        if case .comparison = $0 { return true }
        return false
      }),
      case .comparison(_, _, let left, _, let right, _, _) = comparison
    else {
      return XCTFail("expected grounded comparison")
    }
    XCTAssertTrue(left.allSatisfy { $0.localizedCaseInsensitiveContains("supervised") })
    XCTAssertTrue(right.allSatisfy { $0.localizedCaseInsensitiveContains("unsupervised") })
  }
}

final class PlannerTests: XCTestCase {
  private func sections(in pages: [PageContent]) -> [NoteSection] {
    pages.flatMap { page -> [NoteSection] in
      switch page {
      case .hero: return []
      case .single(let section): return [section]
      case .pair(let first, let second): return [first, second]
      }
    }
  }

  private func semanticPayload(in sections: [NoteSection]) -> [String] {
    sections.flatMap { section -> [String] in
      switch section {
      case .concept(_, let body, let points, _, let quote, _, _):
        return [body, quote].compactMap { $0 } + points
      case .methods(_, let columns, _):
        return columns.flatMap { column in
          [column.tagline, column.summary].compactMap { $0 } + column.steps
        }
      case .process(_, let steps, _, _, _):
        return steps
      case .comparison(_, _, let left, _, let right, _, _):
        return left + right
      case .quote(let text, let attribution, _):
        return [text] + [attribution].compactMap { $0 }
      case .definition(_, let meaning, _):
        return [meaning]
      case .summary(_, let points, _):
        return points
      }
    }
  }

  private var denseDocument: NoteDocument {
    var sourceSections: [NoteSection] = [
      .concept(
        heading: "Dense concept", body: "concept-body-claim",
        points: (0..<14).map { "concept-point-\($0)-" + String(repeating: "detail ", count: 8) },
        iconHints: ["brain"], quote: "concept-quote-claim", sourceTime: 5),
      .methods(
        heading: "Dense methods",
        columns: (0..<4).map { column in
          MethodColumn(
            title: "Method \(column)", tagline: "method-tagline-\(column)",
            summary: "method-summary-\(column)",
            steps: (0..<8).map { "method-\(column)-step-\($0)-claim" },
            iconHints: ["gear"])
        }, sourceTime: 15),
      .process(
        heading: "Dense process",
        steps: (0..<18).map { "process-step-\($0)-" + String(repeating: "evidence ", count: 5) },
        iconHints: ["gear"], sourceTime: 25),
      .comparison(
        heading: "Dense comparison", leftTitle: "Left",
        leftPoints: (0..<9).map { "left-claim-\($0)" }, rightTitle: "Right",
        rightPoints: (0..<8).map { "right-claim-\($0)" }, sourceTime: 35),
      .summary(
        heading: "Dense summary", points: (0..<14).map { "summary-claim-\($0)" },
        sourceTime: nil),
      .quote(text: "standalone-quote-claim", attribution: "quoted-speaker-claim", sourceTime: 45),
    ]
    sourceSections += (0..<7).map {
      .definition(
        term: "Term \($0)", meaning: "definition-meaning-\($0)-claim", sourceTime: 50 + Double($0))
    }
    return NoteDocument(title: "Dense evidence", sections: sourceSections)
  }

  func testHeroIsAlwaysFirstAndSmallSectionsPair() {
    let doc = NoteDocument(
      title: "T",
      sections: [
        .definition(term: "AI", meaning: "Machines doing clever things with data.", sourceTime: 1),
        .quote(text: "A memorable quote", attribution: nil, sourceTime: 2),
        .methods(
          heading: "M", columns: [MethodColumn(title: "One"), MethodColumn(title: "Two")],
          sourceTime: 3),
      ])
    let pages = PagePlanner.plan(doc)
    guard case .hero = pages[0] else { return XCTFail("hero missing") }
    guard case .pair = pages[1] else { return XCTFail("small sections should pair") }
    guard case .single(.methods) = pages[2] else { return XCTFail("methods should be solo") }
    XCTAssertEqual(pages.count, 3)
  }

  func testEveryPresentationFormatRetainsEverySectionExactlyOnce() {
    let sourceSections: [NoteSection] = [
      .definition(term: "Late", meaning: "A late item.", sourceTime: 90),
      .concept(
        heading: "Opening", body: "The opening evidence.", points: [], iconHints: [], quote: nil,
        sourceTime: 5),
      .summary(heading: "Review", points: ["One", "Two"], sourceTime: nil),
      .quote(text: "Middle evidence", attribution: nil, sourceTime: 45),
    ]
    let document = NoteDocument(title: "Formats", sections: sourceSections)

    for format in NotePresentationFormat.allCases {
      let plannedSections = sections(in: PagePlanner.plan(document, format: format))
      XCTAssertEqual(plannedSections.count, sourceSections.count, "\(format) lost a section")
      for section in sourceSections {
        XCTAssertEqual(
          plannedSections.filter { $0 == section }.count, 1,
          "\(format) must retain each section exactly once")
      }
    }
  }

  func testPresentationFormatsApplyTheirDistinctLayoutRules() {
    let layoutSections: [NoteSection] = [
      .concept(
        heading: "Medium concept", body: String(repeating: "Useful evidence. ", count: 10),
        points: ["One", "Two", "Three"], iconHints: [], quote: nil, sourceTime: 60),
      .process(
        heading: "Four steps", steps: ["One", "Two", "Three", "Four"], iconHints: [],
        sourceTime: 20),
      .methods(
        heading: "Dense", columns: [MethodColumn(title: "A"), MethodColumn(title: "B")],
        sourceTime: 40),
      .summary(heading: "Review", points: ["Remember this"], sourceTime: nil),
    ]
    let document = NoteDocument(title: "Formats", sections: layoutSections)

    let illustrated = PagePlanner.plan(document, format: .illustrated)
    let detailed = PagePlanner.plan(document, format: .detailed)
    let condensed = PagePlanner.plan(document, format: .condensed)
    let evidenceFirst = PagePlanner.plan(document, format: .evidenceFirst)
    let focusCards = PagePlanner.plan(document, format: .focusCards)
    let quickReview = PagePlanner.plan(document, format: .quickReview)
    let studyGuide = PagePlanner.plan(document, format: .studyGuide)

    guard case .hero = illustrated.first else { return XCTFail("illustrated needs a hero") }
    guard case .hero = detailed.first else { return XCTFail("detailed needs a hero") }
    guard case .hero = condensed.first else { return XCTFail("condensed needs a hero") }
    XCTAssertEqual(detailed.count, layoutSections.count + 1)
    XCTAssertLessThan(
      condensed.count, illustrated.count, "condensed should safely pair more content")
    XCTAssertEqual(evidenceFirst.count, layoutSections.count)
    XCTAssertFalse(
      evidenceFirst.contains {
        if case .hero = $0 { return true }
        return false
      },
      "evidence-first must not synthesize a hero")
    XCTAssertEqual(
      sections(in: evidenceFirst).map(\.sourceTime), [20, 40, 60, nil],
      "evidence-first must be chronological with undated review material last")
    XCTAssertEqual(focusCards.count, layoutSections.count)
    XCTAssertFalse(
      focusCards.contains {
        if case .hero = $0 { return true }
        return false
      })
    XCTAssertLessThan(quickReview.count, focusCards.count)
    XCTAssertEqual(sections(in: studyGuide).first, layoutSections.last)
  }

  func testSpecializedPresentationFormatsUseDistinctSourceSafeOrderingAndGrouping() {
    let quote = NoteSection.quote(text: "Quoted evidence", attribution: "Speaker", sourceTime: 40)
    let concept = NoteSection.concept(
      heading: "Core concept", body: "Grounded concept", points: [], iconHints: [], quote: nil,
      sourceTime: 30)
    let methods = NoteSection.methods(
      heading: "Methods", columns: [MethodColumn(title: "Source method")], sourceTime: 20)
    let summary = NoteSection.summary(
      heading: "Review", points: ["Grounded review point"], sourceTime: nil)
    let process = NoteSection.process(
      heading: "Procedure", steps: ["Grounded step"], iconHints: [], sourceTime: 10)
    let definitionOne = NoteSection.definition(
      term: "Term one", meaning: "First grounded meaning", sourceTime: 50)
    let comparison = NoteSection.comparison(
      heading: "Trade-off", leftTitle: "A", leftPoints: ["Grounded A"], rightTitle: "B",
      rightPoints: ["Grounded B"], sourceTime: 25)
    let definitionTwo = NoteSection.definition(
      term: "Term two", meaning: "Second grounded meaning", sourceTime: 55)
    let source = [
      quote, concept, methods, summary, process, definitionOne, comparison, definitionTwo,
    ]
    let document = NoteDocument(title: "Specialized formats", sections: source)

    let cornell = PagePlanner.plan(document, format: .cornellNotes)
    let hierarchy = PagePlanner.plan(document, format: .hierarchicalOutline)
    let timeline = PagePlanner.plan(document, format: .timeline)
    let flashcards = PagePlanner.plan(document, format: .qaFlashcards)
    let exam = PagePlanner.plan(document, format: .examRevision)
    let tutorial = PagePlanner.plan(document, format: .tutorial)
    let decisions = PagePlanner.plan(document, format: .decisionsAndActions)

    guard case .hero = cornell.first else { return XCTFail("Cornell notes need a cover") }
    guard case .pair(let firstCue, let secondCue) = cornell[1] else {
      return XCTFail("Cornell definition cues should form the first measured pair")
    }
    XCTAssertEqual(firstCue, definitionOne)
    XCTAssertEqual(secondCue, definitionTwo)
    XCTAssertEqual(
      sections(in: cornell),
      [definitionOne, definitionTwo, quote, concept, methods, process, comparison, summary])

    guard case .hero = hierarchy.first else {
      return XCTFail("hierarchical outline needs a cover")
    }
    XCTAssertEqual(
      sections(in: hierarchy),
      [concept, definitionOne, definitionTwo, methods, process, comparison, quote, summary])

    XCTAssertFalse(
      timeline.contains {
        if case .hero = $0 { return true }
        return false
      })
    XCTAssertEqual(
      sections(in: timeline),
      [process, methods, comparison, concept, quote, definitionOne, definitionTwo, summary])
    XCTAssertLessThan(timeline.count, source.count, "short adjacent timeline moments should pair")

    XCTAssertFalse(
      flashcards.contains {
        if case .hero = $0 { return true }
        return false
      })
    XCTAssertEqual(
      sections(in: flashcards),
      [definitionOne, definitionTwo, concept, quote, comparison, process, methods, summary])

    guard case .hero = exam.first else { return XCTFail("exam revision needs a cover") }
    XCTAssertEqual(
      sections(in: exam),
      [summary, definitionOne, definitionTwo, comparison, concept, methods, process, quote])
    XCTAssertLessThan(exam.count, source.count + 1, "short revision material should pair")

    guard case .hero = tutorial.first else { return XCTFail("tutorial needs a cover") }
    XCTAssertEqual(
      sections(in: tutorial),
      [process, methods, concept, definitionOne, definitionTwo, comparison, quote, summary])

    XCTAssertFalse(
      decisions.contains {
        if case .hero = $0 { return true }
        return false
      })
    XCTAssertEqual(
      sections(in: decisions),
      [comparison, process, methods, concept, definitionOne, definitionTwo, quote, summary])
  }

  func testDenseClaimsSurviveExactlyOnceAcrossEveryPresentationFormat() {
    let document = SNMValidation.sanitize(denseDocument)
    let expected = semanticPayload(in: document.sections).sorted()
    XCTAssertGreaterThan(document.sections.count, SNMLimits.maxSections)

    for format in NotePresentationFormat.allCases {
      let pages = PagePlanner.plan(document, format: format)
      let planned = semanticPayload(in: sections(in: pages)).sorted()
      XCTAssertEqual(planned, expected, "\(format) changed, duplicated, or dropped a claim")

      for page in pages {
        switch page {
        case .hero:
          break
        case .single(let section):
          XCTAssertTrue(
            PagePlanner.fitsOnSinglePage(section), "\(format) produced an overflowing single page")
        case .pair(let first, let second):
          XCTAssertLessThanOrEqual(
            PagePlanner.measuredHeight(first), PagePlanner.pairedSectionCapacity,
            "\(format) overcrowded the first half of a pair")
          XCTAssertLessThanOrEqual(
            PagePlanner.measuredHeight(second), PagePlanner.pairedSectionCapacity,
            "\(format) overcrowded the second half of a pair")
        }
      }
    }
  }

  func testContinuationTextChunksReconstructSourceExactly() {
    let source = String(repeating: "alpha beta ", count: 43) + "🧠 final"
    let chunks = PagePlanner.textChunks(source, limit: 80)
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertEqual(chunks.joined(), source)
  }

  func testAdversarialWideTextStillProducesComfortablePages() {
    let wide = String(repeating: "W", count: 1_200)
    let document = SNMValidation.sanitize(
      NoteDocument(
        title: "Wide glyph stress",
        sections: [
          .concept(
            heading: "Concept", body: wide, points: [wide], iconHints: [], quote: wide,
            sourceTime: 1),
          .quote(text: wide, attribution: "Speaker", sourceTime: 2),
          .definition(term: "Definition", meaning: wide, sourceTime: 3),
          .comparison(
            heading: "Comparison", leftTitle: "Left", leftPoints: [wide, wide],
            rightTitle: "Right", rightPoints: [wide, wide], sourceTime: 4),
        ]))
    let pages = PagePlanner.plan(document, format: .detailed)
    XCTAssertGreaterThan(pages.count, document.sections.count + 1)
    for section in sections(in: pages) {
      XCTAssertTrue(
        PagePlanner.fitsOnSinglePage(section),
        "continuation fragment still exceeds the measured page budget")
    }
  }
}

final class RendererTests: XCTestCase {
  var sample: NoteDocument {
    NoteDocument(
      title: "Neural Networks 101", subtitle: "From data to decisions",
      sections: [
        .concept(
          heading: "The Big Idea", body: "Networks learn representations from examples.",
          points: ["Weights encode relationships", "Depth builds abstraction"],
          iconHints: ["brain", "chart"], quote: "The network learns what matters.", sourceTime: 10),
        .methods(
          heading: "3 Ways to Train",
          columns: [
            MethodColumn(
              title: "Supervised", tagline: "Learn from labels",
              summary: "Pairs of input and answer.",
              steps: ["Collect labels", "Fit the model"], iconHints: ["document", "gear"]),
            MethodColumn(
              title: "Unsupervised", tagline: "Find structure", summary: "No labels needed.",
              steps: ["Cluster data", "Inspect groups"], iconHints: ["magnifier", "network"]),
          ], sourceTime: 60),
        .process(
          heading: "Training Loop",
          steps: ["Forward pass", "Compute loss", "Backpropagate", "Update weights"],
          iconHints: ["upload", "chart", "network", "gear"], sourceTime: 120),
        .summary(
          heading: "Key Takeaways", points: ["Data quality dominates", "Start simple"],
          sourceTime: nil),
      ])
  }

  func testRendersAllPagesNonEmpty() {
    let style = RenderStyle(seed: 42)
    let images = PageRenderer().renderImages(document: sample, style: style, scale: 1)
    XCTAssertEqual(images.count, PagePlanner.plan(sample).count)
    for image in images {
      XCTAssertEqual(image.width, Int(PageMetrics.size.width))
      XCTAssertEqual(image.height, Int(PageMetrics.size.height))
    }
  }

  func testDenseContinuationPagesAllRender() {
    let dense = NoteDocument(
      title: "Dense review",
      sections: [
        .summary(
          heading: "All grounded claims",
          points: (0..<28).map {
            "Claim \($0): " + String(repeating: "grounded supporting detail ", count: 5)
          }, sourceTime: 10)
      ])
    let style = RenderStyle(seed: 2048, presentationFormat: .detailed)
    let planned = PagePlanner.plan(dense, format: .detailed)
    let images = PageRenderer().renderImages(document: dense, style: style, scale: 1)
    XCTAssertGreaterThan(planned.count, 2)
    XCTAssertEqual(images.count, planned.count)
    XCTAssertTrue(images.allSatisfy { $0.width == 1080 && $0.height == 1920 })
  }

  func testRenderIsDeterministic() {
    let style = RenderStyle(seed: 7)
    let renderer = PageRenderer()
    let a = renderer.renderImages(document: sample, style: style, scale: 1).map {
      PageRenderer.pngData($0)
    }
    let b = renderer.renderImages(document: sample, style: style, scale: 1).map {
      PageRenderer.pngData($0)
    }
    XCTAssertEqual(a, b, "same seed must render identical bytes")
  }

  func testDifferentSeedChangesOutput() {
    let renderer = PageRenderer()
    let a = renderer.renderImages(document: sample, style: RenderStyle(seed: 1), scale: 1).map {
      PageRenderer.pngData($0)
    }
    let b = renderer.renderImages(document: sample, style: RenderStyle(seed: 2), scale: 1).map {
      PageRenderer.pngData($0)
    }
    XCTAssertNotEqual(a, b)
  }

  func testPDFHasContent() {
    let pdf = PageRenderer().renderPDF(document: sample, style: RenderStyle(seed: 42))
    XCTAssertGreaterThan(pdf.count, 20_000)
    XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
  }

  func testPDFPageFormatsSetMediaBoxAndPreservePageCount() {
    for format in PDFPageFormat.allCases {
      let style = RenderStyle(
        seed: 42, presentationFormat: .detailed, pdfPageFormat: format)
      let data = PageRenderer().renderPDF(document: sample, style: style)
      guard
        let provider = CGDataProvider(data: data as CFData),
        let document = CGPDFDocument(provider),
        let firstPage = document.page(at: 1)
      else {
        XCTFail("\(format) did not produce a readable PDF")
        continue
      }
      XCTAssertEqual(
        document.numberOfPages,
        PagePlanner.plan(sample, format: .detailed).count,
        "\(format) page count changed")
      let mediaBox = firstPage.getBoxRect(.mediaBox)
      XCTAssertEqual(mediaBox.width, format.pageSize.width, accuracy: 0.02)
      XCTAssertEqual(mediaBox.height, format.pageSize.height, accuracy: 0.02)
    }
  }

  func testPDFSemanticLayerIsSearchableAndCarriesDocumentMetadata() throws {
    let style = RenderStyle(
      seed: 42, presentationFormat: .detailed, pdfPageFormat: .a4)
    let data = PageRenderer().renderPDF(document: sample, style: style)
    let pdf = try XCTUnwrap(PDFDocument(data: data))
    let extractedText = try XCTUnwrap(pdf.string)

    XCTAssertTrue(extractedText.contains("Networks learn representations from examples."))
    XCTAssertTrue(extractedText.contains("Step 4: Update weights"))
    XCTAssertTrue(extractedText.contains("Synthesized review"))
    XCTAssertTrue(extractedText.contains("Bullet: Data quality dominates"))
    XCTAssertFalse(
      pdf.findString("Data quality dominates", withOptions: [.caseInsensitive]).isEmpty,
      "semantic note content must be searchable through PDFKit")

    let visualOnlyData = PageRenderer().renderPDF(
      document: sample, style: style, includesSemanticText: false)
    let visualOnlyText = PDFDocument(data: visualOnlyData)?.string ?? ""
    XCTAssertFalse(
      visualOnlyText.contains("Bullet: Data quality dominates"),
      "the control PDF unexpectedly contains the semantic-only list label")

    let attributes = try XCTUnwrap(pdf.documentAttributes)
    XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, sample.title)
    XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "VideoNotes")
    XCTAssertEqual(
      attributes[PDFDocumentAttribute.subjectAttribute] as? String,
      "Detailed video notes. Language: en.")
    XCTAssertEqual(
      attributes[PDFDocumentAttribute.creatorAttribute] as? String,
      "VideoNotes / SketchnoteEngine")
    XCTAssertTrue(
      (attributes[PDFDocumentAttribute.keywordsAttribute] as? [String])?.contains("Training Loop")
        == true)

    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    let coreDocument = try XCTUnwrap(CGPDFDocument(provider))
    let catalog = try XCTUnwrap(coreDocument.catalog)
    var metadataStream: CGPDFStreamRef?
    XCTAssertTrue(
      CGPDFDictionaryGetStream(catalog, "Metadata", &metadataStream),
      "portable XMP metadata stream is missing")
    XCTAssertNotNil(metadataStream)
    var markInfo: CGPDFDictionaryRef?
    XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "MarkInfo", &markInfo))
    var isMarked: CGPDFBoolean = 0
    XCTAssertTrue(CGPDFDictionaryGetBoolean(try XCTUnwrap(markInfo), "Marked", &isMarked))
    XCTAssertEqual(isMarked, 1, "the semantic layer must be represented as tagged PDF content")
  }

  func testInvisibleSemanticLayerDoesNotChangeRenderedPixels() throws {
    let style = RenderStyle(
      seed: 42, presentationFormat: .detailed, pdfPageFormat: .a4)
    let renderer = PageRenderer()
    let accessible = renderer.renderPDF(
      document: sample, style: style, includesSemanticText: true)
    let visualOnly = renderer.renderPDF(
      document: sample, style: style, includesSemanticText: false)

    let accessiblePixels = try XCTUnwrap(rasterizedPDFPage(accessible, pageNumber: 2))
    let visualOnlyPixels = try XCTUnwrap(rasterizedPDFPage(visualOnly, pageNumber: 2))
    XCTAssertEqual(
      accessiblePixels, visualOnlyPixels,
      "the invisible text layer must not alter a single rendered pixel")
  }

  func testPDFSemanticLayerPreservesUnicodeNoteText() throws {
    let multilingual = NoteDocument(
      title: "Résumé de l’apprentissage", language: "fr",
      sections: [
        .definition(
          term: "機械学習",
          meaning: "Modèle entraîné à partir d’exemples - البيانات مهمة.",
          sourceTime: 4)
      ])
    let data = PageRenderer().renderPDF(
      document: multilingual,
      style: RenderStyle(seed: 9, presentationFormat: .focusCards))
    let pdf = try XCTUnwrap(PDFDocument(data: data))
    let text = try XCTUnwrap(pdf.string)

    XCTAssertTrue(text.contains("Résumé de l’apprentissage"))
    XCTAssertTrue(text.contains("機械学習"))
    XCTAssertTrue(text.contains("البيانات مهمة"))
    XCTAssertEqual(
      pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
      multilingual.title)
  }

  func testEveryPresentationAndPDFFormatCombinationRenders() {
    for presentation in NotePresentationFormat.allCases {
      for paper in PDFPageFormat.allCases {
        let style = RenderStyle(
          seed: 84, presentationFormat: presentation, pdfPageFormat: paper)
        let data = PageRenderer().renderPDF(document: sample, style: style)
        guard
          let provider = CGDataProvider(data: data as CFData),
          let document = CGPDFDocument(provider),
          let firstPage = document.page(at: 1)
        else {
          XCTFail("\(presentation) + \(paper) did not produce a readable PDF")
          continue
        }
        XCTAssertEqual(
          document.numberOfPages,
          PagePlanner.plan(sample, format: presentation).count,
          "\(presentation) + \(paper) changed the planned page count")
        XCTAssertTrue(
          PDFDocument(data: data)?.string?.contains("Data quality dominates") == true,
          "\(presentation) + \(paper) lost searchable semantic note text")
        let mediaBox = firstPage.getBoxRect(.mediaBox)
        XCTAssertEqual(mediaBox.width, paper.pageSize.width, accuracy: 0.02)
        XCTAssertEqual(mediaBox.height, paper.pageSize.height, accuracy: 0.02)
      }
    }
  }

  func testPNGFinalizationProducesNonemptyData() {
    let image = PageRenderer().renderImages(
      document: sample, style: RenderStyle(seed: 17), scale: 1
    ).first
    XCTAssertNotNil(image)
    XCTAssertGreaterThan(image.map(PageRenderer.pngData)?.count ?? 0, 1_000)
  }

  func testAllPalettesRender() {
    for palette in Palette.all {
      let images = PageRenderer().renderImages(
        document: sample,
        style: RenderStyle(palette: palette, seed: 3), scale: 1)
      XCTAssertFalse(images.isEmpty, "\(palette.name) failed")
    }
  }

  func testEveryGlyphFlattens() {
    for (name, path) in IconLibrary.glyphs {
      let polylines = RoughPen.flatten(path)
      XCTAssertFalse(polylines.isEmpty, "glyph \(name) produced no strokes")
    }
  }

  func testKeywordMapTargetsExist() {
    for (keyword, glyph) in IconLibrary.keywordMap {
      XCTAssertNotNil(IconLibrary.glyphs[glyph], "keyword \(keyword) → missing glyph \(glyph)")
    }
    for name in IconLibrary.fallbackGlyphs {
      XCTAssertNotNil(IconLibrary.glyphs[name])
    }
  }

  func testSplitMixDeterminism() {
    var a = SplitMix64(seed: 99)
    var b = SplitMix64(seed: 99)
    for _ in 0..<50 { XCTAssertEqual(a.next(), b.next()) }
  }

  func testPairReportsBothEvidenceTimes() {
    let first = NoteSection.definition(
      term: "One", meaning: "First grounded claim.", sourceTime: 12)
    let second = NoteSection.quote(text: "Second grounded claim.", attribution: nil, sourceTime: 65)
    XCTAssertEqual(PageRenderer().sourceLabel(for: .pair(first, second)), "SOURCES · 00:12 + 01:05")
  }

  func testNilTimeSummaryIsLabeledAsSynthesizedReview() {
    let summary = NoteSection.summary(
      heading: "Review", points: ["A synthesized takeaway"], sourceTime: nil)
    XCTAssertEqual(PageRenderer().sourceLabel(for: .single(summary)), "SYNTHESIZED REVIEW")
  }

  private func rasterizedPDFPage(_ data: Data, pageNumber: Int) -> Data? {
    guard
      let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider),
      let page = document.page(at: pageNumber)
    else { return nil }

    let pageRect = page.getBoxRect(.mediaBox)
    let scale: CGFloat = 0.25
    let width = max(1, Int((pageRect.width * scale).rounded(.up)))
    let height = max(1, Int((pageRect.height * scale).rounded(.up)))
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    return pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.scaleBy(x: scale, y: scale)
      context.drawPDFPage(page)
      return Data(buffer)
    }
  }
}

final class SketcherTests: XCTestCase {
  func syntheticFrame() -> CGImage {
    let context = CGContext(
      data: nil, width: 400, height: 300, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 60, y: 60, width: 140, height: 120))
    context.fillEllipse(in: CGRect(x: 250, y: 90, width: 100, height: 100))
    return context.makeImage()!
  }

  func testTraceFindsShapes() {
    let strokes = FrameSketcher.trace(syntheticFrame())
    XCTAssertGreaterThanOrEqual(strokes.count, 2, "rectangle and circle should be traced")
    for stroke in strokes {
      for p in stroke.points {
        XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y), "points must be normalized")
      }
    }
  }

  func testTraceIsDeterministic() {
    let a = FrameSketcher.trace(syntheticFrame())
    let b = FrameSketcher.trace(syntheticFrame())
    XCTAssertEqual(a, b)
  }

  func testPerceptualHashDistinguishesFrames() {
    let a = FrameSketcher.perceptualHash(syntheticFrame())
    XCTAssertEqual(FrameSketcher.hammingDistance(a, a), 0)
    let context = CGContext(
      data: nil, width: 400, height: 300, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 200, width: 400, height: 100))
    let b = FrameSketcher.perceptualHash(context.makeImage()!)
    XCTAssertGreaterThan(FrameSketcher.hammingDistance(a, b), 9, "different frames must hash apart")
  }

  func testPerceptualHashDistinguishesUniformDarkAndLightFrames() {
    func solid(_ value: CGFloat) -> CGImage {
      let context = CGContext(
        data: nil, width: 320, height: 180, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
      return context.makeImage()!
    }
    let black = FrameSketcher.perceptualHash(solid(0))
    let white = FrameSketcher.perceptualHash(solid(1))
    XCTAssertNotEqual(black, white)
    XCTAssertGreaterThan(FrameSketcher.hammingDistance(black, white), 9)
  }

  func testSketchRoundTripsThroughSNM() throws {
    let sketch = [
      SketchStroke(points: [
        CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.4, y: 0.5),
      ])
    ]
    let doc = NoteDocument(
      title: "T",
      sections: [
        .concept(
          heading: "H", body: nil, points: [], iconHints: [], quote: nil, sourceTime: 1,
          sketch: sketch)
      ], heroSketch: sketch)
    let data = try JSONEncoder().encode(doc)
    let back = try JSONDecoder().decode(NoteDocument.self, from: data)
    XCTAssertEqual(doc, back)
    XCTAssertEqual(back.heroSketch, sketch)
  }

  func testSketchPageRenders() {
    let sketch = [
      SketchStroke(
        points: (0..<20).map { CGPoint(x: 0.1 + Double($0) * 0.04, y: 0.5 + 0.3 * sin(Double($0))) }
      )
    ]
    let doc = NoteDocument(
      title: "Traced",
      sections: [
        .concept(
          heading: "Scene", body: "About the scene", points: ["A point"],
          iconHints: [], quote: nil, sourceTime: 0, sketch: sketch)
      ], heroSketch: sketch)
    let images = PageRenderer().renderImages(document: doc, style: RenderStyle(seed: 5), scale: 1)
    XCTAssertEqual(images.count, 2)
  }
}

final class GroundingAuditorTests: XCTestCase {
  private func sketch(_ offset: CGFloat) -> [SketchStroke] {
    (0..<3).map { index in
      let y = offset + CGFloat(index) * 0.04
      return SketchStroke(points: [
        CGPoint(x: 0.12, y: y), CGPoint(x: 0.48, y: y + 0.02),
        CGPoint(x: 0.82, y: y),
      ])
    }
  }

  func testExactSourceSketchAndTimestampPassStrictGrounding() throws {
    let trace = sketch(0.2)
    let content = ExtractedContent(
      sourceName: "Lesson", duration: 60,
      transcript: [TranscriptSegment(start: 5, end: 9, text: "A grounded explanation")],
      visuals: [VisualMoment(time: 7, lines: ["Grounded scene"], sketch: trace)])
    let document = NoteDocument(
      title: "Lesson",
      sections: [
        .concept(
          heading: "Grounded scene", body: "A grounded explanation", points: [],
          iconHints: [], quote: nil, sourceTime: 7, sketch: trace)
      ], heroSketch: trace)

    let report = GroundingAuditor.audit(document: document, content: content)

    XCTAssertEqual(report.alignedCitations, 1)
    XCTAssertEqual(report.sourceMatchedIllustrations, 1)
    XCTAssertEqual(report.temporallyAlignedIllustrations, 1)
    XCTAssertTrue(report.heroSourceMatched)
    XCTAssertTrue(report.heroOpeningMatched)
    XCTAssertTrue(report.illustrationsAreStrictlyGrounded)

    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    XCTAssertEqual(json["illustrationsAreStrictlyGrounded"] as? Bool, true)
    XCTAssertEqual(json["ungroundedIllustrations"] as? Int, 0)
  }

  func testSourceSketchFromWrongSceneAndFabricatedSketchAreRejected() {
    let citedTrace = sketch(0.1)
    let lateTrace = sketch(0.45)
    let fabricatedTrace = sketch(0.7)
    let content = ExtractedContent(
      sourceName: "Lesson", duration: 100,
      transcript: [TranscriptSegment(start: 8, end: 12, text: "The cited lesson")],
      visuals: [
        VisualMoment(time: 10, lines: ["Cited"], sketch: citedTrace),
        VisualMoment(time: 80, lines: ["Unrelated late scene"], sketch: lateTrace),
      ])
    let document = NoteDocument(
      title: "Lesson",
      sections: [
        .concept(
          heading: "Wrong scene", body: nil, points: [], iconHints: [], quote: nil,
          sourceTime: 10, sketch: lateTrace),
        .concept(
          heading: "Invented", body: nil, points: [], iconHints: [], quote: nil,
          sourceTime: 10, sketch: fabricatedTrace),
      ])

    let report = GroundingAuditor.audit(document: document, content: content)

    XCTAssertEqual(report.illustratedSections, 2)
    XCTAssertEqual(report.sourceMatchedIllustrations, 1)
    XCTAssertEqual(report.temporallyAlignedIllustrations, 0)
    XCTAssertEqual(report.ungroundedIllustrations, 1)
    XCTAssertEqual(report.temporallyMisalignedIllustrations, 1)
    XCTAssertFalse(report.illustrationsAreStrictlyGrounded)
  }

  func testLateSourceFrameCannotPassAsOpeningHero() {
    let lateTrace = sketch(0.4)
    let content = ExtractedContent(
      sourceName: "Lesson", duration: 100, transcript: [],
      visuals: [VisualMoment(time: 80, lines: ["Late title"], sketch: lateTrace)])
    let document = NoteDocument(
      title: "Lesson", sections: [.summary(heading: "Summary", points: ["Point"], sourceTime: nil)],
      heroSketch: lateTrace)

    let report = GroundingAuditor.audit(document: document, content: content)

    XCTAssertTrue(report.heroSourceMatched)
    XCTAssertFalse(report.heroOpeningMatched)
    XCTAssertFalse(report.illustrationsAreStrictlyGrounded)
  }

  func testHeuristicStructurerOnlyEmitsStrictlyGroundedSourceIllustrations() throws {
    let trace = sketch(0.25)
    let content = ExtractedContent(
      sourceName: "Lesson", duration: 45,
      transcript: [
        TranscriptSegment(
          start: 5, end: 12,
          text: "A verified workflow prepares the data and checks the result.")
      ],
      visuals: [
        VisualMoment(
          time: 7, lines: ["Verified Workflow", "Prepare data", "Check result"], sketch: trace)
      ])

    let document = try HeuristicStructurer.structure(content)
    let report = GroundingAuditor.audit(document: document, content: content)

    XCTAssertGreaterThan(report.illustratedSections, 0)
    XCTAssertEqual(report.ungroundedIllustrations, 0)
    XCTAssertEqual(report.temporallyMisalignedIllustrations, 0)
    XCTAssertTrue(report.illustrationsAreStrictlyGrounded)
  }
}
