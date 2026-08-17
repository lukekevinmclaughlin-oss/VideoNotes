import CoreGraphics
import Foundation

public enum NotePresentationFormat: String, CaseIterable, Sendable {
  /// A visual cover followed by intelligently paired, compact sections.
  case illustrated
  /// A visual cover followed by one complete section per page.
  case detailed
  /// A visual cover followed by denser, evidence-safe section pairing.
  case condensed
  /// Source-chronological sections without a synthesized cover page.
  case evidenceFirst
  /// One original-order section per card, without a cover page.
  case focusCards
  /// A compact, original-order review set without a cover page.
  case quickReview
  /// Review and definition material first, followed by the complete lesson.
  case studyGuide
  /// Definition cues first, complete source notes next, and review summaries last.
  case cornellNotes
  /// Complete sections grouped from core concepts through supporting reference material.
  case hierarchicalOutline
  /// Dated sections in source chronology, with undated review material retained last.
  case timeline
  /// Source-provided terms and headings prioritized as study cards; no questions are invented.
  case qaFlashcards
  /// Review, definitions, and comparisons first, followed by all remaining source material.
  case examRevision
  /// Source-provided processes and methods first, with every other section retained as reference.
  case tutorial
  /// Source-provided comparisons and procedures first; no decisions or actions are invented.
  case decisionsAndActions
}

public enum PDFPageFormat: String, CaseIterable, Sendable {
  case digital
  case a4
  case usLetter

  public var pageSize: CGSize {
    switch self {
    case .digital: return PageMetrics.size
    case .a4: return CGSize(width: 595.28, height: 841.89)
    case .usLetter: return CGSize(width: 612, height: 792)
    }
  }
}

public struct RenderStyle: Equatable, Sendable {
  public var palette: Palette
  public var seed: UInt64
  public var compact: Bool
  public var presentationFormat: NotePresentationFormat
  public var pdfPageFormat: PDFPageFormat

  public init(
    palette: Palette = .paperAndInk,
    seed: UInt64,
    compact: Bool = false,
    presentationFormat: NotePresentationFormat = .illustrated,
    pdfPageFormat: PDFPageFormat = .digital
  ) {
    self.palette = palette
    self.seed = seed
    self.compact = compact
    self.presentationFormat = presentationFormat
    self.pdfPageFormat = pdfPageFormat
  }
}

public enum PageContent: Equatable {
  case hero(title: String, subtitle: String?, iconHints: [String], sketch: [SketchStroke]? = nil)
  case single(NoteSection)
  case pair(NoteSection, NoteSection)
}

public enum PageMetrics {
  public static let size = CGSize(width: 1080, height: 1920)
  public static let margin: CGFloat = 76
}

public enum PagePlanner {
  /// Leave a little breathing room beyond the renderer's measured content.
  /// This is a layout budget, not a semantic-content limit.
  static let singlePageCapacity: CGFloat =
    PageMetrics.size.height - PageMetrics.margin * 2 - 144
  static let pairedSectionCapacity: CGFloat =
    (PageMetrics.size.height - PageMetrics.margin * 2 - 80 - 110) / 2 - 28

  /// SNM → ordered pages. The default preserves the original illustrated layout.
  public static func plan(
    _ document: NoteDocument,
    format: NotePresentationFormat = .illustrated
  ) -> [PageContent] {
    switch format {
    case .illustrated:
      return hero(document) + pairedPages(pageSections(document.sections), where: isSmall)
    case .detailed:
      return hero(document) + pageSections(document.sections).map(PageContent.single)
    case .condensed:
      return hero(document) + pairedPages(pageSections(document.sections), where: isCondensedSmall)
    case .evidenceFirst:
      return pageSections(chronologicalSections(document.sections)).map(PageContent.single)
    case .focusCards:
      return pageSections(document.sections).map(PageContent.single)
    case .quickReview:
      return pairedPages(pageSections(document.sections), where: isCondensedSmall)
    case .studyGuide:
      return hero(document)
        + pageSections(studyOrderedSections(document.sections)).map(PageContent.single)
    case .cornellNotes:
      return hero(document)
        + pairedPages(
          pageSections(stableOrder(document.sections, rankedBy: cornellRank)),
          where: isCornellPairable)
    case .hierarchicalOutline:
      return hero(document)
        + pageSections(stableOrder(document.sections, rankedBy: hierarchyRank)).map(
          PageContent.single)
    case .timeline:
      return pairedPages(
        pageSections(chronologicalSections(document.sections)), where: isSmall)
    case .qaFlashcards:
      return pageSections(stableOrder(document.sections, rankedBy: flashcardRank)).map(
        PageContent.single)
    case .examRevision:
      return hero(document)
        + pairedPages(
          pageSections(stableOrder(document.sections, rankedBy: examRank)),
          where: isCondensedSmall)
    case .tutorial:
      return hero(document)
        + pageSections(stableOrder(document.sections, rankedBy: tutorialRank)).map(
          PageContent.single)
    case .decisionsAndActions:
      return pairedPages(
        pageSections(stableOrder(document.sections, rankedBy: decisionsAndActionsRank)),
        where: isSmall)
    }
  }

  private static func hero(_ document: NoteDocument) -> [PageContent] {
    [
      .hero(
        title: document.title,
        subtitle: document.subtitle,
        iconHints: heroIcons(document),
        sketch: document.heroSketch)
    ]
  }

  private static func pairedPages(
    _ sections: [NoteSection],
    where canPair: (NoteSection) -> Bool
  ) -> [PageContent] {
    var pages: [PageContent] = []
    var pending: NoteSection?
    for section in sections {
      if let waiting = pending {
        if canPair(section), pairFits(waiting, section) {
          pages.append(.pair(waiting, section))
          pending = nil
        } else {
          pages.append(.single(waiting))
          pending = nil
          pages.append(.single(section))
        }
      } else if canPair(section) {
        pending = section
      } else {
        pages.append(.single(section))
      }
    }
    if let waiting = pending { pages.append(.single(waiting)) }
    return pages
  }

  /// Expands only sections that cannot be drawn comfortably. Every semantic
  /// payload is assigned to one continuation fragment, in source order.
  static func pageSections(_ sections: [NoteSection]) -> [NoteSection] {
    sections.flatMap(sectionFragments)
  }

  static func fitsOnSinglePage(_ section: NoteSection) -> Bool {
    guard measuredHeight(section) <= singlePageCapacity else { return false }
    if case .concept(_, _, _, _, let quote, _, _) = section,
      (quote?.count ?? 0) > 80
    {
      return false
    }
    if case .comparison(_, _, let left, _, let right, _, _) = section {
      return left.count <= 4 && right.count <= 4
        && (left + right).allSatisfy { $0.count <= 160 }
    }
    if case .methods(_, let columns, _) = section {
      return columns.count <= 3
    }
    return true
  }

  private static func pairFits(_ first: NoteSection, _ second: NoteSection) -> Bool {
    measuredHeight(first) <= pairedSectionCapacity
      && measuredHeight(second) <= pairedSectionCapacity
  }

  /// Mirrors the renderer closely enough to make overflow a planner invariant.
  /// The quote and comparison paths use their actual solo typography because
  /// the renderer's generic estimator intentionally treats those more loosely.
  static func measuredHeight(_ section: NoteSection) -> CGFloat {
    let width = PageMetrics.size.width - PageMetrics.margin * 2
    let style = RenderStyle(seed: 0)
    switch section {
    case .quote(let quote, let attribution, _):
      let font = FontBook.font(.script, size: 58)
      return TextKit.measure(
        "\u{201c}" + quote + "\u{201d}", font: font, width: width - 140, lineSpacing: 8
      )
      .height + 140 + (attribution == nil ? 0 : 56)
    case .comparison(let heading, let leftTitle, let left, let rightTitle, let right, _, let sketch):
      let headingFont = FontBook.font(.heading, size: 58)
      let headingHeight = TextKit.measure(heading, font: headingFont, width: width).height + 64
      let columnWidth = (width - 56) / 2
      let innerWidth = columnWidth - 44
      let titleFont = FontBook.font(.heading, size: 38)
      let pointFont = FontBook.font(.body, size: 30)
      func sideHeight(_ title: String, _ points: [String]) -> CGFloat {
        TextKit.measure(title, font: titleFont, width: innerWidth).height + 52
          + points.reduce(0) {
            $0 + TextKit.measure($1, font: pointFont, width: innerWidth - 52).height + 22
          }
      }
      return headingHeight + (sketch == nil ? 0 : 260)
        + max(sideHeight(leftTitle, left), sideHeight(rightTitle, right)) + 48
    default:
      return PageRenderer().measureSection(section, width: width, style: style)
    }
  }

  private static func sectionFragments(_ section: NoteSection) -> [NoteSection] {
    guard !fitsOnSinglePage(section) else { return [section] }
    switch section {
    case .concept(let heading, let body, let points, let icons, let quote, let time, let sketch):
      return conceptFragments(
        heading: heading, body: body, points: points, icons: icons, quote: quote,
        sourceTime: time, sketch: sketch)
    case .methods(let heading, let columns, let time):
      return methodFragments(heading: heading, columns: columns, sourceTime: time)
    case .process(let heading, let steps, let icons, let time, let sketch):
      return processFragments(
        heading: heading, steps: steps, icons: icons, sourceTime: time, sketch: sketch)
    case .comparison(
      let heading, let leftTitle, let left, let rightTitle, let right, let time, let sketch):
      return comparisonFragments(
        heading: heading, leftTitle: leftTitle, left: left, rightTitle: rightTitle,
        right: right, sourceTime: time, sketch: sketch)
    case .quote(let text, let attribution, let time):
      let chunks = fittedTextChunks(text, initialLimit: 500) { chunk in
        fitsOnSinglePage(.quote(text: chunk, attribution: attribution, sourceTime: time))
      }
      return chunks.enumerated().map { index, chunk in
        .quote(
          text: chunk,
          attribution: index == chunks.count - 1 ? attribution : nil,
          sourceTime: time)
      }
    case .definition(let term, let meaning, let time):
      let chunks = fittedTextChunks(meaning, initialLimit: 600) { chunk in
        fitsOnSinglePage(
          .definition(
            term: continuationLabel(term, part: 99), meaning: chunk, sourceTime: time))
      }
      return chunks.enumerated().map { index, chunk in
        .definition(
          term: continuationLabel(term, part: index + 1), meaning: chunk, sourceTime: time)
      }
    case .summary(let heading, let points, let time):
      return summaryFragments(heading: heading, points: points, sourceTime: time)
    }
  }

  private enum ConceptUnit {
    case body(String)
    case point(String)
    case quote(String)
  }

  private struct ConceptDraft {
    var body: String?
    var points: [String] = []
    var icons: [String] = []
    var quote: String?
    var sketch: [SketchStroke]?

    var hasContent: Bool {
      body != nil || !points.isEmpty || quote != nil || sketch != nil || !icons.isEmpty
    }
  }

  private static func conceptFragments(
    heading: String, body: String?, points: [String], icons: [String], quote: String?,
    sourceTime: Double?, sketch: [SketchStroke]?
  ) -> [NoteSection] {
    var units: [ConceptUnit] = []
    if let body { units += textChunks(body, limit: 320).map(ConceptUnit.body) }
    for point in points {
      units += textChunks(point, limit: 160).map(ConceptUnit.point)
    }
    if let quote { units += textChunks(quote, limit: 80).map(ConceptUnit.quote) }

    var result: [NoteSection] = []
    var part = 1
    var draft = ConceptDraft(body: nil, icons: icons, sketch: sketch)

    func makeSection(_ value: ConceptDraft, part: Int) -> NoteSection {
      .concept(
        heading: continuationLabel(heading, part: part), body: value.body,
        points: value.points, iconHints: value.icons, quote: value.quote,
        sourceTime: sourceTime, sketch: value.sketch)
    }
    func flush() {
      guard draft.hasContent else { return }
      result.append(makeSection(draft, part: part))
      part += 1
      draft = ConceptDraft()
    }

    for unit in units {
      var candidate = draft
      switch unit {
      case .body(let value):
        if candidate.body != nil {
          flush()
          candidate = draft
        }
        candidate.body = value
      case .point(let value):
        candidate.points.append(value)
      case .quote(let value):
        if candidate.quote != nil {
          flush()
          candidate = draft
        }
        candidate.quote = value
      }
      if fitsOnSinglePage(makeSection(candidate, part: part)) {
        draft = candidate
      } else {
        flush()
        switch unit {
        case .body(let value): draft.body = value
        case .point(let value): draft.points = [value]
        case .quote(let value): draft.quote = value
        }
      }
    }
    flush()
    return result.isEmpty
      ? [
        .concept(
          heading: heading, body: body, points: points, iconHints: icons, quote: quote,
          sourceTime: sourceTime, sketch: sketch)
      ] : result
  }

  private static func methodFragments(
    heading: String, columns: [MethodColumn], sourceTime: Double?
  ) -> [NoteSection] {
    var columnParts: [MethodColumn] = []
    for column in columns {
      let summaries = column.summary.map { textChunks($0, limit: 240) } ?? []
      let steps = column.steps.flatMap { textChunks($0, limit: 120) }
      var part = 1
      var summaryIndex = 0
      var stepIndex = 0
      repeat {
        let summary = summaryIndex < summaries.count ? summaries[summaryIndex] : nil
        if summary != nil { summaryIndex += 1 }
        let end = min(stepIndex + 2, steps.count)
        let pageSteps = Array(steps[stepIndex..<end])
        stepIndex = end
        columnParts.append(
          MethodColumn(
            title: continuationLabel(column.title, part: part),
            tagline: part == 1 ? column.tagline : nil,
            summary: summary,
            steps: pageSteps,
            iconHints: part == 1 ? column.iconHints : []))
        part += 1
      } while summaryIndex < summaries.count || stepIndex < steps.count
    }
    if columnParts.isEmpty {
      return [.methods(heading: heading, columns: [], sourceTime: sourceTime)]
    }
    return columnParts.enumerated().map { index, column in
      .methods(
        heading: continuationLabel(heading, part: index + 1), columns: [column],
        sourceTime: sourceTime)
    }
  }

  private static func processFragments(
    heading: String, steps: [String], icons: [String], sourceTime: Double?,
    sketch: [SketchStroke]?
  ) -> [NoteSection] {
    let pieces = steps.flatMap { textChunks($0, limit: 160) }
    var result: [NoteSection] = []
    var index = 0
    var part = 1
    repeat {
      var pageSteps: [String] = []
      while index < pieces.count {
        let candidateSteps = pageSteps + [pieces[index]]
        let candidate = NoteSection.process(
          heading: continuationLabel(heading, part: part), steps: candidateSteps,
          iconHints: part == 1 ? icons : [], sourceTime: sourceTime,
          sketch: part == 1 ? sketch : nil)
        if !pageSteps.isEmpty, !fitsOnSinglePage(candidate) { break }
        pageSteps = candidateSteps
        index += 1
      }
      result.append(
        .process(
          heading: continuationLabel(heading, part: part), steps: pageSteps,
          iconHints: part == 1 ? icons : [], sourceTime: sourceTime,
          sketch: part == 1 ? sketch : nil))
      part += 1
    } while index < pieces.count
    return result
  }

  private static func comparisonFragments(
    heading: String, leftTitle: String, left: [String], rightTitle: String, right: [String],
    sourceTime: Double?, sketch: [SketchStroke]?
  ) -> [NoteSection] {
    let leftPieces = left.flatMap { textChunks($0, limit: 80) }
    let rightPieces = right.flatMap { textChunks($0, limit: 80) }
    let pageCount = max(1, Int(ceil(Double(max(leftPieces.count, rightPieces.count)) / 2)))
    return (0..<pageCount).map { index in
      let start = index * 2
      let leftEnd = min(start + 2, leftPieces.count)
      let rightEnd = min(start + 2, rightPieces.count)
      return .comparison(
        heading: continuationLabel(heading, part: index + 1), leftTitle: leftTitle,
        leftPoints: start < leftEnd ? Array(leftPieces[start..<leftEnd]) : [],
        rightTitle: rightTitle,
        rightPoints: start < rightEnd ? Array(rightPieces[start..<rightEnd]) : [],
        sourceTime: sourceTime, sketch: index == 0 ? sketch : nil)
    }
  }

  private static func summaryFragments(
    heading: String, points: [String], sourceTime: Double?
  ) -> [NoteSection] {
    let pieces = points.flatMap { textChunks($0, limit: 160) }
    var result: [NoteSection] = []
    var index = 0
    var part = 1
    repeat {
      var pagePoints: [String] = []
      while index < pieces.count {
        let candidate = NoteSection.summary(
          heading: continuationLabel(heading, part: part),
          points: pagePoints + [pieces[index]], sourceTime: sourceTime)
        if !pagePoints.isEmpty, !fitsOnSinglePage(candidate) { break }
        pagePoints.append(pieces[index])
        index += 1
      }
      result.append(
        .summary(
          heading: continuationLabel(heading, part: part), points: pagePoints,
          sourceTime: sourceTime))
      part += 1
    } while index < pieces.count
    return result
  }

  private static func continuationLabel(_ label: String, part: Int) -> String {
    part == 1 ? label : "\(label) · continued \(part)"
  }

  /// Split without trimming or normalizing so concatenating the chunks exactly
  /// reconstructs the source string.
  static func textChunks(_ text: String, limit: Int) -> [String] {
    precondition(limit > 0)
    guard !text.isEmpty else { return [text] }
    var remainder = text[...]
    var result: [String] = []
    while remainder.count > limit {
      let nominal = remainder.index(remainder.startIndex, offsetBy: limit)
      let prefix = remainder[..<nominal]
      var split = nominal
      if let whitespace = prefix.lastIndex(where: { $0.isWhitespace }),
        prefix.distance(from: prefix.startIndex, to: whitespace) >= limit / 2
      {
        split = remainder.index(after: whitespace)
      }
      result.append(String(remainder[..<split]))
      remainder = remainder[split...]
    }
    if !remainder.isEmpty { result.append(String(remainder)) }
    return result
  }

  private static func fittedTextChunks(
    _ text: String, initialLimit: Int, fits: (String) -> Bool
  ) -> [String] {
    var pending = textChunks(text, limit: initialLimit)
    var result: [String] = []
    while !pending.isEmpty {
      let chunk = pending.removeFirst()
      if fits(chunk) || chunk.count <= 1 {
        result.append(chunk)
      } else {
        pending.insert(contentsOf: textChunks(chunk, limit: max(1, chunk.count / 2)), at: 0)
      }
    }
    return result
  }

  private static func chronologicalSections(_ sections: [NoteSection]) -> [NoteSection] {
    sections.enumerated().sorted { left, right in
      switch (left.element.sourceTime, right.element.sourceTime) {
      case (let leftTime?, let rightTime?) where leftTime != rightTime:
        return leftTime < rightTime
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return left.offset < right.offset
      }
    }.map(\.element)
  }

  private static func studyOrderedSections(_ sections: [NoteSection]) -> [NoteSection] {
    sections.enumerated().sorted { left, right in
      let leftRank = studyRank(left.element)
      let rightRank = studyRank(right.element)
      return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
    }.map(\.element)
  }

  /// Stable semantic grouping keeps every original section intact and makes
  /// unmatched material predictable: sections with the same rank retain their
  /// original source order.
  private static func stableOrder(
    _ sections: [NoteSection], rankedBy rank: (NoteSection) -> Int
  ) -> [NoteSection] {
    sections.enumerated().sorted { left, right in
      let leftRank = rank(left.element)
      let rightRank = rank(right.element)
      return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
    }.map(\.element)
  }

  private static func cornellRank(_ section: NoteSection) -> Int {
    switch section {
    case .definition: return 0
    case .summary: return 2
    default: return 1
    }
  }

  private static func hierarchyRank(_ section: NoteSection) -> Int {
    switch section {
    case .concept: return 0
    case .definition: return 1
    case .methods: return 2
    case .process: return 3
    case .comparison: return 4
    case .quote: return 5
    case .summary: return 6
    }
  }

  private static func flashcardRank(_ section: NoteSection) -> Int {
    switch section {
    case .definition: return 0
    case .concept: return 1
    case .quote: return 2
    case .comparison: return 3
    case .process: return 4
    case .methods: return 5
    case .summary: return 6
    }
  }

  private static func examRank(_ section: NoteSection) -> Int {
    switch section {
    case .summary: return 0
    case .definition: return 1
    case .comparison: return 2
    case .concept: return 3
    case .methods, .process: return 4
    case .quote: return 5
    }
  }

  private static func tutorialRank(_ section: NoteSection) -> Int {
    switch section {
    case .process: return 0
    case .methods: return 1
    case .concept: return 2
    case .definition: return 3
    case .comparison: return 4
    case .quote: return 5
    case .summary: return 6
    }
  }

  private static func decisionsAndActionsRank(_ section: NoteSection) -> Int {
    switch section {
    case .comparison: return 0
    case .process: return 1
    case .methods: return 2
    case .concept: return 3
    case .definition: return 4
    case .quote: return 5
    case .summary: return 6
    }
  }

  private static func studyRank(_ section: NoteSection) -> Int {
    switch section {
    case .summary: return 0
    case .definition: return 1
    case .concept: return 2
    case .methods, .process, .comparison: return 3
    case .quote: return 4
    }
  }

  /// Sections that comfortably share a page.
  static func isSmall(_ section: NoteSection) -> Bool {
    switch section {
    case .definition, .quote: return true
    case .summary(_, let points, _): return points.count <= 3
    case .concept(_, let body, let points, _, let quote, _, let sketch):
      return quote == nil && sketch == nil && (body?.count ?? 0) < 120 && points.count <= 2
    case .process(_, let steps, _, _, let sketch): return sketch == nil && steps.count <= 2
    case .methods, .comparison: return false
    }
  }

  /// Broader than the illustrated layout, while keeping sketch-backed and
  /// structurally dense material on its own page so no content is squeezed out.
  static func isCondensedSmall(_ section: NoteSection) -> Bool {
    switch section {
    case .definition, .quote: return true
    case .summary(_, let points, _): return points.count <= 5
    case .concept(_, let body, let points, _, let quote, _, let sketch):
      return quote == nil && sketch == nil && (body?.count ?? 0) < 220 && points.count <= 4
    case .process(_, let steps, _, _, let sketch): return sketch == nil && steps.count <= 4
    case .methods, .comparison: return false
    }
  }

  /// Cornell cue and summary groups may share a page when the measured layout
  /// proves they fit. Complete note-body sections remain full-page references.
  private static func isCornellPairable(_ section: NoteSection) -> Bool {
    switch section {
    case .definition, .summary: return true
    default: return false
    }
  }

  static func heroIcons(_ document: NoteDocument) -> [String] {
    var hints: [String] = []
    for section in document.sections {
      switch section {
      case .concept(_, _, _, let icons, _, _, _), .process(_, _, let icons, _, _):
        hints.append(contentsOf: icons)
      case .methods(_, let columns, _):
        hints.append(contentsOf: columns.flatMap(\.iconHints))
      default: break
      }
    }
    var unique: [String] = []
    for hint in hints where !unique.contains(hint) { unique.append(hint) }
    if unique.isEmpty { unique = ["document", "chat"] }
    return Array(unique.prefix(2))
  }
}
