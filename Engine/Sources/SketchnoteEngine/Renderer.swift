import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws sketchnote pages with the RoughPen. Fully deterministic for a given
/// (document, style) — every wobble comes from the style seed.
public struct PageRenderer {

  public init() {}

  // MARK: - entry points

  public func renderImages(document: NoteDocument, style: RenderStyle, scale: CGFloat = 2)
    -> [CGImage]
  {
    let pages = PagePlanner.plan(document, format: style.presentationFormat)
    var images: [CGImage] = []
    for index in pages.indices {
      guard !Task.isCancelled else { break }
      if let image = renderImage(
        page: pages[index], index: index, total: pages.count,
        style: style, scale: scale)
      {
        images.append(image)
      }
    }
    return images
  }

  public func renderImage(
    page: PageContent, index: Int, total: Int, style: RenderStyle, scale: CGFloat = 2
  ) -> CGImage? {
    let size = PageMetrics.size
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil,
        width: Int(size.width * scale), height: Int(size.height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    flipToTopLeft(context, height: size.height)
    draw(page: page, index: index, total: total, style: style, in: context)
    return context.makeImage()
  }

  public func renderPDF(document: NoteDocument, style: RenderStyle) -> Data {
    renderPDF(document: document, style: style, includesSemanticText: true)
  }

  /// Internal seam used by visual-regression tests. Shipping exports always
  /// include the semantic layer through the public two-argument entry point.
  func renderPDF(
    document: NoteDocument, style: RenderStyle, includesSemanticText: Bool
  ) -> Data {
    let pages = PagePlanner.plan(document, format: style.presentationFormat)
    let data = NSMutableData()
    let outputSize = style.pdfPageFormat.pageSize
    var mediaBox = CGRect(origin: .zero, size: outputSize)
    let metadata = pdfMetadata(document: document, style: style)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata)
    else { return Data() }
    if let xmp = xmpMetadata(document: document, style: style) {
      context.addDocumentMetadata(xmp as CFData)
    }
    for (index, page) in pages.enumerated() {
      guard !Task.isCancelled else { break }
      context.beginPDFPage(nil)
      context.saveGState()
      let scale = min(
        outputSize.width / PageMetrics.size.width,
        outputSize.height / PageMetrics.size.height)
      let offset = CGPoint(
        x: (outputSize.width - PageMetrics.size.width * scale) / 2,
        y: (outputSize.height - PageMetrics.size.height * scale) / 2)
      context.translateBy(x: offset.x, y: offset.y)
      context.scaleBy(x: scale, y: scale)
      flipToTopLeft(context, height: PageMetrics.size.height)
      // The illustrated page contains decorative text that is duplicated by
      // the invisible, source-ordered semantic layer below. Establish the
      // modern tagged-PDF path before Core Text draws anything, and keep that
      // decorative representation out of the document's reading structure.
      // This also avoids mixing Core Text's legacy PDF tagging path with
      // CGPDFContextBeginTag in hosted app/test processes.
      CGPDFContextBeginTag(context, .nonStructure, [:] as CFDictionary)
      draw(page: page, index: index, total: pages.count, style: style, in: context)
      CGPDFContextEndTag(context)
      context.restoreGState()
      if includesSemanticText {
        drawSemanticText(
          for: page, documentTitle: document.title, index: index, total: pages.count,
          outputSize: outputSize, in: context)
      }
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }

  /// Standard PDF document information. These values are intentionally based
  /// only on the semantic note model; no author or topic is invented.
  private func pdfMetadata(document: NoteDocument, style: RenderStyle) -> CFDictionary {
    let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeTitle = title.isEmpty ? "Video Notes" : title
    let format = metadataName(for: style.presentationFormat)
    let language = document.language.trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = "\(format) video notes. Language: \(language.isEmpty ? "unspecified" : language)."
    var keywords = [
      "VideoNotes", "illustrated notes", "video notes", "source-grounded notes", format,
    ]
    for heading in document.sections.map(\.heading) {
      let normalized = heading.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty,
        !keywords.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame })
      {
        keywords.append(normalized)
      }
      if keywords.count >= 12 { break }
    }
    return [
      kCGPDFContextTitle: safeTitle,
      kCGPDFContextAuthor: "VideoNotes",
      kCGPDFContextSubject: subject,
      kCGPDFContextKeywords: keywords.joined(separator: ", "),
      kCGPDFContextCreator: "VideoNotes / SketchnoteEngine",
    ] as CFDictionary
  }

  /// Mirrors the document information in an XMP metadata stream so search,
  /// library, and archival tools do not have to rely on the legacy Info map.
  private func xmpMetadata(document: NoteDocument, style: RenderStyle) -> Data? {
    let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeTitle = title.isEmpty ? "Video Notes" : title
    let language = document.language.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeLanguage = language.isEmpty ? "x-default" : language
    let format = metadataName(for: style.presentationFormat)
    let subject = "\(format) video notes. Language: \(language.isEmpty ? "unspecified" : language)."
    var keywords = [
      "VideoNotes", "illustrated notes", "video notes", "source-grounded notes", format,
    ]
    for heading in document.sections.map(\.heading) {
      let normalized = heading.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty,
        !keywords.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame })
      {
        keywords.append(normalized)
      }
      if keywords.count >= 12 { break }
    }

    let packet = """
      <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
      <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/">
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(xmlEscaped(safeTitle))</rdf:li></rdf:Alt></dc:title>
            <dc:creator><rdf:Seq><rdf:li>VideoNotes</rdf:li></rdf:Seq></dc:creator>
            <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(xmlEscaped(subject))</rdf:li></rdf:Alt></dc:description>
            <dc:language><rdf:Bag><rdf:li>\(xmlEscaped(safeLanguage))</rdf:li></rdf:Bag></dc:language>
            <pdf:Keywords>\(xmlEscaped(keywords.joined(separator: ", ")))</pdf:Keywords>
            <xmp:CreatorTool>VideoNotes / SketchnoteEngine</xmp:CreatorTool>
          </rdf:Description>
        </rdf:RDF>
      </x:xmpmeta>
      <?xpacket end="w"?>
      """
    return packet.data(using: .utf8)
  }

  private func xmlEscaped(_ value: String) -> String {
    let validScalars = value.unicodeScalars.filter { scalar in
      scalar.value == 0x9 || scalar.value == 0xA || scalar.value == 0xD
        || (0x20...0xD7FF).contains(scalar.value)
        || (0xE000...0xFFFD).contains(scalar.value)
        || (0x10000...0x10FFFF).contains(scalar.value)
    }
    return String(String.UnicodeScalarView(validScalars))
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  private func metadataName(for format: NotePresentationFormat) -> String {
    switch format {
    case .illustrated: return "Illustrated"
    case .detailed: return "Detailed"
    case .condensed: return "Condensed review"
    case .evidenceFirst: return "Evidence-first"
    case .focusCards: return "Focus cards"
    case .quickReview: return "Quick review"
    case .studyGuide: return "Study guide"
    case .cornellNotes: return "Cornell notes"
    case .hierarchicalOutline: return "Hierarchical outline"
    case .timeline: return "Timeline / chapter map"
    case .qaFlashcards: return "Q&A flashcards"
    case .examRevision: return "Exam revision"
    case .tutorial: return "Tutorial / step-by-step"
    case .decisionsAndActions: return "Decisions & action items"
    }
  }

  /// Places selectable/searchable text in the page content stream using PDF's
  /// invisible text rendering mode. The semantic layer is drawn after the
  /// illustrated page and cannot change its pixels.
  private func drawSemanticText(
    for page: PageContent, documentTitle: String, index: Int, total: Int,
    outputSize: CGSize, in context: CGContext
  ) {
    let lines = semanticLines(
      for: page, documentTitle: documentTitle, index: index, total: total
    )
    .flatMap(wrappedSemanticLines)
    guard !lines.isEmpty else { return }

    context.saveGState()
    context.setTextDrawingMode(.invisible)
    context.textMatrix = .identity
    let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font
    ]
    var y = outputSize.height - 18
    for (lineIndex, value) in lines.enumerated() {
      let attributed = NSAttributedString(string: value, attributes: attributes)
      let line = CTLineCreateWithAttributedString(attributed)
      let tagProperties =
        [
          CGPDFTagProperty.actualText.rawValue: value
        ] as CFDictionary
      CGPDFContextBeginTag(context, lineIndex == 0 ? .header1 : .paragraph, tagProperties)
      context.textPosition = CGPoint(x: 18, y: y)
      CTLineDraw(line, context)
      CGPDFContextEndTag(context)
      y -= 10
      if y < 18 { break }
    }
    context.restoreGState()
  }

  private func wrappedSemanticLines(_ line: String) -> [String] {
    let normalized = line.replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard normalized.count > 110 else { return normalized.isEmpty ? [] : [normalized] }

    var result: [String] = []
    var current = ""
    for word in normalized.split(separator: " ").map(String.init) {
      if current.isEmpty {
        current = word
      } else if current.count + word.count + 1 <= 110 {
        current += " " + word
      } else {
        result.append(current)
        current = word
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private func semanticLines(
    for page: PageContent, documentTitle: String, index: Int, total: Int
  ) -> [String] {
    var lines = [documentTitle, "Page \(index + 1) of \(total)"]
    switch page {
    case .hero(let title, let subtitle, _, _):
      if title != documentTitle { lines.append(title) }
      if let subtitle { lines.append(subtitle) }
    case .single(let section):
      lines.append(contentsOf: semanticLines(for: section))
    case .pair(let first, let second):
      lines.append(contentsOf: semanticLines(for: first))
      lines.append(contentsOf: semanticLines(for: second))
    }
    return lines
  }

  private func semanticLines(for section: NoteSection) -> [String] {
    var lines: [String] = []
    if let sourceTime = section.sourceTime {
      lines.append("Source time: \(TimeFormat.mmss(sourceTime))")
    } else if case .summary = section {
      lines.append("Synthesized review")
    }

    switch section {
    case .concept(let heading, let body, let points, _, let quote, _, _):
      lines.append(heading)
      if let body { lines.append(body) }
      lines.append(contentsOf: points.map { "Bullet: \($0)" })
      if let quote { lines.append("Quote: \(quote)") }
    case .methods(let heading, let columns, _):
      lines.append(heading)
      for column in columns {
        lines.append(column.title)
        if let tagline = column.tagline { lines.append(tagline) }
        if let summary = column.summary { lines.append(summary) }
        lines.append(
          contentsOf: column.steps.enumerated().map { "Step \($0.offset + 1): \($0.element)" })
      }
    case .process(let heading, let steps, _, _, _):
      lines.append(heading)
      lines.append(contentsOf: steps.enumerated().map { "Step \($0.offset + 1): \($0.element)" })
    case .comparison(
      let heading, let leftTitle, let leftPoints, let rightTitle, let rightPoints, _, _):
      lines.append(heading)
      lines.append(leftTitle)
      lines.append(contentsOf: leftPoints.map { "Bullet: \($0)" })
      lines.append(rightTitle)
      lines.append(contentsOf: rightPoints.map { "Bullet: \($0)" })
    case .quote(let text, let attribution, _):
      lines.append("Quote: \(text)")
      if let attribution { lines.append("Attribution: \(attribution)") }
    case .definition(let term, let meaning, _):
      lines.append(term)
      lines.append("Definition: \(meaning)")
    case .summary(let heading, let points, _):
      lines.append(heading)
      lines.append(contentsOf: points.map { "Bullet: \($0)" })
    }
    return lines
  }

  public static func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return Data() }
    return data as Data
  }

  private func flipToTopLeft(_ context: CGContext, height: CGFloat) {
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
  }

  // MARK: - page dispatch

  func draw(page: PageContent, index: Int, total: Int, style: RenderStyle, in context: CGContext) {
    let pageSeed = style.seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
    var pen = RoughPen(context: context, seed: pageSeed)
    let text = TextKit(context: context)
    let palette = style.palette
    let size = PageMetrics.size

    // paper + grain
    context.setFillColor(palette.paper)
    context.fill(CGRect(origin: .zero, size: size))
    var grain = SplitMix64(seed: pageSeed ^ 0xFEED)
    context.setFillColor(palette.ink.copy(alpha: 0.028) ?? palette.ink)
    for _ in 0..<200 {
      let x = grain.range(0...size.width)
      let y = grain.range(0...size.height)
      context.fillEllipse(
        in: CGRect(x: x, y: y, width: grain.range(1...2.6), height: grain.range(1...2.6)))
    }

    switch page {
    case .hero(let title, let subtitle, let icons, let sketch):
      drawHero(
        title: title, subtitle: subtitle, icons: icons, sketch: sketch,
        pen: &pen, text: text, palette: palette, style: style)
    case .single(let section):
      let rect = contentRect()
      let natural = min(measureSection(section, width: rect.width, style: style), rect.height)
      // sparse sections drift toward the optical centre instead of hugging the top
      let offset = natural < rect.height * 0.5 ? (rect.height - natural) * 0.30 : 0
      drawSection(
        section,
        in: CGRect(
          x: rect.minX, y: rect.minY + offset,
          width: rect.width, height: rect.height - offset),
        pen: &pen, text: text, palette: palette, style: style, solo: true)
    case .pair(let top, let bottom):
      let rect = contentRect()
      let gap: CGFloat = 110
      let topHeight = min(
        measureSection(top, width: rect.width, style: style), (rect.height - gap) / 2)
      let bottomHeight = min(
        measureSection(bottom, width: rect.width, style: style), (rect.height - gap) / 2)
      let startY = rect.minY + max(0, (rect.height - topHeight - bottomHeight - gap) / 2)
      drawSection(
        top, in: CGRect(x: rect.minX, y: startY, width: rect.width, height: topHeight),
        pen: &pen, text: text, palette: palette, style: style, solo: false)
      // A neutral divider keeps adjacent sections visually distinct without
      // implying that one causes or leads to the other.
      let dividerY = startY + topHeight + gap / 2
      context.saveGState()
      context.setFillColor(palette.accent.copy(alpha: 0.58) ?? palette.accent)
      for offset in [-30.0, 0, 30.0] as [CGFloat] {
        context.fillEllipse(
          in: CGRect(x: rect.midX + offset - 5, y: dividerY - 5, width: 10, height: 10))
      }
      context.restoreGState()
      drawSection(
        bottom,
        in: CGRect(
          x: rect.minX, y: startY + topHeight + gap, width: rect.width, height: bottomHeight),
        pen: &pen, text: text, palette: palette, style: style, solo: false)
    }

    // footer
    let footerFont = FontBook.font(.body, size: 24)
    text.draw(
      "VideoNotes", font: footerFont, color: palette.ink.copy(alpha: 0.4) ?? palette.ink,
      in: CGRect(x: PageMetrics.margin, y: size.height - 54, width: 300, height: 40))
    if total > 1 {
      text.draw(
        "\(index + 1) / \(total)", font: footerFont,
        color: palette.ink.copy(alpha: 0.4) ?? palette.ink,
        in: CGRect(
          x: size.width - PageMetrics.margin - 120, y: size.height - 54, width: 120, height: 40),
        align: .right)
    }
    if let sourceLabel = sourceLabel(for: page) {
      text.draw(
        sourceLabel, font: footerFont,
        color: palette.accent.copy(alpha: 0.72) ?? palette.accent,
        in: CGRect(x: size.width / 2 - 190, y: size.height - 54, width: 380, height: 40),
        align: .center)
    }
  }

  func sourceLabel(for page: PageContent) -> String? {
    switch page {
    case .hero: return nil
    case .single(let section):
      if case .summary(_, _, nil) = section { return "SYNTHESIZED REVIEW" }
      return section.sourceTime.map { "SOURCE · \(TimeFormat.mmss($0))" }
    case .pair(let first, let second):
      let times = [first.sourceTime, second.sourceTime].compactMap { $0 }
      let includesSynthesizedReview = [first, second].contains { section in
        if case .summary(_, _, nil) = section { return true }
        return false
      }
      guard let firstTime = times.first else {
        return includesSynthesizedReview ? "SYNTHESIZED REVIEW" : nil
      }
      if includesSynthesizedReview {
        return "SYNTHESIZED REVIEW · SOURCE \(TimeFormat.mmss(firstTime))"
      }
      if times.count > 1, abs(times[1] - firstTime) >= 1 {
        return "SOURCES · \(TimeFormat.mmss(firstTime)) + \(TimeFormat.mmss(times[1]))"
      }
      return "SOURCE · \(TimeFormat.mmss(firstTime))"
    }
  }

  func contentRect() -> CGRect {
    CGRect(
      x: PageMetrics.margin, y: PageMetrics.margin + 20,
      width: PageMetrics.size.width - PageMetrics.margin * 2,
      height: PageMetrics.size.height - PageMetrics.margin * 2 - 80)
  }

  func fontScale(_ style: RenderStyle) -> CGFloat { style.compact ? 0.9 : 1 }

  // MARK: - hero

  func drawHero(
    title: String, subtitle: String?, icons: [String], sketch: [SketchStroke]?,
    pen: inout RoughPen, text: TextKit, palette: Palette, style: RenderStyle
  ) {
    let size = PageMetrics.size
    let margin = PageMetrics.margin
    let s = fontScale(style)

    // corner brackets (reference: hand-drawn frame corners)
    let b: CGFloat = 84
    pen.strokePolyline(
      [
        CGPoint(x: margin, y: margin + b), CGPoint(x: margin, y: margin),
        CGPoint(x: margin + b, y: margin),
      ],
      color: palette.ink, width: 5)
    pen.strokePolyline(
      [
        CGPoint(x: size.width - margin - b, y: size.height - margin),
        CGPoint(x: size.width - margin, y: size.height - margin),
        CGPoint(x: size.width - margin, y: size.height - margin - b),
      ],
      color: palette.ink, width: 5)

    let titleFont = FontBook.font(.heading, size: 92 * s)
    let titleWidth = size.width - margin * 2 - 40
    let titleHeight = TextKit.measure(title, font: titleFont, width: titleWidth).height
    var y: CGFloat = 250
    text.draw(
      title, font: titleFont, color: palette.ink,
      in: CGRect(x: margin + 20, y: y, width: titleWidth, height: titleHeight + 20), align: .center)
    y += titleHeight + 42

    if let subtitle {
      let subFont = FontBook.font(.script, size: 52 * s)
      let subHeight = TextKit.measure(subtitle, font: subFont, width: titleWidth).height
      // highlighter behind the subtitle's middle
      let lineWidth = min(titleWidth, TextKit.lineWidth(subtitle, font: subFont))
      pen.highlight(
        CGRect(
          x: (size.width - lineWidth) / 2 - 14, y: y + 6, width: lineWidth + 28,
          height: min(subHeight, 66)),
        color: palette.highlight)
      text.draw(
        subtitle, font: subFont, color: palette.ink,
        in: CGRect(x: margin + 20, y: y, width: titleWidth, height: subHeight + 20), align: .center)
      y += subHeight + 60
    }

    // central art: the video's own traced frame when we have one
    if let sketch, !sketch.isEmpty {
      let artHeight = min(size.height - y - 430, 720)
      let artRect = CGRect(
        x: margin + 60, y: y + 40, width: size.width - (margin + 60) * 2, height: artHeight)
      drawTracedFigure(sketch, in: artRect, pen: &pen, palette: palette, framed: true)
      pen.sparkle(
        at: CGPoint(x: artRect.maxX - 8, y: artRect.minY + 6), size: 52, color: palette.gold)
      pen.sparkle(
        at: CGPoint(x: artRect.maxX + 16, y: artRect.minY + 44), size: 28, color: palette.gold)
      let squiggleY = size.height - 300
      var points: [CGPoint] = []
      for i in 0...16 {
        let x = size.width / 2 - 130 + CGFloat(i) * 16.5
        points.append(CGPoint(x: x, y: squiggleY + (i % 2 == 0 ? -9 : 9)))
      }
      pen.strokePolyline(
        points, color: palette.ink.copy(alpha: 0.5) ?? palette.ink, width: 3.4, wobble: 1.4,
        passes: 1)
      return
    }

    // No source image means no semantic illustration. Use a clearly
    // decorative signal motif rather than inferred icons/arrows that
    // could imply a relationship the lecture never made.
    let cy = y + (size.height - y - 420) / 2
    for diameter in [430.0, 320.0, 210.0] as [CGFloat] {
      pen.ellipse(
        in: CGRect(
          x: size.width / 2 - diameter / 2, y: cy - diameter / 2,
          width: diameter, height: diameter),
        color: palette.accent.copy(alpha: diameter == 210 ? 0.8 : 0.35) ?? palette.accent,
        width: diameter == 210 ? 4 : 2.5)
    }
    var signal: [CGPoint] = []
    for i in 0...18 {
      let x = size.width / 2 - 145 + CGFloat(i) * 16
      let amplitude: CGFloat = i % 4 == 0 ? 48 : (i % 2 == 0 ? 24 : -28)
      signal.append(CGPoint(x: x, y: cy + amplitude))
    }
    pen.strokePolyline(signal, color: palette.ink, width: 5, wobble: 1.2, passes: 1)

    // small ink squiggle decoration bottom-centre
    let squiggleY = size.height - 300
    var points: [CGPoint] = []
    for i in 0...16 {
      let x = size.width / 2 - 130 + CGFloat(i) * 16.5
      points.append(CGPoint(x: x, y: squiggleY + (i % 2 == 0 ? -9 : 9)))
    }
    pen.strokePolyline(
      points, color: palette.ink.copy(alpha: 0.5) ?? palette.ink, width: 3.4, wobble: 1.4, passes: 1
    )
  }

  func context(_ pen: RoughPen) -> CGContext { pen.context }

  func wobblyBlob(in rect: CGRect, rng: inout SplitMix64, context: CGContext) {
    let cx = rect.midX
    let cy = rect.midY
    let path = CGMutablePath()
    let n = 14
    var pts: [CGPoint] = []
    for i in 0..<n {
      let a = CGFloat(i) / CGFloat(n) * 2 * .pi
      let rx = rect.width / 2 * rng.range(0.82...1.0)
      let ry = rect.height / 2 * rng.range(0.82...1.0)
      pts.append(CGPoint(x: cx + cos(a) * rx, y: cy + sin(a) * ry))
    }
    path.move(to: pts[0])
    for i in 1...n {
      let p = pts[i % n]
      let prev = pts[i - 1]
      path.addQuadCurve(
        to: CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2),
        control: prev)
    }
    path.closeSubpath()
    context.addPath(path)
    context.fillPath()
  }

  // MARK: - section dispatch

  func drawSection(
    _ section: NoteSection, in rect: CGRect, pen: inout RoughPen, text: TextKit,
    palette: Palette, style: RenderStyle, solo: Bool
  ) {
    switch section {
    case .concept(let heading, let body, let points, let icons, let quote, _, let sketch):
      drawConcept(
        heading: heading, body: body, points: points, icons: icons, quote: quote,
        sketch: sketch, in: rect, pen: &pen, text: text, palette: palette, style: style, solo: solo)
    case .methods(let heading, let columns, _):
      drawMethods(
        heading: heading, columns: columns, in: rect, pen: &pen, text: text, palette: palette,
        style: style)
    case .process(let heading, let steps, let icons, _, let sketch):
      drawProcess(
        heading: heading, steps: steps, icons: icons, sketch: sketch,
        in: rect, pen: &pen, text: text, palette: palette, style: style, solo: solo)
    case .comparison(let heading, let lt, let lp, let rt, let rp, _, let sketch):
      drawComparison(
        heading: heading, leftTitle: lt, leftPoints: lp, rightTitle: rt, rightPoints: rp,
        sketch: sketch, in: rect, pen: &pen, text: text, palette: palette, style: style)
    case .quote(let quoteText, let attribution, _):
      drawQuoteCard(
        quoteText, attribution: attribution, in: rect, pen: &pen, text: text, palette: palette,
        style: style, big: solo)
    case .definition(let term, let meaning, _):
      drawDefinition(
        term: term, meaning: meaning, in: rect, pen: &pen, text: text, palette: palette,
        style: style)
    case .summary(let heading, let points, _):
      drawSummary(
        heading: heading, points: points, in: rect, pen: &pen, text: text, palette: palette,
        style: style)
    }
  }

  /// Heading with highlight chip + underline. Returns new y below it.
  func drawHeading(
    _ heading: String, in rect: CGRect, pen: inout RoughPen, text: TextKit,
    palette: Palette, style: RenderStyle, centered: Bool = false
  ) -> CGFloat {
    let font = FontBook.font(.heading, size: 58 * fontScale(style))
    let height = TextKit.measure(heading, font: font, width: rect.width).height
    let extents = TextKit.lineExtents(heading, font: font, width: rect.width)
    // highlight sits behind the LAST laid-out line
    let hx = centered ? rect.midX - extents.last / 2 : rect.minX
    pen.highlight(
      CGRect(
        x: hx - 8, y: rect.minY + height - min(height, 58) + 12,
        width: min(extents.last, rect.width) + 20, height: min(height, 52)),
      color: palette.highlight)
    text.draw(
      heading, font: font, color: palette.ink,
      in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height + 12),
      align: centered ? .center : .left)
    let underlineY = rect.minY + height + 20
    let underlineWidth = min(max(extents.first, extents.last) + 30, rect.width)
    let ux = centered ? rect.midX - underlineWidth / 2 : rect.minX
    pen.line(
      from: CGPoint(x: ux, y: underlineY),
      to: CGPoint(x: ux + underlineWidth, y: underlineY),
      color: palette.accent, width: 4.4, wobble: 2.6)
    return underlineY + 34
  }

  func drawBullets(
    _ points: [String], from y: CGFloat, in rect: CGRect, pen: inout RoughPen,
    text: TextKit, palette: Palette, style: RenderStyle, font: CTFont? = nil
  ) -> CGFloat {
    let bodyFont = font ?? FontBook.font(.body, size: 37 * fontScale(style))
    var y = y
    for point in points {
      let textX = rect.minX + 52
      let width = rect.maxX - textX
      let height = TextKit.measure(point, font: bodyFont, width: width).height
      guard y + height <= rect.maxY else { break }
      // diamond bullet
      let cy = y + 22
      pen.strokePolyline(
        [
          CGPoint(x: rect.minX + 14, y: cy - 9), CGPoint(x: rect.minX + 23, y: cy),
          CGPoint(x: rect.minX + 14, y: cy + 9), CGPoint(x: rect.minX + 5, y: cy),
        ],
        color: palette.accent, width: 3.4, wobble: 0.9, closed: true)
      text.draw(
        point, font: bodyFont, color: palette.ink,
        in: CGRect(x: textX, y: y, width: width, height: height + 8))
      y += height + 22
    }
    return y
  }

  // MARK: - concept

  func drawConcept(
    heading: String, body: String?, points: [String], icons: [String], quote: String?,
    sketch: [SketchStroke]?, in rect: CGRect, pen: inout RoughPen, text: TextKit,
    palette: Palette, style: RenderStyle, solo: Bool
  ) {
    var y = drawHeading(heading, in: rect, pen: &pen, text: text, palette: palette, style: style)

    // this section's own frame, traced — beats any generic doodle
    if solo, let sketch, !sketch.isEmpty {
      let figureHeight: CGFloat = min(430, rect.height * 0.34)
      let figureRect = CGRect(
        x: rect.minX + rect.width * 0.12, y: y + 12,
        width: rect.width * 0.76, height: figureHeight)
      drawTracedFigure(sketch, in: figureRect, pen: &pen, palette: palette, framed: true)
      pen.sparkle(
        at: CGPoint(x: figureRect.maxX + 14, y: figureRect.minY + 8), size: 30, color: palette.gold)
      y = figureRect.maxY + 44
    }

    if let body, !body.isEmpty {
      let bodyFont = FontBook.font(.body, size: 38 * fontScale(style))
      let height = TextKit.measure(body, font: bodyFont, width: rect.width).height
      if y + height <= rect.maxY {
        text.draw(
          body, font: bodyFont, color: palette.ink.copy(alpha: 0.88) ?? palette.ink,
          in: CGRect(x: rect.minX, y: y, width: rect.width, height: height + 8))
        y += height + 34
      }
    }

    y = drawBullets(
      points, from: y, in: rect, pen: &pen, text: text, palette: palette, style: style)

    if let quote, y + 200 <= rect.maxY {
      drawQuoteCard(
        quote, attribution: nil,
        in: CGRect(x: rect.minX, y: max(y + 20, rect.maxY - 320), width: rect.width, height: 290),
        pen: &pen, text: text, palette: palette, style: style, big: false)
    }
  }

  // MARK: - methods (columns)

  func drawMethods(
    heading: String, columns: [MethodColumn], in rect: CGRect, pen: inout RoughPen,
    text: TextKit, palette: Palette, style: RenderStyle
  ) {
    var y = drawHeading(
      heading, in: rect, pen: &pen, text: text, palette: palette, style: style, centered: true)
    y += 8
    let count = max(1, columns.count)
    let gap: CGFloat = 30
    let columnWidth = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
    let s = fontScale(style)
    // columns hug the tallest column's content instead of the whole page
    let measured = columns.map { measureColumn($0, width: columnWidth - 44, scale: s) }
    let columnHeight = min(rect.maxY - y, (measured.max() ?? 400) + 48)

    for (i, column) in columns.enumerated() {
      let frame = CGRect(
        x: rect.minX + CGFloat(i) * (columnWidth + gap), y: y,
        width: columnWidth, height: columnHeight)
      pen.rect(frame, color: palette.ink, width: 4, cornerRadius: 18)
      var cy = frame.minY + 26
      let inner = frame.insetBy(dx: 22, dy: 0)

      // title chip
      let titleFont = FontBook.font(.heading, size: 34 * s)
      let titleHeight = TextKit.measure(column.title, font: titleFont, width: inner.width).height
      let chipWidth = min(inner.width, TextKit.lineWidth(column.title, font: titleFont))
      pen.highlight(
        CGRect(
          x: frame.midX - chipWidth / 2 - 10, y: cy + 4, width: chipWidth + 20,
          height: min(titleHeight, 44)),
        color: palette.highlight)
      text.draw(
        column.title, font: titleFont, color: palette.ink,
        in: CGRect(x: inner.minX, y: cy, width: inner.width, height: titleHeight + 8),
        align: .center)
      cy += titleHeight + 14

      if let tagline = column.tagline {
        let taglineFont = FontBook.font(.script, size: 33 * s)
        let h = TextKit.measure(tagline, font: taglineFont, width: inner.width).height
        text.draw(
          tagline, font: taglineFont, color: palette.accent,
          in: CGRect(x: inner.minX, y: cy, width: inner.width, height: h + 8), align: .center)
        cy += h + 16
      }
      if let summary = column.summary {
        let summaryFont = FontBook.font(.body, size: 27 * s)
        let h = TextKit.measure(summary, font: summaryFont, width: inner.width).height
        if cy + h < frame.maxY - 60 {
          text.draw(
            summary, font: summaryFont, color: palette.ink.copy(alpha: 0.82) ?? palette.ink,
            in: CGRect(x: inner.minX, y: cy, width: inner.width, height: h + 8))
          cy += h + 18
        }
      }
      if !column.steps.isEmpty {
        let processLabel = "The Process:"
        let labelFont = FontBook.font(.script, size: 30 * s)
        text.draw(
          processLabel, font: labelFont, color: palette.ink,
          in: CGRect(x: inner.minX, y: cy, width: inner.width, height: 44))
        cy += 46
        let stepFont = FontBook.font(.body, size: 26 * s)
        for (n, step) in column.steps.enumerated() {
          let iconBox: CGFloat = 42
          let textX = inner.minX + iconBox + 44
          let width = inner.maxX - textX
          let h = max(iconBox, TextKit.measure(step, font: stepFont, width: width).height)
          guard cy + h <= frame.maxY - 14 else { break }
          let numberFont = FontBook.font(.script, size: 30 * s)
          text.draw(
            "\(n + 1).", font: numberFont, color: palette.ink,
            in: CGRect(x: inner.minX, y: cy + 2, width: 36, height: 40))
          let hint = n < column.iconHints.count ? column.iconHints[n] : "ring"
          pen.path(
            IconLibrary.resolvedGlyph(hint: hint, fallbackIndex: n),
            in: CGRect(x: inner.minX + 34, y: cy, width: iconBox, height: iconBox),
            unitSpace: true, color: palette.gold, width: 3.4, wobble: 1.1)
          text.draw(
            step, font: stepFont, color: palette.ink,
            in: CGRect(x: textX, y: cy, width: width, height: h + 8))
          cy += h + 16
        }
      }
      // connector arrow between columns
      if i < count - 1 {
        pen.squiggleArrow(
          from: CGPoint(x: frame.maxX - 6, y: frame.minY - 16),
          to: CGPoint(x: frame.maxX + gap + 6, y: frame.minY - 16),
          color: palette.accent, width: 3.4)
      }
    }
  }

  /// Draw traced video-frame strokes fitted into a rect, hand-inked.
  func drawTracedFigure(
    _ sketch: [SketchStroke], in rect: CGRect, pen: inout RoughPen,
    palette: Palette, framed: Bool
  ) {
    let allPoints = sketch.flatMap(\.points)
    guard !allPoints.isEmpty else { return }
    let xs = allPoints.map(\.x)
    let ys = allPoints.map(\.y)
    let minX = xs.min()!
    let maxX = xs.max()!
    let minY = ys.min()!
    let maxY = ys.max()!
    let w = max(0.02, maxX - minX)
    let h = max(0.02, maxY - minY)
    let scale = min(rect.width / w, rect.height / h)
    let drawnW = w * scale
    let drawnH = h * scale
    let ox = rect.midX - drawnW / 2
    let oy = rect.midY - drawnH / 2

    if framed {
      let frame = CGRect(x: ox - 26, y: oy - 26, width: drawnW + 52, height: drawnH + 52)
      pen.context.saveGState()
      pen.context.setFillColor(palette.ink.copy(alpha: 0.045) ?? palette.ink)
      pen.context.fill(frame.offsetBy(dx: 7, dy: 9))
      pen.context.setFillColor(palette.paper)
      pen.context.fill(frame)
      pen.context.restoreGState()
      pen.rect(frame, color: palette.ink, width: 4, cornerRadius: 12)
    }
    for (i, stroke) in sketch.enumerated() {
      let mapped = stroke.points.map {
        CGPoint(x: ox + ($0.x - minX) * scale, y: oy + ($0.y - minY) * scale)
      }
      // the two biggest shapes get the accent colour, the rest stay ink
      let color = i < 2 ? palette.accent : palette.ink.copy(alpha: 0.85) ?? palette.ink
      pen.strokePolyline(
        mapped, color: color, width: i < 2 ? 3.6 : 2.6, wobble: 1.1, passes: 1,
        closed: hypot(mapped.first!.x - mapped.last!.x, mapped.first!.y - mapped.last!.y) < 6)
    }
  }

  /// Natural height of a section at a given width (for pair-page packing).
  func measureSection(_ section: NoteSection, width: CGFloat, style: RenderStyle) -> CGFloat {
    let s = fontScale(style)
    let headingFont = FontBook.font(.heading, size: 58 * s)
    func headingBlock(_ h: String) -> CGFloat {
      TextKit.measure(h, font: headingFont, width: width).height + 54
    }
    func bulletRows(_ points: [String], font: CTFont, indent: CGFloat = 52) -> CGFloat {
      points.reduce(0) { $0 + TextKit.measure($1, font: font, width: width - indent).height + 22 }
    }
    switch section {
    case .concept(let h, let body, let points, _, let quote, _, let sketch):
      var total = headingBlock(h)
      if sketch != nil { total += 470 }
      if let body, !body.isEmpty {
        total +=
          TextKit.measure(body, font: FontBook.font(.body, size: 38 * s), width: width).height + 34
      }
      total += bulletRows(points, font: FontBook.font(.body, size: 37 * s))
      if quote != nil { total += 310 }
      return total
    case .methods(let h, let columns, _):
      let columnWidth = (width - 60) / CGFloat(max(1, columns.count))
      let tallest =
        columns.map { measureColumn($0, width: columnWidth - 44, scale: s) }.max() ?? 300
      return headingBlock(h) + tallest + 56
    case .process(let h, let steps, _, _, let sketch):
      let stepFont = FontBook.font(.body, size: 36 * s)
      let rows = steps.reduce(0.0) {
        $0 + max(66, TextKit.measure($1, font: stepFont, width: width - 180).height) + 30
      }
      return headingBlock(h) + rows + 6 + (sketch == nil ? 0 : 330)
    case .comparison(let h, _, let lp, _, let rp, _, let sketch):
      return headingBlock(h) + 140 + CGFloat(max(lp.count, rp.count)) * 70
        + (sketch == nil ? 0 : 280)
    case .quote(let quoteText, let attribution, _):
      let quoteFont = FontBook.font(.script, size: 40 * s)
      let textHeight = TextKit.measure(
        "“" + quoteText + "”", font: quoteFont, width: width - 84, lineSpacing: 8
      ).height
      return textHeight + 84 + (attribution != nil ? 56 : 0) + 24
    case .definition(let term, let meaning, _):
      let termHeight = TextKit.measure(
        term, font: FontBook.font(.heading, size: 52 * s), width: width
      ).height
      let meaningHeight = TextKit.measure(
        meaning, font: FontBook.font(.body, size: 38 * s), width: width - 84
      ).height
      return termHeight + 26 + meaningHeight + 20
    case .summary(let h, let points, _):
      return headingBlock(h) + 8
        + bulletRows(points, font: FontBook.font(.body, size: 37 * s), indent: 76) + CGFloat(
          points.count) * 8
    }
  }

  /// Mirror of drawMethods' vertical layout, for content-hugging panels.
  func measureColumn(_ column: MethodColumn, width: CGFloat, scale s: CGFloat) -> CGFloat {
    var h: CGFloat = 26
    h +=
      TextKit.measure(column.title, font: FontBook.font(.heading, size: 34 * s), width: width)
      .height + 14
    if let tagline = column.tagline {
      h +=
        TextKit.measure(tagline, font: FontBook.font(.script, size: 33 * s), width: width).height
        + 16
    }
    if let summary = column.summary {
      h +=
        TextKit.measure(summary, font: FontBook.font(.body, size: 27 * s), width: width).height + 18
    }
    if !column.steps.isEmpty {
      h += 46
      let stepFont = FontBook.font(.body, size: 26 * s)
      for step in column.steps {
        h += max(42, TextKit.measure(step, font: stepFont, width: width - 86).height) + 16
      }
    }
    return h
  }

  // MARK: - process

  func drawProcess(
    heading: String, steps: [String], icons: [String], sketch: [SketchStroke]?,
    in rect: CGRect, pen: inout RoughPen,
    text: TextKit, palette: Palette, style: RenderStyle, solo: Bool
  ) {
    var y = drawHeading(heading, in: rect, pen: &pen, text: text, palette: palette, style: style)
    y += 6
    if solo, let sketch, !sketch.isEmpty {
      let figureRect = CGRect(
        x: rect.minX + rect.width * 0.18, y: y + 8,
        width: rect.width * 0.64, height: min(280, rect.height * 0.2))
      drawTracedFigure(sketch, in: figureRect, pen: &pen, palette: palette, framed: true)
      y = figureRect.maxY + 34
    }
    let s = fontScale(style)
    let stepFont = FontBook.font(.body, size: 36 * s)
    let available = rect.maxY - y
    // comfortable pitch, not page-filling emptiness
    let per = min(available / CGFloat(max(1, steps.count)), 236)
    for (n, step) in steps.enumerated() {
      let circle: CGFloat = 66
      let iconBox: CGFloat = 34
      let textX = rect.minX + circle + iconBox + 52
      let width = rect.maxX - textX
      let textHeight = TextKit.measure(step, font: stepFont, width: width).height
      let rowHeight = max(circle, textHeight)
      guard y + rowHeight <= rect.maxY + 4 else { break }
      let cy = y + rowHeight / 2

      pen.ellipse(
        in: CGRect(x: rect.minX, y: cy - circle / 2, width: circle, height: circle),
        color: palette.accent, width: 4.4)
      let numberFont = FontBook.font(.heading, size: 34 * s)
      text.draw(
        "\(n + 1)", font: numberFont, color: palette.ink,
        in: CGRect(x: rect.minX, y: cy - 24, width: circle, height: 52), align: .center)
      let markerX = rect.minX + circle + 22
      pen.strokePolyline(
        [
          CGPoint(x: markerX + iconBox / 2, y: cy - iconBox / 2),
          CGPoint(x: markerX + iconBox, y: cy),
          CGPoint(x: markerX + iconBox / 2, y: cy + iconBox / 2),
          CGPoint(x: markerX, y: cy),
        ],
        color: palette.gold, width: 3.5, wobble: 0.8, closed: true)
      text.draw(
        step, font: stepFont, color: palette.ink,
        in: CGRect(x: textX, y: cy - textHeight / 2, width: width, height: textHeight + 8))

      if n < steps.count - 1, solo, per - rowHeight > 40 {
        pen.fatArrow(
          from: CGPoint(x: rect.minX + circle / 2, y: y + rowHeight + 10),
          to: CGPoint(x: rect.minX + circle / 2, y: y + per - 12),
          color: palette.accent.copy(alpha: 0.75) ?? palette.accent, thickness: 15)
      }
      y += max(rowHeight + 30, solo ? per : rowHeight + 30)
    }
  }

  // MARK: - comparison

  func drawComparison(
    heading: String, leftTitle: String, leftPoints: [String], rightTitle: String,
    rightPoints: [String], sketch: [SketchStroke]?, in rect: CGRect,
    pen: inout RoughPen, text: TextKit,
    palette: Palette, style: RenderStyle
  ) {
    var y = drawHeading(
      heading, in: rect, pen: &pen, text: text, palette: palette, style: style, centered: true)
    y += 10
    if let sketch, !sketch.isEmpty {
      let figureRect = CGRect(
        x: rect.minX + rect.width * 0.25, y: y,
        width: rect.width * 0.5, height: min(230, rect.height * 0.18))
      drawTracedFigure(sketch, in: figureRect, pen: &pen, palette: palette, framed: true)
      y = figureRect.maxY + 30
    }
    let gap: CGFloat = 56
    let columnWidth = (rect.width - gap) / 2
    let height = rect.maxY - y
    let s = fontScale(style)
    let sides: [(CGRect, String, [String])] = [
      (CGRect(x: rect.minX, y: y, width: columnWidth, height: height), leftTitle, leftPoints),
      (
        CGRect(x: rect.minX + columnWidth + gap, y: y, width: columnWidth, height: height),
        rightTitle, rightPoints
      ),
    ]
    for (frame, title, points) in sides {
      pen.rect(frame, color: palette.ink, width: 4, cornerRadius: 18)
      let inner = frame.insetBy(dx: 22, dy: 0)
      let titleFont = FontBook.font(.heading, size: 38 * s)
      let th = TextKit.measure(title, font: titleFont, width: inner.width).height
      let chipW = min(inner.width, TextKit.lineWidth(title, font: titleFont))
      pen.highlight(
        CGRect(
          x: frame.midX - chipW / 2 - 10, y: frame.minY + 28, width: chipW + 20, height: min(th, 46)
        ),
        color: palette.highlight)
      text.draw(
        title, font: titleFont, color: palette.ink,
        in: CGRect(x: inner.minX, y: frame.minY + 24, width: inner.width, height: th + 8),
        align: .center)
      _ = drawBullets(
        points, from: frame.minY + th + 52,
        in: CGRect(x: inner.minX, y: frame.minY, width: inner.width, height: frame.height - 40),
        pen: &pen, text: text, palette: palette, style: style,
        font: FontBook.font(.body, size: 30 * s))
    }
    // VS badge
    let badge: CGFloat = 92
    let badgeRect = CGRect(
      x: rect.midX - badge / 2, y: y + height * 0.42 - badge / 2, width: badge, height: badge)
    pen.context.saveGState()
    pen.context.setFillColor(palette.paper)
    pen.context.fillEllipse(in: badgeRect.insetBy(dx: -6, dy: -6))
    pen.context.restoreGState()
    pen.ellipse(in: badgeRect, color: palette.gold, width: 5)
    text.draw(
      "VS", font: FontBook.font(.heading, size: 38 * s), color: palette.ink,
      in: CGRect(x: badgeRect.minX, y: badgeRect.minY + 22, width: badge, height: 52),
      align: .center)
  }

  // MARK: - quote

  func drawQuoteCard(
    _ quote: String, attribution: String?, in rect: CGRect, pen: inout RoughPen,
    text: TextKit, palette: Palette, style: RenderStyle, big: Bool
  ) {
    let context = pen.context
    let tilt: CGFloat = pen.rng.range(-0.030 ... -0.012)
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: tilt)
    context.translateBy(x: -rect.midX, y: -rect.midY)

    let s = fontScale(style)
    let quoteFont = FontBook.font(.script, size: (big ? 58 : 40) * s)
    let inset: CGFloat = big ? 70 : 42
    let textWidth = rect.width - inset * 2
    let quoted = "“" + quote + "”"
    let textHeight = TextKit.measure(quoted, font: quoteFont, width: textWidth, lineSpacing: 8)
      .height
    let cardHeight = min(rect.height, textHeight + inset * 2 + (attribution != nil ? 56 : 0))
    let card = CGRect(
      x: rect.minX, y: rect.midY - cardHeight / 2, width: rect.width, height: cardHeight)

    context.setFillColor(palette.ink.copy(alpha: 0.055) ?? palette.ink)
    context.fill(card.offsetBy(dx: 9, dy: 11))
    context.setFillColor(palette.paper)
    context.fill(card)
    pen.rect(card, color: palette.ink, width: 4.4, cornerRadius: 10)

    // oversized quote mark
    text.draw(
      "“", font: FontBook.font(.heading, size: (big ? 160 : 110) * s),
      color: palette.gold,
      in: CGRect(x: card.minX + 22, y: card.minY - (big ? 30 : 20), width: 160, height: 180))

    text.draw(
      quoted, font: quoteFont, color: palette.ink,
      in: CGRect(
        x: card.minX + inset, y: card.midY - textHeight / 2 - (attribution != nil ? 20 : 0),
        width: textWidth, height: textHeight + 12),
      align: .center, lineSpacing: 8)
    if let attribution {
      text.draw(
        "— " + attribution, font: FontBook.font(.body, size: 30 * s),
        color: palette.ink.copy(alpha: 0.7) ?? palette.ink,
        in: CGRect(x: card.minX + inset, y: card.maxY - 64, width: textWidth, height: 44),
        align: .right)
    }
    context.restoreGState()
  }

  // MARK: - definition

  func drawDefinition(
    term: String, meaning: String, in rect: CGRect, pen: inout RoughPen,
    text: TextKit, palette: Palette, style: RenderStyle
  ) {
    let s = fontScale(style)
    let termFont = FontBook.font(.heading, size: 52 * s)
    let termHeight = TextKit.measure(term, font: termFont, width: rect.width).height
    let chipWidth = min(rect.width, TextKit.lineWidth(term, font: termFont))
    pen.highlight(
      CGRect(
        x: rect.minX - 8, y: rect.minY + termHeight - min(termHeight, 50) + 10,
        width: chipWidth + 20, height: min(termHeight, 48)), color: palette.highlight)
    text.draw(
      term, font: termFont, color: palette.ink,
      in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: termHeight + 10))
    var y = rect.minY + termHeight + 26
    // "=" doodle
    pen.line(
      from: CGPoint(x: rect.minX + 6, y: y + 12), to: CGPoint(x: rect.minX + 52, y: y + 10),
      color: palette.accent, width: 5)
    pen.line(
      from: CGPoint(x: rect.minX + 6, y: y + 30), to: CGPoint(x: rect.minX + 52, y: y + 28),
      color: palette.accent, width: 5)
    let meaningFont = FontBook.font(.body, size: 38 * s)
    let mh = TextKit.measure(meaning, font: meaningFont, width: rect.width - 84).height
    text.draw(
      meaning, font: meaningFont, color: palette.ink,
      in: CGRect(x: rect.minX + 84, y: y, width: rect.width - 84, height: mh + 8))
    y += mh
  }

  // MARK: - summary

  func drawSummary(
    heading: String, points: [String], in rect: CGRect, pen: inout RoughPen,
    text: TextKit, palette: Palette, style: RenderStyle
  ) {
    var y = drawHeading(heading, in: rect, pen: &pen, text: text, palette: palette, style: style)
    y += 8
    let s = fontScale(style)
    let font = FontBook.font(.body, size: 37 * s)
    for point in points {
      let box: CGFloat = 46
      let textX = rect.minX + box + 30
      let width = rect.maxX - textX
      let height = max(box, TextKit.measure(point, font: font, width: width).height)
      guard y + height <= rect.maxY else { break }
      pen.rect(
        CGRect(x: rect.minX, y: y + 2, width: box, height: box), color: palette.ink, width: 4,
        cornerRadius: 8)
      pen.path(
        IconLibrary.glyphs["check"]!,
        in: CGRect(x: rect.minX + 4, y: y + 4, width: box, height: box),
        unitSpace: true, color: palette.gold, width: 5.4, wobble: 1)
      text.draw(
        point, font: font, color: palette.ink,
        in: CGRect(x: textX, y: y + (box - min(height, 44)) / 2, width: width, height: height + 8))
      y += height + 26
    }
  }
}
