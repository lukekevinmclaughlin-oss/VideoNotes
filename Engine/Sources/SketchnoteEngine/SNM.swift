import Foundation

/// Semantic Note Model — the single structured document produced by analysis
/// and consumed by the planner/renderer. See docs/SKETCHNOTE-SPEC.md §5.
public struct NoteDocument: Codable, Equatable, Sendable {
  public var title: String
  public var subtitle: String?
  public var language: String
  public var sections: [NoteSection]
  /// Traced drawing of the video's title/hero frame — the cover art.
  public var heroSketch: [SketchStroke]?

  public init(
    title: String, subtitle: String? = nil, language: String = "en",
    sections: [NoteSection], heroSketch: [SketchStroke]? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.language = language
    self.sections = sections
    self.heroSketch = heroSketch
  }
}

public struct MethodColumn: Codable, Equatable, Sendable {
  public var title: String
  public var tagline: String?
  public var summary: String?
  public var steps: [String]
  public var iconHints: [String]

  public init(
    title: String, tagline: String? = nil, summary: String? = nil, steps: [String] = [],
    iconHints: [String] = []
  ) {
    self.title = title
    self.tagline = tagline
    self.summary = summary
    self.steps = steps
    self.iconHints = iconHints
  }
}

public enum NoteSection: Codable, Equatable, Sendable {
  case concept(
    heading: String, body: String?, points: [String], iconHints: [String], quote: String?,
    sourceTime: Double?, sketch: [SketchStroke]? = nil)
  case methods(heading: String, columns: [MethodColumn], sourceTime: Double?)
  case process(
    heading: String, steps: [String], iconHints: [String], sourceTime: Double?,
    sketch: [SketchStroke]? = nil)
  case comparison(
    heading: String, leftTitle: String, leftPoints: [String], rightTitle: String,
    rightPoints: [String], sourceTime: Double?, sketch: [SketchStroke]? = nil)
  case quote(text: String, attribution: String?, sourceTime: Double?)
  case definition(term: String, meaning: String, sourceTime: Double?)
  case summary(heading: String, points: [String], sourceTime: Double?)

  public var heading: String {
    switch self {
    case .concept(let h, _, _, _, _, _, _), .methods(let h, _, _), .process(let h, _, _, _, _),
      .comparison(let h, _, _, _, _, _, _), .summary(let h, _, _):
      return h
    case .quote(let t, _, _): return t
    case .definition(let term, _, _): return term
    }
  }

  public var sourceTime: Double? {
    switch self {
    case .concept(_, _, _, _, _, let t, _), .methods(_, _, let t), .process(_, _, _, let t, _),
      .comparison(_, _, _, _, _, let t, _), .quote(_, _, let t), .definition(_, _, let t),
      .summary(_, _, let t):
      return t
    }
  }
}

public enum SNMLimits {
  // These are composition targets used by the heuristic structurer. They are
  // deliberately not storage or validation limits: a caller-provided SNM may
  // contain more evidence, and the page planner will flow it onto continuation
  // pages rather than deleting it.
  public static let maxSections = 9
  public static let maxPoints = 6
  public static let maxPointLength = 90
  public static let maxSteps = 6
  public static let maxStepLength = 60
  public static let maxHeadingLength = 80
}

public enum SNMValidation {
  /// Preserve the complete semantic note model. Presentation labels are
  /// bounded so headings remain renderable, but sections and claim payloads
  /// are never shortened or discarded. `PagePlanner` flows those payloads
  /// onto continuation pages.
  public static func sanitize(_ doc: NoteDocument) -> NoteDocument {
    var result = doc
    result.title = clip(doc.title, SNMLimits.maxHeadingLength)
    result.subtitle = doc.subtitle.map { clip($0, 120) }
    result.sections = doc.sections.map(sanitize(section:))
    return result
  }

  static func sanitize(section: NoteSection) -> NoteSection {
    switch section {
    case .concept(let heading, let body, let points, let icons, let quote, let time, let sketch):
      return .concept(
        heading: clip(heading, SNMLimits.maxHeadingLength), body: body, points: points,
        iconHints: icons, quote: quote, sourceTime: time, sketch: sketch)
    case .methods(let heading, let columns, let time):
      return .methods(
        heading: clip(heading, SNMLimits.maxHeadingLength),
        columns: columns.map {
          MethodColumn(
            title: clip($0.title, 40), tagline: $0.tagline, summary: $0.summary,
            steps: $0.steps, iconHints: $0.iconHints)
        }, sourceTime: time)
    case .process(let heading, let steps, let icons, let time, let sketch):
      return .process(
        heading: clip(heading, SNMLimits.maxHeadingLength), steps: steps,
        iconHints: icons, sourceTime: time, sketch: sketch)
    case .comparison(
      let heading, let leftTitle, let left, let rightTitle, let right, let time, let sketch):
      return .comparison(
        heading: clip(heading, SNMLimits.maxHeadingLength),
        leftTitle: clip(leftTitle, 40), leftPoints: left,
        rightTitle: clip(rightTitle, 40), rightPoints: right,
        sourceTime: time, sketch: sketch)
    case .quote(let text, let attribution, let time):
      return .quote(
        text: text, attribution: attribution.map { clip($0, 60) }, sourceTime: time)
    case .definition(let term, let meaning, let time):
      return .definition(term: clip(term, 60), meaning: meaning, sourceTime: time)
    case .summary(let heading, let points, let time):
      return .summary(
        heading: clip(heading, SNMLimits.maxHeadingLength), points: points,
        sourceTime: time)
    }
  }

  static func clip(_ s: String, _ max: Int) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count > max else { return t }
    // cut at a word boundary, add ellipsis
    var cut = String(t.prefix(max - 1))
    if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > max / 2 {
      cut = String(cut[..<space])
    }
    return cut + "…"
  }

  static func clipList(_ list: [String], _ maxCount: Int, _ maxLen: Int) -> [String] {
    Array(list.prefix(maxCount)).map { clip($0, maxLen) }
  }
}
