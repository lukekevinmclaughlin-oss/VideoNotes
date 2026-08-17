import Foundation
import SketchnoteEngine

/// A stable, versioned interchange model for semantic exports. Unlike the
/// visual page plan, this keeps every typed note section intact and therefore
/// never merges claims merely because two sections share a rendered page.
struct SemanticNoteExportEnvelope: Codable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var source: String
  var documentTitle: String
  var documentSubtitle: String?
  var language: String
  var presentationFormat: String
  var evidenceCoverage: String
  var heroSketch: [SketchStroke]?
  var sections: [SemanticExportSection]

  init(
    document: NoteDocument, source: String, presentationFormat: NotePresentationFormat,
    evidenceCoverage: String
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.source = source
    documentTitle = document.title
    documentSubtitle = document.subtitle
    language = document.language
    self.presentationFormat = presentationFormat.rawValue
    self.evidenceCoverage = evidenceCoverage
    heroSketch = document.heroSketch
    sections = document.sections.enumerated().map {
      SemanticExportSection(index: $0.offset, section: $0.element)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, source, documentTitle, documentSubtitle, language, presentationFormat
    case evidenceCoverage, heroSketch, sections
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: container,
        debugDescription: "Unsupported semantic export schema version \(schemaVersion).")
    }
    source = try container.decode(String.self, forKey: .source)
    documentTitle = try container.decode(String.self, forKey: .documentTitle)
    documentSubtitle = try container.decodeIfPresent(String.self, forKey: .documentSubtitle)
    language = try container.decode(String.self, forKey: .language)
    presentationFormat = try container.decode(String.self, forKey: .presentationFormat)
    evidenceCoverage = try container.decode(String.self, forKey: .evidenceCoverage)
    heroSketch = try container.decodeIfPresent([SketchStroke].self, forKey: .heroSketch)
    sections = try container.decode([SemanticExportSection].self, forKey: .sections)

    let validIndexes = sections.enumerated().allSatisfy { $0.offset == $0.element.index }
    let validReviewFlags = sections.allSatisfy {
      $0.requiresReview == ($0.sourceTimeSeconds == nil)
    }
    guard validIndexes, validReviewFlags, sections.allSatisfy({ $0.noteSection != nil }) else {
      throw DecodingError.dataCorruptedError(
        forKey: .sections, in: container,
        debugDescription: "Semantic export sections are malformed or internally inconsistent.")
    }
  }

  var noteDocument: NoteDocument? {
    let decodedSections = sections.compactMap(\.noteSection)
    guard decodedSections.count == sections.count else { return nil }
    return NoteDocument(
      title: documentTitle, subtitle: documentSubtitle, language: language,
      sections: decodedSections, heroSketch: heroSketch)
  }
}

struct SemanticExportSection: Codable, Equatable {
  enum Kind: String, Codable {
    case concept, methods, process, comparison, quote, definition, summary
  }

  struct Method: Codable, Equatable {
    var title: String
    var tagline: String?
    var summary: String?
    var steps: [String]
    var iconHints: [String]

    init(_ column: MethodColumn) {
      title = column.title
      tagline = column.tagline
      summary = column.summary
      steps = column.steps
      iconHints = column.iconHints
    }

    var methodColumn: MethodColumn {
      MethodColumn(
        title: title, tagline: tagline, summary: summary, steps: steps,
        iconHints: iconHints)
    }
  }

  struct Comparison: Codable, Equatable {
    var leftTitle: String
    var leftPoints: [String]
    var rightTitle: String
    var rightPoints: [String]
  }

  var index: Int
  var type: Kind
  var heading: String
  var sourceTimeSeconds: Double?
  var requiresReview: Bool
  var body: String?
  var points: [String]?
  var iconHints: [String]?
  var embeddedQuote: String?
  var methods: [Method]?
  var steps: [String]?
  var comparison: Comparison?
  var quoteText: String?
  var attribution: String?
  var term: String?
  var meaning: String?
  var sourceSketch: [SketchStroke]?

  init(index: Int, section: NoteSection) {
    self.index = index
    sourceTimeSeconds = section.sourceTime
    requiresReview = section.sourceTime == nil

    switch section {
    case .concept(let heading, let body, let points, let icons, let quote, _, let sketch):
      type = .concept
      self.heading = heading
      self.body = body
      self.points = points
      iconHints = icons
      embeddedQuote = quote
      sourceSketch = sketch
    case .methods(let heading, let columns, _):
      type = .methods
      self.heading = heading
      methods = columns.map(Method.init)
    case .process(let heading, let steps, let icons, _, let sketch):
      type = .process
      self.heading = heading
      self.steps = steps
      iconHints = icons
      sourceSketch = sketch
    case .comparison(
      let heading, let leftTitle, let leftPoints, let rightTitle, let rightPoints, _, let sketch):
      type = .comparison
      self.heading = heading
      comparison = Comparison(
        leftTitle: leftTitle, leftPoints: leftPoints,
        rightTitle: rightTitle, rightPoints: rightPoints)
      sourceSketch = sketch
    case .quote(let text, let attribution, _):
      type = .quote
      heading = text
      quoteText = text
      self.attribution = attribution
    case .definition(let term, let meaning, _):
      type = .definition
      heading = term
      self.term = term
      self.meaning = meaning
    case .summary(let heading, let points, _):
      type = .summary
      self.heading = heading
      self.points = points
    }
  }

  /// Reconstructs the exact source semantic section. This makes schema drift
  /// and accidental flattening directly testable.
  var noteSection: NoteSection? {
    switch type {
    case .concept:
      guard let points, let iconHints else { return nil }
      return .concept(
        heading: heading, body: body, points: points, iconHints: iconHints,
        quote: embeddedQuote, sourceTime: sourceTimeSeconds, sketch: sourceSketch)
    case .methods:
      guard let methods else { return nil }
      return .methods(
        heading: heading, columns: methods.map(\.methodColumn), sourceTime: sourceTimeSeconds)
    case .process:
      guard let steps, let iconHints else { return nil }
      return .process(
        heading: heading, steps: steps, iconHints: iconHints,
        sourceTime: sourceTimeSeconds, sketch: sourceSketch)
    case .comparison:
      guard let comparison else { return nil }
      return .comparison(
        heading: heading, leftTitle: comparison.leftTitle,
        leftPoints: comparison.leftPoints, rightTitle: comparison.rightTitle,
        rightPoints: comparison.rightPoints, sourceTime: sourceTimeSeconds,
        sketch: sourceSketch)
    case .quote:
      guard let quoteText else { return nil }
      return .quote(text: quoteText, attribution: attribution, sourceTime: sourceTimeSeconds)
    case .definition:
      guard let term, let meaning else { return nil }
      return .definition(term: term, meaning: meaning, sourceTime: sourceTimeSeconds)
    case .summary:
      guard let points else { return nil }
      return .summary(heading: heading, points: points, sourceTime: sourceTimeSeconds)
    }
  }
}

enum SemanticNoteExporter {
  static func make(
    format: SemanticNoteExportFormat, document: NoteDocument, sourceName: String,
    presentationFormat: NotePresentationFormat, evidenceCoverage: String
  ) -> Data? {
    let title = sourceName.isEmpty ? String(localized: "VideoNotes") : sourceName
    let envelope = SemanticNoteExportEnvelope(
      document: document, source: title, presentationFormat: presentationFormat,
      evidenceCoverage: evidenceCoverage)

    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return try? encoder.encode(envelope)
    case .markdown:
      return markdown(envelope).data(using: .utf8)
    case .plainText:
      return plainText(envelope).data(using: .utf8)
    case .html:
      return html(envelope).data(using: .utf8)
    }
  }

  private static func markdown(_ export: SemanticNoteExportEnvelope) -> String {
    var output = "# \(markdownInline(export.documentTitle))\n\n"
    if let subtitle = export.documentSubtitle, !subtitle.isEmpty {
      output += "_\(markdownInline(subtitle))_\n\n"
    }
    output += "> \(String(localized: "Presentation")): \(presentationName(export)) · \(export.evidenceCoverage)\n\n"
    for section in export.sections {
      output += "## \(markdownInline(displayHeading(section)))\n\n"
      output += markdownEvidence(section) + "\n\n"
      output += markdownBody(section) + "\n\n"
    }
    return output
  }

  private static func markdownEvidence(_ section: SemanticExportSection) -> String {
    if let time = section.sourceTimeSeconds {
      return "**\(String(localized: "Sources")):** \(TimeFormat.mmss(time))"
    }
    return "**\(String(localized: "Evidence")):** \(String(localized: "Synthesized review; verify against the source."))"
  }

  private static func markdownBody(_ section: SemanticExportSection) -> String {
    switch section.type {
    case .concept:
      var parts = [section.body].compactMap { $0 }.map(markdownParagraph)
      if let points = section.points, !points.isEmpty {
        parts.append(points.map { "- \(markdownInline($0))" }.joined(separator: "\n"))
      }
      if let quote = section.embeddedQuote { parts.append(markdownQuote(quote)) }
      return parts.joined(separator: "\n\n")
    case .methods:
      return (section.methods ?? []).map { method in
        var parts = ["### \(markdownInline(method.title))"]
        parts += [method.tagline, method.summary].compactMap { $0 }.map(markdownParagraph)
        if !method.steps.isEmpty {
          parts.append(
            method.steps.enumerated().map {
              "\($0.offset + 1). \(markdownInline($0.element))"
            }
              .joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
      }.joined(separator: "\n\n")
    case .process:
      return (section.steps ?? []).enumerated().map {
        "\($0.offset + 1). \(markdownInline($0.element))"
      }
        .joined(separator: "\n")
    case .comparison:
      guard let comparison = section.comparison else { return "" }
      let left = comparison.leftPoints.map(markdownTableCell).joined(separator: "<br>")
      let right = comparison.rightPoints.map(markdownTableCell).joined(separator: "<br>")
      return "| \(markdownTableCell(comparison.leftTitle)) | \(markdownTableCell(comparison.rightTitle)) |\n| --- | --- |\n| \(left) | \(right) |"
    case .quote:
      let quote = section.quoteText ?? section.heading
      return markdownQuote(quote)
        + (section.attribution.map { "\n> - \(markdownInline($0))" } ?? "")
    case .definition:
      return "**\(markdownInline(section.term ?? section.heading)):** \(markdownParagraph(section.meaning ?? ""))"
    case .summary:
      return (section.points ?? []).map { "- \(markdownInline($0))" }.joined(separator: "\n")
    }
  }

  private static func plainText(_ export: SemanticNoteExportEnvelope) -> String {
    var output = "\(export.documentTitle)\n\(String(repeating: "=", count: max(3, export.documentTitle.count)))\n"
    if let subtitle = export.documentSubtitle, !subtitle.isEmpty { output += subtitle + "\n" }
    output += "\(String(localized: "Presentation")): \(presentationName(export))\n\(export.evidenceCoverage)\n\n"
    for section in export.sections {
      output += "\(section.index + 1). \(displayHeading(section))\n"
      if let time = section.sourceTimeSeconds {
        output += String(localized: "Sources: \(TimeFormat.mmss(time))") + "\n"
      } else {
        output += String(localized: "Evidence: Synthesized review; verify against the source.") + "\n"
      }
      output += plainBody(section) + "\n\n"
    }
    return output
  }

  private static func plainBody(_ section: SemanticExportSection) -> String {
    switch section.type {
    case .concept:
      return ([section.body].compactMap { $0 } + (section.points ?? [])
        + [section.embeddedQuote].compactMap { $0 }).joined(separator: "\n")
    case .methods:
      return (section.methods ?? []).map { method in
        ([method.title, method.tagline, method.summary].compactMap { $0 } + method.steps)
          .joined(separator: "\n")
      }.joined(separator: "\n\n")
    case .process: return (section.steps ?? []).joined(separator: "\n")
    case .comparison:
      guard let comparison = section.comparison else { return "" }
      return ([comparison.leftTitle] + comparison.leftPoints + [comparison.rightTitle]
        + comparison.rightPoints).joined(separator: "\n")
    case .quote:
      return (section.quoteText ?? section.heading)
        + (section.attribution.map { "\n- \($0)" } ?? "")
    case .definition: return section.meaning ?? ""
    case .summary: return (section.points ?? []).joined(separator: "\n")
    }
  }

  private static func html(_ export: SemanticNoteExportEnvelope) -> String {
    let uiLanguage = Locale.current.language.languageCode?.identifier ?? "en"
    let sections = export.sections.map { section in
      let headingLanguage =
        section.type == .quote || section.type == .definition ? uiLanguage : export.language
      let evidence: String
      if let time = section.sourceTimeSeconds {
        evidence = String(localized: "Sources: \(TimeFormat.mmss(time))")
      } else {
        evidence = String(localized: "Synthesized review; verify against the source.")
      }
      return """
        <section data-note-type="\(section.type.rawValue)">
        <p class="eyebrow" lang="\(htmlEscaped(uiLanguage))">\(htmlEscaped(kindLabel(section.type)))</p>
        <h2 lang="\(htmlEscaped(headingLanguage))">\(htmlEscaped(displayHeading(section)))</h2>
        <p class="evidence" lang="\(htmlEscaped(uiLanguage))">\(htmlEscaped(evidence))</p>
        \(htmlBody(section))
        </section>
        """
    }.joined(separator: "\n")
    return """
      <!doctype html><html lang="\(htmlEscaped(export.language))"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>\(htmlEscaped(export.documentTitle))</title><style>:root{color-scheme:light}body{font:17px/1.6 system-ui,sans-serif;max-width:820px;margin:auto;padding:48px 24px;color:#17202a;background:#f8fafc}main>header,section{background:white;border:1px solid #dce4ea;border-radius:18px;padding:24px;margin:20px 0;box-shadow:0 8px 28px #17202a0d}h1,h2,h3{line-height:1.15}h3{margin-bottom:.25rem}.eyebrow,.evidence{font-size:.8rem;font-weight:700;letter-spacing:.08em;color:#357187}.evidence{letter-spacing:0;color:#876b21}blockquote{border-left:4px solid #55a8bd;margin-left:0;padding-left:1rem}table{border-collapse:collapse;width:100%}th,td{border:1px solid #dce4ea;padding:.75rem;text-align:left;vertical-align:top}dt{font-weight:700}dd{margin:0 0 1rem}</style></head><body><main>
      <header><h1>\(htmlEscaped(export.documentTitle))</h1>\(export.documentSubtitle.map { "<p>\(htmlEscaped($0))</p>" } ?? "")<p lang="\(htmlEscaped(uiLanguage))">\(htmlEscaped(export.evidenceCoverage))</p></header>
      \(sections)
      </main></body></html>
      """
  }

  private static func htmlBody(_ section: SemanticExportSection) -> String {
    switch section.type {
    case .concept:
      var body = section.body.map { "<p>\(htmlEscaped($0))</p>" } ?? ""
      body += htmlList(section.points ?? [], ordered: false)
      if let quote = section.embeddedQuote {
        body += "<blockquote><p>\(htmlEscaped(quote))</p></blockquote>"
      }
      return body
    case .methods:
      return (section.methods ?? []).map { method in
        let tagline = method.tagline.map { "<p><strong>\(htmlEscaped($0))</strong></p>" } ?? ""
        let summary = method.summary.map { "<p>\(htmlEscaped($0))</p>" } ?? ""
        return "<article><h3>\(htmlEscaped(method.title))</h3>\(tagline)\(summary)\(htmlList(method.steps, ordered: true))</article>"
      }.joined()
    case .process: return htmlList(section.steps ?? [], ordered: true)
    case .comparison:
      guard let comparison = section.comparison else { return "" }
      return """
        <table><thead><tr><th>\(htmlEscaped(comparison.leftTitle))</th><th>\(htmlEscaped(comparison.rightTitle))</th></tr></thead>
        <tbody><tr><td>\(htmlList(comparison.leftPoints, ordered: false))</td><td>\(htmlList(comparison.rightPoints, ordered: false))</td></tr></tbody></table>
        """
    case .quote:
      let citation = section.attribution.map { "<cite>\(htmlEscaped($0))</cite>" } ?? ""
      return "<blockquote><p>\(htmlEscaped(section.quoteText ?? section.heading))</p>\(citation)</blockquote>"
    case .definition:
      return "<dl><dt>\(htmlEscaped(section.term ?? section.heading))</dt><dd>\(htmlEscaped(section.meaning ?? ""))</dd></dl>"
    case .summary: return htmlList(section.points ?? [], ordered: false)
    }
  }

  private static func htmlList(_ values: [String], ordered: Bool) -> String {
    guard !values.isEmpty else { return "" }
    let tag = ordered ? "ol" : "ul"
    return "<\(tag)>" + values.map { "<li>\(htmlEscaped($0))</li>" }.joined() + "</\(tag)>"
  }

  private static func presentationName(_ export: SemanticNoteExportEnvelope) -> String {
    NotePresentationFormat(rawValue: export.presentationFormat)?.localizedDisplayName
      ?? export.presentationFormat
  }

  private static func displayHeading(_ section: SemanticExportSection) -> String {
    switch section.type {
    case .quote: return String(localized: "Quote")
    case .definition: return String(localized: "Definition")
    default: return section.heading
    }
  }

  private static func kindLabel(_ kind: SemanticExportSection.Kind) -> String {
    switch kind {
    case .concept: return String(localized: "Concept")
    case .methods: return String(localized: "Methods")
    case .process: return String(localized: "Process")
    case .comparison: return String(localized: "Comparison")
    case .quote: return String(localized: "Quote")
    case .definition: return String(localized: "Definition")
    case .summary: return String(localized: "Summary")
    }
  }

  private static func markdownInline(_ value: String) -> String {
    value.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "*", with: "\\*")
      .replacingOccurrences(of: "_", with: "\\_")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
      .replacingOccurrences(of: "#", with: "\\#")
  }

  private static func markdownParagraph(_ value: String) -> String {
    value.split(separator: "\n", omittingEmptySubsequences: false)
      .map { markdownInline(String($0)) }.joined(separator: "  \n")
  }

  private static func markdownQuote(_ value: String) -> String {
    value.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> \(markdownInline(String($0)))" }.joined(separator: "\n")
  }

  private static func markdownTableCell(_ value: String) -> String {
    markdownInline(value).replacingOccurrences(of: "|", with: "\\|")
  }

  private static func htmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}
