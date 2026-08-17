import Foundation

enum ContentLanguage: String, Sendable {
  case english = "en"
  case german = "de"
  case undetermined = "und"

  var summaryHeading: String {
    switch self {
    case .german: return "Wichtigste Erkenntnisse"
    case .english, .undetermined: return "Key Takeaways"
    }
  }

  func onScreenHeading(at time: Double) -> String {
    switch self {
    case .german: return "Auf dem Bildschirm um \(TimeFormat.mmss(time))"
    case .english, .undetermined: return "On screen at \(TimeFormat.mmss(time))"
    }
  }
}

/// Stable, offline language classification for the languages whose note
/// grammar is explicitly supported. Ambiguous or unsupported input stays
/// `und` instead of being forced through an English grammar.
enum ContentLanguageDetector {
  static func detect(_ content: ExtractedContent) -> ContentLanguage {
    let transcript = content.transcript.map(\.text).joined(separator: " ")
    let visualText = content.visuals.flatMap(\.lines).joined(separator: " ")
    // Spoken language is authoritative when available. Mixed-language slide
    // chrome must not override the language actually used by the speaker.
    let text = transcript.isEmpty ? visualText + " " + content.sourceName : transcript
    return detect(text)
  }

  static func detect(_ text: String) -> ContentLanguage {
    let lower = text.lowercased()
    let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard !words.isEmpty else { return .undetermined }

    let englishMarkers: Set<String> = [
      "a", "about", "also", "an", "and", "are", "as", "at", "because", "been", "but",
      "by", "can", "could", "data", "does", "examples", "for", "from", "had", "has",
      "have", "hello", "how", "if", "important", "into", "is", "it", "learning", "model",
      "models", "network", "networks", "not", "of", "on", "or", "our", "result", "should",
      "steps", "that", "the", "their", "then", "these", "they", "this", "those", "to",
      "was", "we", "were", "what", "when", "where", "which", "who", "why", "will", "with",
      "world", "would", "you", "your",
    ]
    let germanMarkers: Set<String> = [
      "aber", "als", "also", "auch", "auf", "aus", "bei", "beispiele", "bedeutet", "bezeichnet",
      "danach", "dann", "das", "daten", "dass", "dem", "den", "denn", "der", "des", "die",
      "dieser", "diese", "dieses", "du", "ein", "eine", "einem", "einen", "einer", "eines",
      "entscheidend", "er", "ergebnis", "erkenntnisse", "für", "gegen", "gründe", "hat", "hatte",
      "haben", "ich", "ihr", "im", "ist", "kein", "keine", "lernen", "man", "methoden", "mit",
      "modell", "modelle", "nach", "nicht", "oder", "phasen", "prinzipien", "regeln", "schließlich",
      "schritte", "sein", "sich", "sie", "sind", "stufen", "tipps", "über", "und", "von", "war",
      "waren", "wege", "weil", "wenn", "werden", "wichtig", "wird", "wir", "wurde", "wurden",
      "zunächst", "zuerst", "zum", "zur", "zusammenfassung",
    ]

    var englishScore = words.reduce(0) { $0 + (englishMarkers.contains($1) ? 2 : 0) }
    var germanScore = words.reduce(0) { $0 + (germanMarkers.contains($1) ? 2 : 0) }
    germanScore += lower.filter { "äöüß".contains($0) }.count * 3

    // Productive suffixes provide a weak signal for short educational
    // headings while common function words remain the primary evidence.
    englishScore +=
      words.filter {
        $0.count >= 6 && ($0.hasSuffix("ing") || $0.hasSuffix("tion"))
      }.count
    germanScore +=
      words.filter {
        $0.count >= 6
          && ($0.hasSuffix("ung") || $0.hasSuffix("heit") || $0.hasSuffix("keit")
            || $0.hasSuffix("ieren"))
      }.count

    let threshold = words.count <= 3 ? 3 : 4
    if germanScore >= threshold, germanScore >= englishScore + 2 { return .german }
    if englishScore >= threshold, englishScore >= germanScore + 2 { return .english }
    return .undetermined
  }
}

/// Deterministic on-device structurer (spec §C1): transcript + OCR → NoteDocument.
/// Same input always produces the same document.
public enum HeuristicStructurer {

  public static func structure(_ content: ExtractedContent) throws -> NoteDocument {
    let hasTranscript = !content.transcript.isEmpty
    let hasVisuals = !content.visuals.isEmpty
    guard hasTranscript || hasVisuals else { throw ExtractError.noContent }

    let language = ContentLanguageDetector.detect(content)
    let spans = disambiguatingRepeatedVisualHeadings(
      in: segment(content, language: language), language: language)
    guard !spans.isEmpty else { throw ExtractError.noContent }

    var sections = spans.map { makeSection(from: $0, language: language) }

    // One pull-quote per document: the most quotable spoken sentence not
    // already used, attached to its section or standing alone.
    if hasTranscript,
      let quote = pullQuote(content.transcript, sections: sections, language: language)
    {
      sections = attach(quote: quote, to: sections)
    }

    // Closing summary from the top points across the document.
    if sections.count >= 2,
      !sections.contains(where: {
        if case .summary = $0 { return true }
        return false
      })
    {
      let points = topDocumentPoints(spans: spans, limit: 4, language: language)
      if points.count >= 2 {
        sections.append(.summary(heading: language.summaryHeading, points: points, sourceTime: nil))
      }
    }

    let (title, subtitle) = titleAndSubtitle(content, spans: spans, language: language)
    return SNMValidation.sanitize(
      NoteDocument(
        title: title, subtitle: subtitle,
        language: language.rawValue, sections: sections,
        heroSketch: heroSketch(content)))
  }

  // MARK: - Segmentation

  /// A topical span of the source: its transcript sentences + its slide.
  struct Span {
    var start: Double
    var end: Double
    var sentences: [TranscriptSegment]
    var slide: VisualMoment?
    var headingOverride: String? = nil
  }

  static func segment(_ content: ExtractedContent) -> [Span] {
    segment(content, language: .english)
  }

  static func segment(_ content: ExtractedContent, language: ContentLanguage) -> [Span] {
    // Boundaries combine slide changes and spoken-topic pauses. Treating
    // them as mutually exclusive can merge distinct spoken topics simply
    // because a video also contains slides.
    var boundaries: [Double] = [0]
    boundaries.append(
      contentsOf: meaningfulVisualBoundaryTimes(content.visuals, language: language))
    if content.transcript.count > 1 {
      var previousEnd = content.transcript[0].end
      for seg in content.transcript.dropFirst() {
        if seg.start - previousEnd > 2.5 { boundaries.append(seg.start) }
        previousEnd = seg.end
      }
      if boundaries.count == 1 {  // no pauses: split every ~90 s
        var t = 90.0
        while t < content.duration {
          boundaries.append(t)
          t += 90
        }
      }
      if boundaries.count == 1, content.transcript.count >= 4 {
        // Short, continuous talks still need a useful study structure.
        // Aim for roughly three evidence-backed topics without turning
        // every sentence into a separate note page.
        let groupSize = max(2, Int(ceil(Double(content.transcript.count) / 3)))
        for (index, seg) in content.transcript.enumerated()
        where index > 0 && index % groupSize == 0 {
          boundaries.append(seg.start)
        }
      }
    }
    boundaries = Array(Set(boundaries)).sorted()

    var spans: [Span] = boundaries.enumerated().map { index, start in
      let end = index + 1 < boundaries.count ? boundaries[index + 1] : content.duration + 1
      let sentences = content.transcript.filter { $0.start >= start && $0.start < end }
      let slide = content.visuals.last(where: { $0.time >= start - 0.5 && $0.time < end })
      return Span(start: start, end: end, sentences: sentences, slide: slide)
    }
    spans.removeAll { $0.sentences.isEmpty && $0.slide == nil }

    // Merge smallest neighbours until within the section budget
    // (reserve one slot for the synthesized summary).
    while spans.count > SNMLimits.maxSections - 1 {
      var smallest = 0
      var smallestWeight = Int.max
      for (i, span) in spans.enumerated() {
        let weight =
          span.sentences.reduce(0) { $0 + $1.text.count } + (span.slide.map { _ in 200 } ?? 0)
        if weight < smallestWeight {
          smallestWeight = weight
          smallest = i
        }
      }
      let target = smallest == 0 ? 0 : smallest - 1
      var merged = spans[target]
      let other = spans[smallest == 0 ? 1 : smallest]
      merged.end = max(merged.end, other.end)
      merged.start = min(merged.start, other.start)
      merged.sentences = (merged.sentences + other.sentences).sorted { $0.start < $1.start }
      merged.slide = merged.slide ?? other.slide
      spans[target] = merged
      spans.remove(at: smallest == 0 ? 1 : smallest)
    }
    return spans
  }

  /// Persistent course/app chrome is not a new topic. Only a changed
  /// primary visual heading (or a very long interval under the same
  /// heading) creates a visual topic boundary.
  static func meaningfulVisualBoundaryTimes(_ visuals: [VisualMoment]) -> [Double] {
    meaningfulVisualBoundaryTimes(visuals, language: .english)
  }

  static func meaningfulVisualBoundaryTimes(
    _ visuals: [VisualMoment], language: ContentLanguage
  ) -> [Double] {
    guard visuals.count > 1 else { return [] }
    var boundaries: [Double] = []
    var previous = visuals[0]
    var previousHeading = primaryVisualHeading(previous, language: language)
    var lastBoundaryTime = previous.time

    for visual in visuals.dropFirst() {
      let heading = primaryVisualHeading(visual, language: language)
      let elapsed = visual.time - previous.time
      let headingChanged: Bool
      switch (previousHeading, heading) {
      case (let old?, let new?): headingChanged = old != new
      case (nil, nil): headingChanged = false
      default: headingChanged = elapsed >= 15
      }
      if headingChanged || visual.time - lastBoundaryTime >= 90 {
        boundaries.append(visual.time)
        lastBoundaryTime = visual.time
      }
      previous = visual
      previousHeading = heading
    }
    return boundaries
  }

  private static func primaryVisualHeading(
    _ visual: VisualMoment, language: ContentLanguage = .english
  ) -> String? {
    guard let title = visual.lines.first(where: looksLikeTitle) else { return nil }
    let chrome = Set(["app", "application", "desktop", "mobile", "studio"])
    let originalWords = Keywords.contentWords(
      title.replacingOccurrences(of: "_", with: " "), language: language)
    let filteredWords = originalWords.filter { !chrome.contains($0) }
    let words = filteredWords.isEmpty ? originalWords : filteredWords
    guard !words.isEmpty else { return nil }
    return words.joined(separator: " ")
  }

  /// When the same deck/app title heads several spans, use the speaker's
  /// topic words as the section title while retaining the exact source
  /// frame and timestamp as evidence.
  static func disambiguatingRepeatedVisualHeadings(in spans: [Span]) -> [Span] {
    disambiguatingRepeatedVisualHeadings(in: spans, language: .english)
  }

  static func disambiguatingRepeatedVisualHeadings(
    in spans: [Span], language: ContentLanguage
  ) -> [Span] {
    var counts: [String: Int] = [:]
    for span in spans {
      if let slide = span.slide, let heading = primaryVisualHeading(slide, language: language) {
        counts[heading, default: 0] += 1
      }
    }
    return spans.map { span in
      var span = span
      if let slide = span.slide,
        let heading = primaryVisualHeading(slide, language: language),
        counts[heading, default: 0] > 1,
        !span.sentences.isEmpty
      {
        span.headingOverride = spokenHeading(for: span, language: language)
      }
      return span
    }
  }

  // MARK: - Section construction

  static func makeSection(from span: Span) -> NoteSection {
    makeSection(from: span, language: .english)
  }

  static func makeSection(from span: Span, language: ContentLanguage) -> NoteSection {
    let heading = headingFor(span, language: language)
    var slideLines = span.slide?.lines ?? []
    // Remove the line actually chosen as the heading, not blindly the first
    // OCR line. Vision ordering can put a body line above the true title.
    if let headingIndex = slideLines.firstIndex(of: heading) {
      slideLines.remove(at: headingIndex)
    }
    let rawEnumerated = enumeratedItems(slideLines)
    let enumerated =
      span.sentences.isEmpty
      ? rawEnumerated
      : rawEnumerated.filter { isSupportedBySpeech($0, in: span) }
    let icons = iconHints(for: heading + " " + slideLines.joined(separator: " "))
    let groundedSketch = (span.slide?.sketch?.count ?? 0) >= 3 ? span.slide?.sketch : nil
    let sourceTime = span.slide?.time ?? span.sentences.first?.start ?? span.start

    // Explicit numbered content, or a "N ways/methods/steps" heading → process
    if enumerated.count >= 2 {
      return .process(
        heading: heading, steps: enumerated, iconHints: icons,
        sourceTime: sourceTime, sketch: groundedSketch)
    }
    if headingSuggestsList(heading, language: language),
      pointCandidates(span, language: language).count >= 2
    {
      return .process(
        heading: heading, steps: pointCandidates(span, language: language), iconHints: icons,
        sourceTime: sourceTime, sketch: groundedSketch)
    }
    // "X vs Y" → comparison
    if let (left, right) = versusSplit(heading, language: language) {
      let sides = attributedComparisonPoints(
        span, leftTitle: left, rightTitle: right, language: language)
      // If the source does not explicitly attribute claims to both
      // sides, a comparison layout would invent that attribution.
      if !sides.left.isEmpty, !sides.right.isEmpty {
        return .comparison(
          heading: heading, leftTitle: left, leftPoints: sides.left,
          rightTitle: right, rightPoints: sides.right,
          sourceTime: sourceTime, sketch: groundedSketch)
      }
    }
    // "X is/means Y" with a short span → definition
    if span.sentences.count <= 2,
      let (term, meaning) = definitionSplit(span, language: language)
    {
      return .definition(term: term, meaning: meaning, sourceTime: sourceTime)
    }
    let body = span.sentences.first.map(\.text)
    var points = pointCandidates(span, language: language)
    points.removeAll { $0.caseInsensitiveCompare(heading) == .orderedSame }
    // don't repeat the body sentence as a bullet
    if let body {
      let bodyNote = compress(body, language: language)
      points.removeAll { $0 == bodyNote || bodyNote.contains($0) }
    }
    // Never pad narrated notes with OCR just to reach a visual density
    // target. OCR remains available in Evidence Inspector, and visual-only
    // sources still use it as their primary note content.
    if span.sentences.isEmpty, points.count < 2, !slideLines.isEmpty {
      let existing = Set(points)
      points += slideLines.filter { looksLikeTitle($0) && !existing.contains($0) }.prefix(
        SNMLimits.maxPoints)
      points = Array(points.prefix(SNMLimits.maxPoints))
    }
    // the traced frame is the section's illustration — art from THIS video
    return .concept(
      heading: heading, body: body, points: points,
      iconHints: icons, quote: nil, sourceTime: sourceTime, sketch: groundedSketch)
  }

  static func attributedComparisonPoints(
    _ span: Span, leftTitle: String,
    rightTitle: String
  ) -> (left: [String], right: [String]) {
    attributedComparisonPoints(
      span, leftTitle: leftTitle, rightTitle: rightTitle, language: .english)
  }

  static func attributedComparisonPoints(
    _ span: Span, leftTitle: String, rightTitle: String, language: ContentLanguage
  ) -> (left: [String], right: [String]) {
    let leftWords = Set(Keywords.contentWords(leftTitle, language: language))
    let rightWords = Set(Keywords.contentWords(rightTitle, language: language))
    var left: [String] = []
    var right: [String] = []
    for point in pointCandidates(span, language: language) {
      let words = Set(Keywords.contentWords(point, language: language))
      let leftScore = words.intersection(leftWords).count
      let rightScore = words.intersection(rightWords).count
      if leftScore > rightScore {
        left.append(point)
      } else if rightScore > leftScore {
        right.append(point)
      }
    }
    return (Array(left.prefix(4)), Array(right.prefix(4)))
  }

  static func headingFor(_ span: Span) -> String {
    headingFor(span, language: .english)
  }

  static func headingFor(_ span: Span, language: ContentLanguage) -> String {
    if let override = span.headingOverride { return override }
    // Slides usually carry better titles than speech — but only lines
    // that read like words, not UI number debris ("5 48", "= =0").
    if let slideTitle = span.slide?.lines.first(where: looksLikeTitle) {
      return slideTitle
    }
    return spokenHeading(for: span, language: language)
  }

  private static func spokenHeading(
    for span: Span, language: ContentLanguage = .english
  ) -> String {
    let text = span.sentences.map(\.text).joined(separator: " ")
    let phrases = Keywords.topPhrases(in: text, limit: 4, language: language)
    // prefer a keyphrase the speaker opens the span with
    let opening = span.sentences.first?.text.lowercased() ?? ""
    if let anchored = phrases.first(where: { opening.contains($0) }) { return anchored.capitalized }
    if let top = phrases.first { return top.capitalized }
    if let sentence = span.sentences.first {
      return SNMValidation.clip(compress(sentence.text, language: language), 60)
    }
    return language.onScreenHeading(at: span.start)
  }

  /// A line is heading-worthy when it's mostly letters, not UI debris.
  static func looksLikeTitle(_ line: String) -> Bool {
    guard line.count >= 4 else { return false }
    let letters = line.filter(\.isLetter).count
    return letters >= 3 && Double(letters) >= Double(line.count) * 0.45
  }

  /// Rank a span's sentences by keyword density and compress into note points.
  static func pointCandidates(_ span: Span) -> [String] {
    pointCandidates(span, language: .english)
  }

  static func pointCandidates(_ span: Span, language: ContentLanguage) -> [String] {
    let all = span.sentences.map(\.text)
    guard !all.isEmpty else {
      return span.slide.map { Array($0.lines.dropFirst().prefix(SNMLimits.maxPoints)) } ?? []
    }
    let keywords = Set(
      Keywords.topPhrases(in: all.joined(separator: " "), limit: 8, language: language)
        .flatMap { $0.split(separator: " ").map(String.init) })
    let scored = all.enumerated().map { index, sentence -> (Int, Double, String) in
      let words = Keywords.contentWords(sentence, language: language)
      let hits = words.filter { keywords.contains($0) }.count
      let lengthPenalty = abs(Double(sentence.count) - 70) / 70
      return (index, Double(hits) - lengthPenalty * 0.5, sentence)
    }
    let picked = scored.sorted { $0.1 > $1.1 }.prefix(SNMLimits.maxPoints)
      .sorted { $0.0 < $1.0 }  // restore source order
    return picked.map { compress($0.2, language: language) }.filter { $0.count > 8 }
  }

  /// Strip conversational filler so a spoken sentence reads like a note.
  static func compress(_ sentence: String) -> String {
    compress(sentence, language: .english)
  }

  static func compress(_ sentence: String, language: ContentLanguage) -> String {
    var s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    let englishFillers = [
      "so basically ", "so ", "and then ", "and ", "but ", "now ", "okay ", "well ",
      "you know ", "basically ", "actually ", "really ", "finally, ", "finally ", "next, ",
      "next ", "first, ", "second, ", "third, ", "welcome to ",
    ]
    let germanFillers = [
      "also im grunde ", "im grunde ", "also ", "und dann ", "und ", "aber ", "nun ", "jetzt ",
      "okay ", "naja ", "nun ja ", "weißt du ", "wissen sie ", "eigentlich ", "wirklich ",
      "schließlich, ", "schließlich ", "als nächstes, ", "als nächstes ", "zuerst, ", "zuerst ",
      "erstens, ", "erstens ", "zweitens, ", "zweitens ", "drittens, ", "drittens ",
      "willkommen bei ", "willkommen zu ",
    ]
    let fillers = language == .german ? germanFillers : englishFillers
    for filler in fillers {
      if s.lowercased().hasPrefix(filler) { s = String(s.dropFirst(filler.count)) }
    }
    if language == .german {
      s = s.replacingOccurrences(of: ", weißt du,", with: ",", options: .caseInsensitive)
        .replacingOccurrences(of: " sozusagen ", with: " ", options: .caseInsensitive)
        .replacingOccurrences(of: " gewissermaßen ", with: " ", options: .caseInsensitive)
    } else {
      s = s.replacingOccurrences(of: ", you know,", with: ",")
        .replacingOccurrences(of: " kind of ", with: " ")
        .replacingOccurrences(of: " sort of ", with: " ")
    }
    if let first = s.first { s = String(first).uppercased() + s.dropFirst() }
    if s.hasSuffix(".") { s = String(s.dropLast()) }
    return s
  }

  static func enumeratedItems(_ lines: [String]) -> [String] {
    let pattern = #/^\s*(?:\d+[\.\):]|[-•*▪◦])\s*(.+)$/#
    return lines.compactMap { line in
      guard let match = line.firstMatch(of: pattern) else { return nil }
      let item = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
      let contentWords = Keywords.contentWords(item)
      guard item.count >= 4, contentWords.contains(where: { $0.count >= 4 }) else { return nil }
      return item
    }
  }

  private static func isSupportedBySpeech(_ line: String, in span: Span) -> Bool {
    let speechWords = Set(Keywords.contentWords(span.sentences.map(\.text).joined(separator: " ")))
    let lineWords = Set(Keywords.contentWords(line))
    return !speechWords.isDisjoint(with: lineWords)
  }

  static func headingSuggestsList(_ heading: String) -> Bool {
    headingSuggestsList(heading, language: .english)
  }

  static func headingSuggestsList(_ heading: String, language: ContentLanguage) -> Bool {
    let h = heading.lowercased()
    let numberWords: [String]
    let listWords: [String]
    if language == .german {
      numberWords = ["2 ", "3 ", "4 ", "5 ", "zwei ", "drei ", "vier ", "fünf "]
      listWords = [
        "wege", "methoden", "schritte", "regeln", "tipps", "gründe", "prinzipien", "stufen",
        "phasen",
      ]
    } else {
      numberWords = ["2 ", "3 ", "4 ", "5 ", "two ", "three ", "four ", "five "]
      listWords = [
        "ways", "methods", "steps", "rules", "tips", "reasons", "principles", "stages", "phases",
      ]
    }
    return listWords.contains(where: h.contains)
      && (numberWords.contains(where: h.contains) || h.first?.isNumber == true)
  }

  static func versusSplit(_ heading: String) -> (String, String)? {
    versusSplit(heading, language: .english)
  }

  static func versusSplit(
    _ heading: String, language: ContentLanguage
  ) -> (String, String)? {
    let tokens =
      language == .german
      ? [" vs ", " vs. ", " versus ", " gegen ", " im vergleich zu "]
      : [" vs ", " vs. ", " versus "]
    for token in tokens {
      if let range = heading.lowercased().range(of: token) {
        let left = String(heading[heading.startIndex..<range.lowerBound])
        let right = String(heading[range.upperBound...])
        if left.count >= 2, right.count >= 2 { return (left, right) }
      }
    }
    return nil
  }

  static func definitionSplit(_ span: Span) -> (String, String)? {
    definitionSplit(span, language: .english)
  }

  static func definitionSplit(
    _ span: Span, language: ContentLanguage
  ) -> (String, String)? {
    guard let sentence = span.sentences.first?.text else { return nil }
    let tokens =
      language == .german
      ? [" ist ", " bedeutet ", " bezeichnet "]
      : [" is ", " means ", " refers to "]
    for token in tokens {
      if let range = sentence.range(of: token, options: .caseInsensitive),
        sentence.distance(from: sentence.startIndex, to: range.lowerBound) <= 40
      {
        let term = String(sentence[sentence.startIndex..<range.lowerBound])
        let meaning = String(sentence[range.upperBound...])
        // a term must be a clean noun phrase, not a run-on across sentences
        if Keywords.contentWords(term, language: language).count >= 1, !term.contains(". "),
          term.count <= 42,
          meaning.count >= 20
        {
          return (term, meaning)
        }
      }
    }
    return nil
  }

  // MARK: - Quotes / summary / title

  static func pullQuote(_ transcript: [TranscriptSegment], sections: [NoteSection]) -> (
    String, Double
  )? {
    pullQuote(transcript, sections: sections, language: .english)
  }

  static func pullQuote(
    _ transcript: [TranscriptSegment], sections: [NoteSection], language: ContentLanguage
  ) -> (String, Double)? {
    let markers =
      language == .german
      ? [
        "im grunde", "der schlüssel", "entscheidend ist", "denk daran", "denken sie daran",
        "am wichtigsten", "die wahrheit ist", "darauf kommt es an",
      ]
      : [
        "basically", "the key", "remember", "the most important", "what you have done",
        "the truth is", "here's the thing",
      ]
    let candidates = transcript.filter { seg in
      let n = seg.text.count
      return n >= 60 && n <= 200 && markers.contains(where: seg.text.lowercased().contains)
    }
    guard let best = candidates.max(by: { $0.text.count < $1.text.count }) else { return nil }
    return (best.text, best.start)
  }

  static func attach(quote: (String, Double), to sections: [NoteSection]) -> [NoteSection] {
    var sections = sections
    // attach to the concept section whose time span contains the quote
    for (i, section) in sections.enumerated() {
      if case .concept(let h, let b, let p, let icons, nil, let t, let sketch) = section,
        let start = t, quote.1 >= start
      {
        let isLastMatch = !sections.dropFirst(i + 1).contains {
          ($0.sourceTime ?? .infinity) <= quote.1
        }
        if isLastMatch {
          sections[i] = .concept(
            heading: h, body: b, points: p, iconHints: icons,
            quote: quote.0, sourceTime: t, sketch: sketch)
          return sections
        }
      }
    }
    sections.append(.quote(text: quote.0, attribution: nil, sourceTime: quote.1))
    return sections
  }

  static func topDocumentPoints(spans: [Span], limit: Int) -> [String] {
    topDocumentPoints(spans: spans, limit: limit, language: .english)
  }

  static func topDocumentPoints(
    spans: [Span], limit: Int, language: ContentLanguage
  ) -> [String] {
    var out: [String] = []
    for span in spans {
      // fragments and greetings make poor takeaways
      if let best = pointCandidates(span, language: language).first(where: { $0.count >= 28 }),
        !out.contains(best)
      {
        out.append(best)
      }
      if out.count == limit { break }
    }
    return out
  }

  static func titleAndSubtitle(_ content: ExtractedContent, spans: [Span]) -> (String, String?) {
    titleAndSubtitle(content, spans: spans, language: .english)
  }

  static func titleAndSubtitle(
    _ content: ExtractedContent, spans: [Span], language: ContentLanguage
  ) -> (String, String?) {
    // First slide's first line is usually the lecture title.
    if let first = content.visuals.first, let title = first.lines.first(where: looksLikeTitle),
      title.count >= 6
    {
      let subtitle = first.lines.first(where: { looksLikeTitle($0) && $0 != title })
      return (title, subtitle)
    }
    // spoken-only: the opening sentence usually names the talk
    if let first = content.transcript.first {
      let title = SNMValidation.clip(compress(first.text, language: language), 60)
      if title.count >= 10 {
        let text = content.transcript.prefix(6).map(\.text).joined(separator: " ")
        let phrase = Keywords.topPhrases(in: text, limit: 1, language: language).first
        let subtitle = phrase.map(\.capitalized)
        return (title, subtitle != title ? subtitle : content.sourceName)
      }
    }
    return (content.sourceName, nil)
  }

  /// Cover art: the title frame's trace when substantial, else the
  /// earliest source-backed visual near the opening. Never search the whole
  /// lecture for the densest frame: that can turn unrelated later B-roll
  /// into the cover illustration.
  static func heroSketch(_ content: ExtractedContent) -> [SketchStroke]? {
    let openingLimit = GroundingAuditor.openingWindow(duration: content.duration)
    if let titled = content.visuals.first(where: {
      $0.time <= openingLimit && !$0.lines.isEmpty && ($0.sketch?.count ?? 0) >= 3
    }) {
      return titled.sketch
    }
    return content.visuals.first(where: { $0.time <= openingLimit && ($0.sketch?.count ?? 0) >= 8 }
    )?.sketch
  }

  // MARK: - Icon hints

  static func iconHints(for text: String) -> [String] {
    let words = Keywords.contentWords(text)
    var hints: [String] = []
    for word in words {
      if let hint = IconLibrary.keywordMap[word], !hints.contains(hint) { hints.append(hint) }
      if hints.count == 4 { break }
    }
    return hints
  }
}

/// Small deterministic keyword extractor (TF over content words, 1–2-grams).
enum Keywords {
  static let englishStopwords: Set<String> = [
    "the", "a", "an", "and", "or", "but", "if", "then", "so", "of", "to", "in", "on", "at", "by",
    "for",
    "with", "about", "as", "into", "like", "through", "after", "over", "between", "out", "against",
    "during", "without", "before", "under", "around", "among", "is", "are", "was", "were", "be",
    "been",
    "being", "have", "has", "had", "do", "does", "did", "will", "would", "should", "can", "could",
    "may",
    "might", "must", "shall", "this", "that", "these", "those", "i", "you", "he", "she", "it", "we",
    "they", "them", "his", "her", "its", "our", "your", "their", "my", "me", "us", "him", "what",
    "which",
    "who", "when", "where", "why", "how", "all", "each", "some", "any", "no", "not", "only", "own",
    "same",
    "than", "too", "very", "just", "now", "also", "there", "here", "one", "two", "get", "got",
    "going",
    "want", "really", "thing", "things", "way", "well", "make", "let", "lot", "kind", "sort",
    "know",
    "see", "look", "actually", "basically", "okay", "yeah", "right", "mean", "say", "said", "go",
    "come",
  ]

  static let germanStopwords: Set<String> = [
    "aber", "alle", "allem", "allen", "aller", "alles", "als", "also", "am", "an", "ander",
    "andere", "anderem", "anderen", "anderer", "anderes", "auch", "auf", "aus", "bei", "bin",
    "bis", "bist", "da", "damit", "dann", "das", "dass", "dein", "deine", "dem", "den", "denn",
    "der", "des", "die", "dies", "diese", "diesem", "diesen", "dieser", "dieses", "doch", "dort",
    "durch", "ein", "eine", "einem", "einen", "einer", "eines", "er", "es", "etwas", "für",
    "gegen", "gewesen", "hat", "hatte", "haben", "hier", "hin", "hinter", "ich", "ihm", "ihn",
    "ihnen", "ihr", "ihre", "im", "in", "ist", "ja", "jede", "jedem", "jeden", "jeder", "jedes",
    "jener", "jenes", "jetzt", "kann", "kein", "keine", "mit", "muss", "nach", "nicht", "nichts",
    "noch", "nun", "nur", "ob", "oder", "ohne", "sehr", "sein", "seine", "selbst", "sich", "sie",
    "sind", "so", "solche", "um", "und", "uns", "unser", "unter", "vom", "von", "vor", "war",
    "waren", "warum", "was", "weiter", "welche", "welchem", "welchen", "welcher", "welches", "wenn",
    "wer", "werde", "werden", "wie", "wieder", "will", "wir", "wird", "wo", "zu", "zum", "zur",
    "über",
    // Conversational fillers are excluded from German key phrases as well
    // as compressed at sentence boundaries.
    "eigentlich", "grund", "naja", "okay", "sozusagen", "wirklich", "weißt", "wissen",
  ]

  // Compatibility for existing English-only callers and tests.
  static let stopwords = englishStopwords

  static func contentWords(
    _ text: String, language: ContentLanguage = .english
  ) -> [String] {
    let selectedStopwords = language == .german ? germanStopwords : englishStopwords
    return text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 3 && !selectedStopwords.contains($0) }
  }

  static func topPhrases(
    in text: String, limit: Int, language: ContentLanguage = .english
  ) -> [String] {
    let selectedStopwords = language == .german ? germanStopwords : englishStopwords
    let words = contentWords(text, language: language)
    guard !words.isEmpty else { return [] }
    var counts: [String: Int] = [:]
    for word in words { counts[word, default: 0] += 1 }
    // bigrams of adjacent content words weigh more
    let raw = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter
    { !$0.isEmpty }
    for i in 0..<max(0, raw.count - 1) {
      let a = raw[i]
      let b = raw[i + 1]
      if !selectedStopwords.contains(a), !selectedStopwords.contains(b), a.count >= 3,
        b.count >= 3
      {
        counts["\(a) \(b)", default: 0] += 2
      }
    }
    return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .prefix(limit).map(\.key)
  }
}
