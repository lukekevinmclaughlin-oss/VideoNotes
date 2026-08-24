import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a `NoteDocument` as pure, well-organised text notes — no sketches,
/// frames, boxes, diagrams, icons, or decorative marks. Just a clean
/// typographic hierarchy (title, headings, body, bullets, numbered steps,
/// quotes, definitions) that flows across as many pages as the content needs.
///
/// Same public surface as `PageRenderer` so it is a drop-in for the app and
/// CLI: `renderImages` for on-screen pages and PNG export, `renderPDF` for a
/// selectable-text PDF.
public struct PlainNotesRenderer {

  public init() {}

  // MARK: - entry points

  public func renderImages(document: NoteDocument, style: RenderStyle, scale: CGFloat = 2)
    -> [CGImage]
  {
    let pages = paginate(document, style: style)
    var images: [CGImage] = []
    for index in pages.indices {
      guard !Task.isCancelled else { break }
      if let image = renderImage(
        page: pages[index], index: index, total: pages.count, style: style, scale: scale)
      {
        images.append(image)
      }
    }
    return images
  }

  public func renderPDF(document: NoteDocument, style: RenderStyle) -> Data {
    let pages = paginate(document, style: style)
    let data = NSMutableData()
    let outputSize = style.pdfPageFormat.pageSize
    var mediaBox = CGRect(origin: .zero, size: outputSize)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, pdfMetadata(document))
    else { return Data() }
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
      draw(page: page, index: index, total: pages.count, style: style, in: context)
      context.restoreGState()
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }

  public static func pngData(_ image: CGImage) -> Data { PageRenderer.pngData(image) }

  private func renderImage(
    page: LaidOutPage, index: Int, total: Int, style: RenderStyle, scale: CGFloat
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

  private func flipToTopLeft(_ context: CGContext, height: CGFloat) {
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
  }

  // MARK: - typography

  private let margin: CGFloat = 92
  private var contentWidth: CGFloat { PageMetrics.size.width - margin * 2 }
  private var contentBottom: CGFloat { PageMetrics.size.height - margin - 44 }  // footer reserve
  private let bulletIndent: CGFloat = 46
  private let numberIndent: CGFloat = 58

  private func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
    let base =
      CTFontCreateUIFontForLanguage(.system, size, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    var traits: CTFontSymbolicTraits = []
    if bold { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    guard !traits.isEmpty else { return base }
    return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
  }

  // MARK: - block model

  private enum Kind {
    case title, subtitle, heading, source, subheading, body, bullet, numbered, quote, attribution
  }

  private struct Block {
    var kind: Kind
    var text: String
    var number: Int = 0
  }

  private struct Placed {
    var block: Block
    var y: CGFloat
    var height: CGFloat
  }

  private struct LaidOutPage {
    var placed: [Placed]
  }

  private func ctFont(for kind: Kind) -> CTFont {
    switch kind {
    case .title: return font(62, bold: true)
    case .subtitle: return font(32)
    case .heading: return font(42, bold: true)
    case .source: return font(21)
    case .subheading: return font(31, bold: true)
    case .body, .bullet, .numbered: return font(30)
    case .quote: return font(31, italic: true)
    case .attribution: return font(26)
    }
  }

  private func frame(for kind: Kind) -> (x: CGFloat, width: CGFloat) {
    switch kind {
    case .bullet: return (margin + bulletIndent, contentWidth - bulletIndent)
    case .numbered: return (margin + numberIndent, contentWidth - numberIndent)
    case .quote, .attribution: return (margin + 30, contentWidth - 30)
    default: return (margin, contentWidth)
    }
  }

  private func spacingBefore(_ kind: Kind) -> CGFloat {
    switch kind {
    case .heading: return 46
    case .subheading: return 26
    case .quote: return 12
    default: return 0
    }
  }

  private func spacingAfter(_ kind: Kind) -> CGFloat {
    switch kind {
    case .title: return 8
    case .subtitle: return 34
    case .heading: return 4
    case .source: return 16
    case .subheading: return 10
    case .body: return 14
    case .bullet, .numbered: return 9
    case .quote: return 6
    case .attribution: return 14
    }
  }

  private func lineSpacing(_ kind: Kind) -> CGFloat {
    switch kind {
    case .body, .bullet, .numbered, .quote: return 8
    default: return 4
    }
  }

  private func measure(_ block: Block) -> CGFloat {
    let f = ctFont(for: block.kind)
    let w = frame(for: block.kind).width
    return ceil(TextKit.measure(block.text, font: f, width: w, lineSpacing: lineSpacing(block.kind)).height)
  }

  // MARK: - document → blocks

  private func blocks(for document: NoteDocument) -> [Block] {
    var out: [Block] = []
    let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
    out.append(Block(kind: .title, text: title.isEmpty ? "Notes" : title))
    if let subtitle = document.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !subtitle.isEmpty
    {
      out.append(Block(kind: .subtitle, text: subtitle))
    }
    for section in document.sections {
      out.append(contentsOf: blocks(for: section))
    }
    return out
  }

  private func sourceText(_ time: Double?) -> String? {
    time.map { "Source · \(TimeFormat.mmss($0))" }
  }

  private func blocks(for section: NoteSection) -> [Block] {
    var out: [Block] = []
    func heading(_ text: String, _ time: Double?) {
      out.append(Block(kind: .heading, text: text))
      if let s = sourceText(time) { out.append(Block(kind: .source, text: s)) }
    }
    func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    switch section {
    case .concept(let h, let body, let points, _, let quote, let time, _):
      heading(clean(h), time)
      if let body = body.map(clean), !body.isEmpty { out.append(Block(kind: .body, text: body)) }
      for p in points where !clean(p).isEmpty { out.append(Block(kind: .bullet, text: clean(p))) }
      if let q = quote.map(clean), !q.isEmpty { out.append(Block(kind: .quote, text: "“\(q)”")) }

    case .methods(let h, let columns, let time):
      heading(clean(h), time)
      for col in columns {
        let title = clean(col.title)
        let tagline = col.tagline.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        out.append(
          Block(kind: .subheading, text: tagline.map { "\(title) — \($0)" } ?? title))
        if let summary = col.summary.map(clean), !summary.isEmpty {
          out.append(Block(kind: .body, text: summary))
        }
        for (i, step) in col.steps.enumerated() where !clean(step).isEmpty {
          out.append(Block(kind: .numbered, text: clean(step), number: i + 1))
        }
      }

    case .process(let h, let steps, _, let time, _):
      heading(clean(h), time)
      for (i, step) in steps.enumerated() where !clean(step).isEmpty {
        out.append(Block(kind: .numbered, text: clean(step), number: i + 1))
      }

    case .comparison(let h, let lt, let lp, let rt, let rp, let time, _):
      heading(clean(h), time)
      out.append(Block(kind: .subheading, text: clean(lt)))
      for p in lp where !clean(p).isEmpty { out.append(Block(kind: .bullet, text: clean(p))) }
      out.append(Block(kind: .subheading, text: clean(rt)))
      for p in rp where !clean(p).isEmpty { out.append(Block(kind: .bullet, text: clean(p))) }

    case .quote(let text, let attribution, let time):
      let t = clean(text)
      out.append(Block(kind: .quote, text: "“\(t)”"))
      if let a = attribution.map(clean), !a.isEmpty {
        out.append(Block(kind: .attribution, text: "— \(a)"))
      }
      if let s = sourceText(time) { out.append(Block(kind: .source, text: s)) }

    case .definition(let term, let meaning, let time):
      heading(clean(term), time)
      out.append(Block(kind: .body, text: clean(meaning)))

    case .summary(let h, let points, let time):
      heading(clean(h), time)
      for p in points where !clean(p).isEmpty { out.append(Block(kind: .bullet, text: clean(p))) }
    }
    return out
  }

  // MARK: - pagination

  private func paginate(_ document: NoteDocument, style: RenderStyle) -> [LaidOutPage] {
    let raw = blocks(for: document)
    var pages: [LaidOutPage] = []
    var current: [Placed] = []
    var y = margin

    func flushPage() {
      pages.append(LaidOutPage(placed: current))
      current = []
      y = margin
    }

    var queue = raw
    var index = 0
    while index < queue.count {
      let block = queue[index]
      let kind = block.kind
      let before = current.isEmpty ? 0 : spacingBefore(kind)
      let f = ctFont(for: kind)
      let width = frame(for: kind).width
      let height = ceil(
        TextKit.measure(block.text, font: f, width: width, lineSpacing: lineSpacing(kind)).height)

      // Keep a heading/subheading with the start of its content: if the heading
      // plus a couple of lines won't fit, break to a new page first.
      let keepWithNext = (kind == .heading || kind == .subheading)
      let needed = keepWithNext ? height + 80 : height

      if !current.isEmpty && y + before + needed > contentBottom {
        // Does the whole block fit on a fresh page? If so, just break.
        if height <= contentBottom - margin {
          flushPage()
        } else {
          // Block taller than an entire page: place what fits, continue the rest.
          let avail = contentBottom - (y + before)
          if avail < ctFontLineHeight(f) * 2 { flushPage() }
          let (head, tail) = splitToFit(
            block.text, font: f, width: width, maxHeight: contentBottom - y, kind: kind)
          if !head.isEmpty {
            let hh = ceil(
              TextKit.measure(head, font: f, width: width, lineSpacing: lineSpacing(kind)).height)
            current.append(Placed(block: Block(kind: kind, text: head, number: block.number), y: y, height: hh))
          }
          queue[index] = Block(kind: kind, text: tail, number: 0)
          flushPage()
          if tail.isEmpty { index += 1 }
          continue
        }
      }

      if !current.isEmpty { y += before }
      current.append(Placed(block: block, y: y, height: height))
      y += height + spacingAfter(kind)
      index += 1
    }
    if !current.isEmpty || pages.isEmpty { flushPage() }
    return pages
  }

  private func ctFontLineHeight(_ f: CTFont) -> CGFloat {
    ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
  }

  /// Largest word-prefix of `text` whose wrapped height fits `maxHeight`.
  private func splitToFit(_ text: String, font f: CTFont, width: CGFloat, maxHeight: CGFloat, kind: Kind)
    -> (head: String, tail: String)
  {
    let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard words.count > 1 else { return (text, "") }
    var lo = 1
    var hi = words.count
    var best = 0
    while lo <= hi {
      let mid = (lo + hi) / 2
      let candidate = words.prefix(mid).joined(separator: " ")
      let h = TextKit.measure(candidate, font: f, width: width, lineSpacing: lineSpacing(kind)).height
      if h <= maxHeight {
        best = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    guard best > 0, best < words.count else {
      return best >= words.count ? (text, "") : (words.first ?? text, words.dropFirst().joined(separator: " "))
    }
    return (
      words.prefix(best).joined(separator: " "),
      words.dropFirst(best).joined(separator: " ")
    )
  }

  // MARK: - drawing

  private func draw(
    page: LaidOutPage, index: Int, total: Int, style: RenderStyle, in context: CGContext
  ) {
    let palette = style.palette
    let size = PageMetrics.size
    let ink = palette.ink
    let muted = palette.ink.copy(alpha: 0.55) ?? palette.ink
    let accent = palette.accent

    // clean paper, no grain
    context.setFillColor(palette.paper)
    context.fill(CGRect(origin: .zero, size: size))

    let text = TextKit(context: context)
    for placed in page.placed {
      let block = placed.block
      let kind = block.kind
      let f = ctFont(for: kind)
      let (x, width) = frame(for: kind)
      let color: CGColor
      switch kind {
      case .subtitle, .attribution: color = muted
      case .source: color = accent.copy(alpha: 0.85) ?? accent
      case .quote: color = ink.copy(alpha: 0.82) ?? ink
      default: color = ink
      }

      // list markers
      if kind == .bullet {
        text.draw(
          "•", font: ctFont(for: .body), color: accent,
          in: CGRect(x: margin + 14, y: placed.y, width: 26, height: placed.height + 8))
      } else if kind == .numbered {
        text.draw(
          "\(block.number).", font: ctFont(for: .body), color: accent,
          in: CGRect(x: margin, y: placed.y, width: numberIndent - 8, height: placed.height + 8))
      }

      text.draw(
        block.text, font: f, color: color,
        in: CGRect(x: x, y: placed.y, width: width, height: placed.height + 8),
        lineSpacing: lineSpacing(kind))
    }

    // footer: product mark + page count. No source clutter, no rules.
    let footerFont = font(22)
    text.draw(
      "VideoNotes", font: footerFont, color: muted,
      in: CGRect(x: margin, y: size.height - 52, width: 300, height: 34))
    if total > 1 {
      text.draw(
        "\(index + 1) / \(total)", font: footerFont, color: muted,
        in: CGRect(x: size.width - margin - 160, y: size.height - 52, width: 160, height: 34),
        align: .right)
    }
  }

  private func pdfMetadata(_ document: NoteDocument) -> CFDictionary {
    let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return
      [
        kCGPDFContextTitle as String: title.isEmpty ? "Video Notes" : title,
        kCGPDFContextCreator as String: "VideoNotes",
      ] as CFDictionary
  }
}
