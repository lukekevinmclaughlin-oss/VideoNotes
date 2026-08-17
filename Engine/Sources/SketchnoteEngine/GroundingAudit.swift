import Foundation

/// Deterministic evidence/provenance metrics for a generated note document.
///
/// An illustration is considered source-matched only when its complete stroke
/// payload is byte-for-byte equivalent to a traced source moment. A section
/// illustration is temporally aligned only when that same moment is also near
/// the section's citation. This deliberately does not use visual similarity:
/// a merely plausible or generated picture must never pass as source evidence.
public struct GroundingAuditReport: Encodable, Equatable, Sendable {
  public var totalSections: Int
  public var citedSections: Int
  public var alignedCitations: Int
  public var illustratedSections: Int
  public var sourceMatchedIllustrations: Int
  public var temporallyAlignedIllustrations: Int
  public var heroIllustrationPresent: Bool
  public var heroSourceMatched: Bool
  public var heroOpeningMatched: Bool

  public var synthesizedSections: Int { totalSections - citedSections }
  public var unalignedCitations: Int { citedSections - alignedCitations }
  public var ungroundedIllustrations: Int {
    illustratedSections - sourceMatchedIllustrations
  }
  public var temporallyMisalignedIllustrations: Int {
    sourceMatchedIllustrations - temporallyAlignedIllustrations
  }
  public var citationAlignmentRate: Double {
    citedSections == 0 ? 1 : Double(alignedCitations) / Double(citedSections)
  }
  public var illustrationGroundingRate: Double {
    illustratedSections == 0
      ? 1 : Double(sourceMatchedIllustrations) / Double(illustratedSections)
  }
  public var illustrationsAreStrictlyGrounded: Bool {
    ungroundedIllustrations == 0 && temporallyMisalignedIllustrations == 0
      && (!heroIllustrationPresent || heroOpeningMatched)
  }

  private enum CodingKeys: String, CodingKey {
    case totalSections
    case citedSections
    case alignedCitations
    case synthesizedSections
    case unalignedCitations
    case citationAlignmentRate
    case illustratedSections
    case sourceMatchedIllustrations
    case temporallyAlignedIllustrations
    case ungroundedIllustrations
    case temporallyMisalignedIllustrations
    case illustrationGroundingRate
    case heroIllustrationPresent
    case heroSourceMatched
    case heroOpeningMatched
    case illustrationsAreStrictlyGrounded
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(totalSections, forKey: .totalSections)
    try values.encode(citedSections, forKey: .citedSections)
    try values.encode(alignedCitations, forKey: .alignedCitations)
    try values.encode(synthesizedSections, forKey: .synthesizedSections)
    try values.encode(unalignedCitations, forKey: .unalignedCitations)
    try values.encode(citationAlignmentRate, forKey: .citationAlignmentRate)
    try values.encode(illustratedSections, forKey: .illustratedSections)
    try values.encode(sourceMatchedIllustrations, forKey: .sourceMatchedIllustrations)
    try values.encode(temporallyAlignedIllustrations, forKey: .temporallyAlignedIllustrations)
    try values.encode(ungroundedIllustrations, forKey: .ungroundedIllustrations)
    try values.encode(
      temporallyMisalignedIllustrations, forKey: .temporallyMisalignedIllustrations)
    try values.encode(illustrationGroundingRate, forKey: .illustrationGroundingRate)
    try values.encode(heroIllustrationPresent, forKey: .heroIllustrationPresent)
    try values.encode(heroSourceMatched, forKey: .heroSourceMatched)
    try values.encode(heroOpeningMatched, forKey: .heroOpeningMatched)
    try values.encode(
      illustrationsAreStrictlyGrounded, forKey: .illustrationsAreStrictlyGrounded)
  }
}

public enum GroundingAuditor {
  /// The only source interval eligible for cover imagery. Keeping this shared
  /// with the structurer prevents production selection and provenance checks
  /// from drifting apart.
  public static func openingWindow(duration: Double) -> Double {
    min(45, max(8, max(0, duration) * 0.12))
  }

  /// Audits citations and illustration provenance without inference or network
  /// access. The tolerance accounts for frame sampling and sentence boundaries.
  public static func audit(
    document: NoteDocument, content: ExtractedContent,
    citationTolerance: Double = 3
  ) -> GroundingAuditReport {
    let tolerance = max(0, citationTolerance)
    let moments = content.visuals.filter { !$0.time.isNaN && $0.time.isFinite }
    let transcript = content.transcript.filter {
      $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
    }

    var citedSections = 0
    var alignedCitations = 0
    var illustratedSections = 0
    var sourceMatchedIllustrations = 0
    var temporallyAlignedIllustrations = 0

    for section in document.sections {
      if let sourceTime = section.sourceTime, sourceTime.isFinite {
        citedSections += 1
        let hasAlignedSpeech = transcript.contains {
          sourceTime >= $0.start - tolerance && sourceTime <= $0.end + tolerance
        }
        let hasAlignedVisual = moments.contains { abs($0.time - sourceTime) <= tolerance }
        if hasAlignedSpeech || hasAlignedVisual { alignedCitations += 1 }
      }

      guard let sketch = section.sourceSketch, !sketch.isEmpty else { continue }
      illustratedSections += 1
      let exactMatches = moments.filter { $0.sketch == sketch }
      guard !exactMatches.isEmpty else { continue }
      sourceMatchedIllustrations += 1
      if let sourceTime = section.sourceTime,
        exactMatches.contains(where: { abs($0.time - sourceTime) <= tolerance })
      {
        temporallyAlignedIllustrations += 1
      }
    }

    let heroSketch = document.heroSketch.flatMap { $0.isEmpty ? nil : $0 }
    let heroMatches = heroSketch.map { sketch in moments.filter { $0.sketch == sketch } } ?? []
    let openingLimit = openingWindow(duration: content.duration)

    return GroundingAuditReport(
      totalSections: document.sections.count,
      citedSections: citedSections,
      alignedCitations: alignedCitations,
      illustratedSections: illustratedSections,
      sourceMatchedIllustrations: sourceMatchedIllustrations,
      temporallyAlignedIllustrations: temporallyAlignedIllustrations,
      heroIllustrationPresent: heroSketch != nil,
      heroSourceMatched: !heroMatches.isEmpty,
      heroOpeningMatched: heroMatches.contains { $0.time <= openingLimit })
  }
}

extension NoteSection {
  fileprivate var sourceSketch: [SketchStroke]? {
    switch self {
    case .concept(_, _, _, _, _, _, let sketch), .process(_, _, _, _, let sketch),
      .comparison(_, _, _, _, _, _, let sketch):
      return sketch
    case .methods, .quote, .definition, .summary:
      return nil
    }
  }
}
