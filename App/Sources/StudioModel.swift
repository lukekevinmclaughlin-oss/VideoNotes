import CoreGraphics
import Foundation
import SketchnoteEngine
import SwiftUI
import UniformTypeIdentifiers

enum SemanticNoteExportFormat: String, CaseIterable, Identifiable {
  case markdown
  case plainText
  case html
  case json

  var id: Self { self }

  var displayName: String {
    switch self {
    case .markdown: return String(localized: "Markdown")
    case .plainText: return String(localized: "Plain Text")
    case .html: return String(localized: "Web Page (HTML)")
    case .json: return String(localized: "Structured JSON")
    }
  }

  var icon: String {
    switch self {
    case .markdown: return "text.document"
    case .plainText: return "doc.plaintext"
    case .html: return "globe"
    case .json: return "curlybraces"
    }
  }

  var contentType: UTType {
    switch self {
    case .markdown: return UTType(filenameExtension: "md") ?? .plainText
    case .plainText: return .plainText
    case .html: return .html
    case .json: return .json
    }
  }
}

extension Palette {
  var localizedDisplayName: String {
    switch name {
    case "Paper & Ink": return String(localized: "Paper & Ink")
    case "Blueprint": return String(localized: "Blueprint")
    case "Chalkboard": return String(localized: "Chalkboard")
    case "Pastel": return String(localized: "Pastel")
    default: return name
    }
  }
}

extension NotePresentationFormat {
  var localizedDisplayName: String {
    switch self {
    case .illustrated: return String(localized: "Illustrated")
    case .detailed: return String(localized: "Detailed")
    case .condensed: return String(localized: "Condensed Review")
    case .evidenceFirst: return String(localized: "Evidence-First")
    case .focusCards: return String(localized: "Focus Cards")
    case .quickReview: return String(localized: "Quick Review")
    case .studyGuide: return String(localized: "Study Guide")
    case .cornellNotes: return String(localized: "Cornell Notes")
    case .hierarchicalOutline: return String(localized: "Hierarchical Outline")
    case .timeline: return String(localized: "Timeline / Chapter Map")
    case .qaFlashcards: return String(localized: "Q&A Flashcards")
    case .examRevision: return String(localized: "Exam Revision")
    case .tutorial: return String(localized: "Tutorial / Step-by-Step")
    case .decisionsAndActions: return String(localized: "Decisions & Action Items")
    }
  }
}

extension PDFPageFormat {
  var localizedDisplayName: String {
    switch self {
    case .digital: return String(localized: "Digital 9:16")
    case .a4: return String(localized: "A4 Print")
    case .usLetter: return String(localized: "US Letter")
    }
  }
}

/// App state: one media file in → sketchnote pages out.
@MainActor
final class StudioModel: ObservableObject {

  struct EvidenceItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
      case speech = "Speech"
      case visual = "On-screen"

      var displayName: String {
        switch self {
        case .speech: return String(localized: "Speech")
        case .visual: return String(localized: "On-screen")
        }
      }
      var icon: String { self == .speech ? "waveform" : "viewfinder" }
      var tint: Color { self == .speech ? VNTheme.cyan : VNTheme.gold }
    }

    let id: String
    var kind: Kind
    var time: Double
    var title: String
    var detail: String
    var hasTrace: Bool
  }

  struct ReadingPage: Identifiable, Equatable {
    let id: Int
    var title: String
    var detail: String
    var sourceTimes: [Double]
  }

  struct GroundingReport: Equatable {
    var duration: Double
    var transcriptSegments: Int
    var visualMoments: Int
    var tracedVisuals: Int
    var citedSections: Int
    var synthesizedSections: Int
    var sourceIllustrations: Int = 0
    var verifiedSourceIllustrations: Int = 0

    var hasSpeechEvidence: Bool { transcriptSegments > 0 }
    var hasVisualEvidence: Bool { visualMoments > 0 }
    var totalSections: Int { citedSections + synthesizedSections }
    var requiresReview: Bool {
      synthesizedSections > 0 || !hasSpeechEvidence || !hasVisualEvidence
        || verifiedSourceIllustrations != sourceIllustrations
    }
    var citationLabel: String {
      guard totalSections > 0 else { return String(localized: "No note sections") }
      if totalSections == 1 {
        return String(localized: "\(citedSections) of 1 section source-cited")
      }
      return String(
        localized: "\(citedSections) of \(totalSections) sections source-cited")
    }
    var coverageLabel: String {
      if hasSpeechEvidence && hasVisualEvidence {
        return String(localized: "Speech + visual evidence")
      }
      if hasSpeechEvidence { return String(localized: "Speech evidence only") }
      if hasVisualEvidence { return String(localized: "Visual evidence only") }
      return String(localized: "Limited evidence")
    }
    var coverageIcon: String {
      if hasSpeechEvidence && hasVisualEvidence { return "rectangle.stack.badge.checkmark" }
      if hasSpeechEvidence { return "waveform" }
      if hasVisualEvidence { return "viewfinder" }
      return "exclamationmark.triangle"
    }
    var coverageTint: Color {
      if hasSpeechEvidence && hasVisualEvidence { return VNTheme.mint }
      if hasSpeechEvidence { return VNTheme.cyan }
      if hasVisualEvidence { return VNTheme.gold }
      return .orange
    }
    var illustrationLabel: String {
      guard sourceIllustrations > 0 else { return String(localized: "No source drawings used") }
      if verifiedSourceIllustrations == sourceIllustrations {
        return String(localized: "\(verifiedSourceIllustrations) source-matched drawings")
      }
      if sourceIllustrations == 1 {
        return String(localized: "\(verifiedSourceIllustrations) of 1 drawing source-matched")
      }
      return String(
        localized:
          "\(verifiedSourceIllustrations) of \(sourceIllustrations) drawings source-matched")
    }
    var illustrationTint: Color {
      verifiedSourceIllustrations == sourceIllustrations ? VNTheme.mint : .orange
    }
  }

  enum Phase: Equatable {
    case empty
    case analyzing
    case illustrating
    case ready
    case failed(String)

    /// True while the CPU-heavy pipeline is running.
    var isProcessing: Bool { self == .analyzing || self == .illustrating }
  }

  @Published private(set) var phase: Phase = .empty
  @Published private(set) var stageText = ""
  @Published private(set) var scanProgress: Double?  // nil → indeterminate
  @Published private(set) var stageIndex = 0  // 0 listen · 1 read · 2 structure · 3 illustrate
  @Published private(set) var sourceName = ""
  @Published private(set) var pages: [CGImage] = []
  @Published private(set) var pdfURL: URL?
  @Published private(set) var transcriptNotice: String?
  @Published private(set) var groundingReport: GroundingReport?
  @Published private(set) var sourceEvidence: [EvidenceItem] = []
  @Published private(set) var sourceURL: URL?
  @Published private(set) var failureCanOpenSettings = false
  @Published private(set) var isUpdatingStyle = false
  @Published private(set) var readingPages: [ReadingPage] = []
  @Published private(set) var sessionNotice: String?
  @Published private(set) var sessionNoticeIsSuccess = false
  @Published var currentPage = 0 {
    didSet { scheduleProjectSnapshotSave() }
  }

  // style controls (persisted)
  @Published var paletteIndex: Int {
    didSet {
      UserDefaults.standard.set(paletteIndex, forKey: "vn.paletteIndex")
      guard !isRestoringSnapshot else { return }
      rerender()
      scheduleProjectSnapshotSave(immediate: true)
    }
  }
  @Published var compact: Bool {
    didSet {
      UserDefaults.standard.set(compact, forKey: "vn.compact")
      guard !isRestoringSnapshot else { return }
      rerender()
      scheduleProjectSnapshotSave(immediate: true)
    }
  }
  @Published var presentationFormat: NotePresentationFormat {
    didSet {
      UserDefaults.standard.set(presentationFormat.rawValue, forKey: "vn.presentationFormat")
      guard !isRestoringSnapshot else { return }
      rerender()
      scheduleProjectSnapshotSave(immediate: true)
    }
  }
  @Published var pdfPageFormat: PDFPageFormat {
    didSet {
      UserDefaults.standard.set(pdfPageFormat.rawValue, forKey: "vn.pdfPageFormat")
      guard !isRestoringSnapshot else { return }
      rerender()
      scheduleProjectSnapshotSave(immediate: true)
    }
  }
  private var seedBump: UInt64 = 0

  private var document: NoteDocument?
  private var extractedContent: ExtractedContent?
  private var baseSeed: UInt64 = 0
  private var renderTask: Task<Void, Never>?
  private var analysisTask: Task<Void, Never>?
  private var generation = 0  // discards results of a cancelled run
  private var renderRevision = 0
  private let snapshotStore: ProjectSnapshotStore
  private let snapshotPersistence: ProjectSnapshotPersistence
  private var sourceReference: ProjectSourceReference?
  private var snapshotSaveTask: Task<Void, Never>?
  private var snapshotRevision = 0
  private var isRestoringSnapshot = false
  private var didReportSnapshotWriteFailure = false

  init(snapshotStore: ProjectSnapshotStore = .applicationSupport()) {
    self.snapshotStore = snapshotStore
    snapshotPersistence = ProjectSnapshotPersistence(store: snapshotStore)
    let stored = UserDefaults.standard.integer(forKey: "vn.paletteIndex")
    paletteIndex = (0..<Palette.all.count).contains(stored) ? stored : 0
    compact = UserDefaults.standard.bool(forKey: "vn.compact")
    presentationFormat =
      NotePresentationFormat(
        rawValue: UserDefaults.standard.string(forKey: "vn.presentationFormat") ?? "")
      ?? .illustrated
    pdfPageFormat =
      PDFPageFormat(rawValue: UserDefaults.standard.string(forKey: "vn.pdfPageFormat") ?? "")
      ?? .digital
    restoreSavedProject()
  }

  var style: RenderStyle {
    RenderStyle(
      palette: Palette.all[paletteIndex], seed: baseSeed &+ seedBump, compact: compact,
      presentationFormat: presentationFormat, pdfPageFormat: pdfPageFormat)
  }
  var paletteNames: [String] { Palette.all.map(\.localizedDisplayName) }
  var pageCount: Int { pages.count }
  var isExportReady: Bool {
    phase == .ready && !isUpdatingStyle && !pages.isEmpty && pdfURL != nil
  }
  /// Semantic exports are derived from the typed note model and do not depend
  /// on image or PDF rendering succeeding.
  var isSemanticExportReady: Bool { document != nil }

  func pageCount(for format: NotePresentationFormat) -> Int? {
    document.map { PagePlanner.plan($0, format: format).count }
  }

  func consumeSessionNotice() { sessionNotice = nil }

  // MARK: - analyze

  func analyze(_ url: URL) {
    analysisTask?.cancel()
    renderTask?.cancel()
    renderRevision += 1
    removeTemporaryPDF()
    generation += 1
    let gen = generation
    sourceName = url.deletingPathExtension().lastPathComponent
    sourceURL = url
    phase = .analyzing
    stageText = String(localized: "Opening \(url.lastPathComponent)")
    scanProgress = nil
    stageIndex = 0
    pages = []
    pdfURL = nil
    document = nil
    transcriptNotice = nil
    groundingReport = nil
    sourceEvidence = []
    failureCanOpenSettings = false
    isUpdatingStyle = false
    extractedContent = nil
    sourceReference = nil
    readingPages = []
    sessionNotice = nil
    currentPage = 0

    analysisTask = Task { [weak self] in
      guard let self else { return }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        var injected: [TranscriptSegment]?
        #if DEBUG
          if let path = ProcessInfo.processInfo.environment["VIDEONOTES_FAKE_TRANSCRIPT"],
            let raw = try? String(contentsOfFile: path, encoding: .utf8)
          {
            injected = Transcriber.parseInjected(raw)
          }
        #endif
        let result = try await SketchnotePipeline.analyze(url: url, injectedTranscript: injected) {
          stage, message in
          Task { @MainActor [weak self] in
            guard let self, self.generation == gen else { return }
            self.stageText = Self.localizedPipelineMessage(stage: stage, message: message)
            switch stage {
            case .probing, .transcribing, .preparingModel:
              self.stageIndex = 0
              self.scanProgress = nil
            case .scanning(let fraction):
              self.stageIndex = 1
              self.scanProgress = fraction
            case .structuring:
              self.stageIndex = 2
              self.scanProgress = nil
            case .illustrating:
              self.stageIndex = 3
              self.scanProgress = nil
            }
          }
        }
        guard generation == gen else { return }
        document = result.document
        extractedContent = result.content
        sourceReference = ProjectSourceReference(url: url)
        baseSeed = result.seed
        seedBump = 0
        transcriptNotice = result.content.transcriptUnavailableReason.map(
          Self.localizedEngineMessage)
        groundingReport = Self.makeGroundingReport(
          document: result.document, content: result.content)
        sourceEvidence = Self.makeEvidence(from: result.content)
        #if DEBUG
          if let tPath = ProcessInfo.processInfo.environment["VIDEONOTES_AUTO_TRANSCRIPT"] {
            let dump = result.content.transcript.map { "\($0.start)|\($0.end)|\($0.text)" }.joined(
              separator: "\n")
            try? dump.write(toFile: tPath, atomically: true, encoding: .utf8)
          }
          if let out = ProcessInfo.processInfo.environment["VIDEONOTES_AUTO_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? (try? encoder.encode(result.document))?.write(to: URL(fileURLWithPath: out))
          }
        #endif
        scheduleProjectSnapshotSave(immediate: true)
        rerender()
      } catch {
        guard generation == gen else { return }
        let rawError = error.localizedDescription
        phase = .failed(Self.localizedEngineMessage(rawError))
        failureCanOpenSettings = rawError.localizedCaseInsensitiveContains("permission")
        #if DEBUG
          if let out = ProcessInfo.processInfo.environment["VIDEONOTES_AUTO_OUT"] {
            try? "ERROR: \(error.localizedDescription)".write(
              toFile: out, atomically: true, encoding: .utf8)
          }
        #endif
      }
    }
  }

  func cancelAnalysis() {
    generation += 1
    analysisTask?.cancel()
    renderTask?.cancel()
    reset()
  }

  func retryCurrentSource() {
    guard let sourceURL else { return }
    analyze(sourceURL)
  }

  // MARK: - render

  func shuffleStyle() {
    seedBump &+= 1
    rerender()
    scheduleProjectSnapshotSave(immediate: true)
  }

  /// Flushes the latest semantic state when the app leaves the foreground.
  /// The write still runs away from the main actor, but bypasses the page-scroll debounce.
  func persistProjectForLifecycleTransition() {
    scheduleProjectSnapshotSave(immediate: true)
  }

  private func rerender() {
    guard let document else { return }
    let style = style
    let name = sourceName
    let gen = generation
    renderRevision += 1
    let revision = renderRevision
    readingPages = Self.makeReadingPages(document, format: presentationFormat)
    if phase != .analyzing, !pages.isEmpty {
      isUpdatingStyle = true
    } else if phase != .analyzing {
      phase = .illustrating
    }
    stageText = String(localized: "Composing your notes")
    scanProgress = nil
    stageIndex = 3
    renderTask?.cancel()
    renderTask = Task.detached(priority: .userInitiated) { [weak self] in
      let renderer = PlainNotesRenderer()
      // PageMetrics is already 1080×1920. Rendering at 1× keeps a
      // ten-page iPhone project near 83 MB instead of ~332 MB while the
      // PDF remains vector-resolution independent.
      let images = renderer.renderImages(document: document, style: style, scale: 1)
      guard !Task.isCancelled else { return }
      guard !images.isEmpty else {
        await self?.publishRenderFailure(
          String(localized: "One or more note pages could not be rendered."), generation: gen,
          revision: revision)
        return
      }
      let pdf = renderer.renderPDF(document: document, style: style)
      guard !Task.isCancelled else { return }
      guard !pdf.isEmpty else {
        await self?.publishRenderFailure(
          String(localized: "The PDF could not be generated."), generation: gen,
          revision: revision)
        return
      }
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("VideoNotes", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let localizedStem = String(localized: "\(name.isEmpty ? "VideoNotes" : name) — Sketchnotes")
      let pdfURL = folder.appendingPathComponent("\(localizedStem).pdf")
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try pdf.write(to: pdfURL, options: .atomic)
      } catch {
        try? FileManager.default.removeItem(at: folder)
        await self?.publishRenderFailure(
          String(localized: "The rendered notes could not be saved: \(error.localizedDescription)"),
          generation: gen, revision: revision)
        return
      }
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self, self.generation == gen, self.renderRevision == revision,
          !Task.isCancelled
        else { return }
        let previousPDF = self.pdfURL
        self.pages = images
        self.pdfURL = pdfURL
        let boundedPage = min(self.currentPage, max(0, images.count - 1))
        if self.currentPage != boundedPage { self.currentPage = boundedPage }
        self.phase = .ready
        self.isUpdatingStyle = false
        self.stageText = ""
        if let previousPDF, previousPDF != pdfURL {
          try? FileManager.default.removeItem(at: previousPDF.deletingLastPathComponent())
        }
        #if DEBUG
          if let dir = ProcessInfo.processInfo.environment["VIDEONOTES_AUTO_PNG"] {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            for (i, image) in images.enumerated() {
              try? PageRenderer.pngData(image).write(
                to: base.appendingPathComponent("page-\(i + 1).png"))
            }
            try? pdf.write(to: base.appendingPathComponent("notes.pdf"))
          }
        #endif
      }
    }
  }

  private func publishRenderFailure(_ message: String, generation: Int, revision: Int) {
    guard self.generation == generation, renderRevision == revision else { return }
    isUpdatingStyle = false
    stageText = ""
    if pages.isEmpty {
      phase = .failed(message)
    } else {
      phase = .ready
      publishSessionNotice(message)
    }
  }

  // MARK: - export

  func pdfData() -> Data? {
    guard isExportReady, let pdfURL else { return nil }
    return try? Data(contentsOf: pdfURL)
  }

  func semanticNotes(format: SemanticNoteExportFormat) -> Data? {
    guard let document else { return nil }
    return SemanticNoteExporter.make(
      format: format, document: document, sourceName: sourceName,
      presentationFormat: presentationFormat,
      evidenceCoverage: groundingReport?.citationLabel
        ?? String(localized: "Evidence coverage unavailable"))
  }

  /// Write page PNGs into a user-chosen folder (security-scoped).
  func exportPNGs(to folder: URL) throws {
    guard isExportReady else { throw StudioExportError.renderInProgress }
    let access = folder.startAccessingSecurityScopedResource()
    defer { if access { folder.stopAccessingSecurityScopedResource() } }
    let stem = sourceName.isEmpty ? "notes" : sourceName
    let manager = FileManager.default
    let localizedStem = String(localized: "\(stem) — Sketchnotes")
    var destination = folder.appendingPathComponent(localizedStem, isDirectory: true)
    var suffix = 2
    while manager.fileExists(atPath: destination.path) {
      destination = folder.appendingPathComponent(
        "\(localizedStem) \(suffix)", isDirectory: true)
      suffix += 1
    }
    try manager.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
      for (i, image) in pages.enumerated() {
        let data = PageRenderer.pngData(image)
        guard !data.isEmpty else { throw StudioExportError.pngEncodingFailed }
        try data.write(
          to: destination.appendingPathComponent("page-\(i + 1).png"), options: .atomic)
      }
    } catch {
      try? manager.removeItem(at: destination)
      throw error
    }
  }

  enum StudioExportError: LocalizedError {
    case pngEncodingFailed
    case renderInProgress
    var errorDescription: String? {
      switch self {
      case .pngEncodingFailed:
        return String(localized: "A note page could not be encoded as PNG.")
      case .renderInProgress:
        return String(localized: "Wait for the current note format to finish rendering.")
      }
    }
  }

  func reset() {
    analysisTask?.cancel()
    renderTask?.cancel()
    renderRevision += 1
    removeTemporaryPDF()
    phase = .empty
    pages = []
    pdfURL = nil
    document = nil
    extractedContent = nil
    sourceReference = nil
    sourceName = ""
    stageText = ""
    transcriptNotice = nil
    groundingReport = nil
    sourceEvidence = []
    sourceURL = nil
    failureCanOpenSettings = false
    isUpdatingStyle = false
    readingPages = []
    sessionNotice = nil
    currentPage = 0
    clearPersistedProject()
  }

  private func removeTemporaryPDF() {
    guard let pdfURL else { return }
    try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent())
  }

  enum CorrectionError: LocalizedError {
    case empty
    case stale
    var errorDescription: String? {
      switch self {
      case .empty: return String(localized: "Evidence text cannot be empty.")
      case .stale: return String(localized: "This evidence item is no longer available.")
      }
    }
  }

  /// Apply a human correction to OCR or speech evidence, rebuild the note
  /// model from that corrected source, and rerender without re-scanning.
  func applyCorrection(to item: EvidenceItem, text: String) throws {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { throw CorrectionError.empty }
    guard var content = extractedContent,
      let index = Int(item.id.split(separator: "-").last ?? "")
    else { throw CorrectionError.stale }

    switch item.kind {
    case .speech:
      guard content.transcript.indices.contains(index) else { throw CorrectionError.stale }
      content.transcript[index].text = cleaned
    case .visual:
      guard content.visuals.indices.contains(index) else { throw CorrectionError.stale }
      let lines = cleaned.split(separator: "\n").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      guard !lines.isEmpty else { throw CorrectionError.empty }
      content.visuals[index].lines = lines
    }

    let rebuilt = try HeuristicStructurer.structure(content)
    extractedContent = content
    document = rebuilt
    groundingReport = Self.makeGroundingReport(document: rebuilt, content: content)
    sourceEvidence = Self.makeEvidence(from: content)
    scheduleProjectSnapshotSave(immediate: true)
    rerender()
  }

  private static func makeGroundingReport(
    document: NoteDocument, content: ExtractedContent
  ) -> GroundingReport {
    let audit = GroundingAuditor.audit(document: document, content: content)
    let heroCount = audit.heroIllustrationPresent ? 1 : 0
    let verifiedHeroCount = audit.heroOpeningMatched ? 1 : 0
    return GroundingReport(
      duration: content.duration,
      transcriptSegments: content.transcript.count,
      visualMoments: content.visuals.count,
      tracedVisuals: content.visuals.filter { !($0.sketch ?? []).isEmpty }.count,
      citedSections: document.sections.filter { $0.sourceTime != nil }.count,
      synthesizedSections: document.sections.filter { $0.sourceTime == nil }.count,
      sourceIllustrations: audit.illustratedSections + heroCount,
      verifiedSourceIllustrations: audit.temporallyAlignedIllustrations + verifiedHeroCount)
  }

  private static func makeEvidence(from content: ExtractedContent) -> [EvidenceItem] {
    let speech = content.transcript.enumerated().map { index, segment in
      EvidenceItem(
        id: "speech-\(index)", kind: .speech, time: segment.start,
        title: String(localized: "Spoken at \(TimeFormat.mmss(segment.start))"),
        detail: segment.text, hasTrace: false)
    }
    let visuals = content.visuals.enumerated().map { index, moment in
      let hasTrace = !((moment.sketch ?? []).isEmpty)
      let lines = moment.lines.joined(separator: "\n")
      return EvidenceItem(
        id: "visual-\(index)", kind: .visual, time: moment.time,
        title: String(localized: "Key scene at \(TimeFormat.mmss(moment.time))"),
        detail: lines.isEmpty
          ? String(localized: "Visual scene retained from the source video.") : lines,
        hasTrace: hasTrace)
    }
    return (speech + visuals).sorted { lhs, rhs in
      lhs.time == rhs.time ? lhs.kind.rawValue < rhs.kind.rawValue : lhs.time < rhs.time
    }
  }

  private static func makeReadingPages(
    _ document: NoteDocument,
    format: NotePresentationFormat
  ) -> [ReadingPage] {
    PagePlanner.plan(document, format: format).enumerated().map { index, page in
      switch page {
      case .hero(let title, let subtitle, _, _):
        return ReadingPage(
          id: index, title: title, detail: subtitle ?? String(localized: "Cover page"),
          sourceTimes: [])
      case .single(let section):
        let text = readingText(for: section)
        return ReadingPage(
          id: index, title: section.heading, detail: text,
          sourceTimes: [section.sourceTime].compactMap { $0 })
      case .pair(let first, let second):
        return ReadingPage(
          id: index, title: "\(first.heading) · \(second.heading)",
          detail: readingText(for: first) + "\n\n" + readingText(for: second),
          sourceTimes: [first.sourceTime, second.sourceTime].compactMap { $0 })
      }
    }
  }

  private static func readingText(for section: NoteSection) -> String {
    switch section {
    case .concept(_, let body, let points, _, let quote, _, _):
      return ([body].compactMap { $0 } + points + [quote].compactMap { $0 }).joined(separator: "\n")
    case .methods(_, let columns, _):
      return columns.map { column in
        ([column.title, column.tagline, column.summary].compactMap { $0 } + column.steps).joined(
          separator: "\n")
      }.joined(separator: "\n\n")
    case .process(_, let steps, _, _, _): return steps.joined(separator: "\n")
    case .comparison(_, let leftTitle, let leftPoints, let rightTitle, let rightPoints, _, _):
      return ([leftTitle] + leftPoints + [rightTitle] + rightPoints).joined(separator: "\n")
    case .quote(let text, let attribution, _):
      return text + (attribution.map { "\n— \($0)" } ?? "")
    case .definition(_, let meaning, _): return meaning
    case .summary(_, let points, _): return points.joined(separator: "\n")
    }
  }

  // MARK: - private on-device recovery

  private func restoreSavedProject() {
    do {
      guard let snapshot = try snapshotStore.load() else { return }
      isRestoringSnapshot = true
      document = snapshot.document
      extractedContent = snapshot.content.extractedContent
      sourceName = snapshot.sourceName
      baseSeed = snapshot.baseSeed
      seedBump = snapshot.style.seedBump
      paletteIndex = snapshot.style.paletteIndex
      compact = snapshot.style.compact
      presentationFormat =
        NotePresentationFormat(rawValue: snapshot.style.presentationFormat) ?? .illustrated
      pdfPageFormat = PDFPageFormat(rawValue: snapshot.style.pdfPageFormat) ?? .digital
      transcriptNotice = snapshot.content.transcriptUnavailableReason.map(
        Self.localizedEngineMessage)
      groundingReport = Self.makeGroundingReport(
        document: snapshot.document, content: snapshot.content.extractedContent)
      sourceEvidence = Self.makeEvidence(from: snapshot.content.extractedContent)
      sourceReference = snapshot.sourceReference
      failureCanOpenSettings = false
      pages = []
      pdfURL = nil
      isUpdatingStyle = false
      let restoredPageCount = PagePlanner.plan(
        snapshot.document, format: presentationFormat
      ).count
      currentPage = min(snapshot.currentPage, max(0, restoredPageCount - 1))
      phase = .illustrating
      stageText = String(localized: "Restoring your notes")
      stageIndex = 3
      scanProgress = nil

      var shouldRefreshBookmark = false
      switch snapshot.sourceReference?.resolve() ?? .unavailable {
      case .available(let url, let bookmarkWasStale):
        sourceURL = url
        shouldRefreshBookmark = bookmarkWasStale
        if bookmarkWasStale {
          let access = url.startAccessingSecurityScopedResource()
          sourceReference = ProjectSourceReference(url: url)
          if access { url.stopAccessingSecurityScopedResource() }
        }
        publishSessionNotice(
          String(
            localized: "Restored “\(snapshot.sourceName)” from your private on-device autosave."),
          success: true)
      case .unavailable:
        sourceURL = nil
        publishSessionNotice(
          String(
            localized:
              "Restored “\(snapshot.sourceName)” from the private on-device autosave. The original media is no longer available at its saved location, so source preview and re-analysis are unavailable; the generated notes and extracted evidence remain usable."
          )
        )
      }

      isRestoringSnapshot = false
      rerender()
      if shouldRefreshBookmark { scheduleProjectSnapshotSave(immediate: true) }
    } catch {
      isRestoringSnapshot = false
      let snapshotError = error as? ProjectSnapshotError
      if snapshotError?.shouldQuarantineSnapshot ?? true {
        snapshotStore.quarantineUnreadableSnapshot()
        let reason =
          snapshotError?.localizedDescription
          ?? String(localized: "its recovery data could not be read")
        publishSessionNotice(
          String(
            localized:
              "A damaged or incompatible local autosave was found (\(reason)). It was set aside, and VideoNotes opened a new workspace; no source media was changed."
          )
        )
      } else {
        let reason =
          snapshotError?.localizedDescription
          ?? String(localized: "The private recovery key is unavailable.")
        publishSessionNotice(
          String(
            localized:
              "\(reason) The encrypted autosave was kept safely in place so VideoNotes can try again later."
          )
        )
      }
    }
  }

  private func makeProjectSnapshot() -> ProjectSnapshot? {
    guard let document, let extractedContent else { return nil }
    return ProjectSnapshot(
      sourceName: sourceName, sourceReference: sourceReference, document: document,
      content: extractedContent, baseSeed: baseSeed,
      style: ProjectSnapshot.Style(
        paletteIndex: paletteIndex, compact: compact,
        presentationFormat: presentationFormat.rawValue,
        pdfPageFormat: pdfPageFormat.rawValue, seedBump: seedBump),
      currentPage: currentPage)
  }

  private func scheduleProjectSnapshotSave(immediate: Bool = false) {
    guard !isRestoringSnapshot, let snapshot = makeProjectSnapshot() else { return }
    snapshotRevision += 1
    let revision = snapshotRevision
    let persistence = snapshotPersistence
    snapshotSaveTask?.cancel()
    snapshotSaveTask = Task { [weak self] in
      if !immediate {
        do {
          try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
          return
        }
      }
      guard !Task.isCancelled else { return }
      do {
        try await persistence.save(snapshot, revision: revision)
        guard !Task.isCancelled else { return }
        self?.didReportSnapshotWriteFailure = false
      } catch {
        guard !Task.isCancelled else { return }
        self?.publishSnapshotWriteFailure()
      }
    }
  }

  private func clearPersistedProject() {
    snapshotSaveTask?.cancel()
    snapshotRevision += 1
    let revision = snapshotRevision
    let persistence = snapshotPersistence
    Task { [weak self] in
      do {
        try await persistence.remove(revision: revision)
      } catch {
        if case .encryptionKeyUnavailable = error as? ProjectSnapshotError {
          self?.publishSessionNotice(
            String(
              localized:
                "The workspace recovery files were removed, but their private Keychain encryption key could not be retired. No recovery data was recreated."
            )
          )
        } else {
          self?.publishSessionNotice(
            String(
              localized:
                "The workspace was cleared, but its private local recovery file could not be removed. Check available storage and file permissions before using a shared device."
            )
          )
        }
      }
    }
  }

  private func publishSnapshotWriteFailure() {
    guard !didReportSnapshotWriteFailure else { return }
    didReportSnapshotWriteFailure = true
    publishSessionNotice(
      String(
        localized:
          "Your notes are ready, but their private on-device recovery copy could not be updated. Check available storage before closing VideoNotes."
      )
    )
  }

  private func publishSessionNotice(_ message: String, success: Bool = false) {
    sessionNoticeIsSuccess = success
    sessionNotice = message
  }

  private static func localizedPipelineMessage(stage: PipelineStage, message: String) -> String {
    switch stage {
    case .probing:
      let filename = message.removing(prefix: "Opening ") ?? message
      return String(localized: "Opening \(filename)")
    case .transcribing:
      let duration =
        message.removing(prefix: "Transcribing ")?
        .removing(suffix: " of audio on device") ?? message
      return String(localized: "Transcribing \(duration) of audio on device")
    case .preparingModel:
      return String(
        localized: "Preparing the on-device speech engine (one-time download, may take a few minutes)"
      )
    case .scanning:
      if let counts = message.integerPair(after: "Finding meaningful scenes ") {
        return String(localized: "Finding meaningful scenes \(counts.first) of \(counts.second)")
      }
      if let counts = message.integerPair(after: "Reading key scene ") {
        return String(localized: "Reading key scene \(counts.first) of \(counts.second)")
      }
      if let count = message.integer(after: "Finished reading ", before: " distinct scenes") {
        return String(localized: "Finished reading \(count) distinct scenes")
      }
      return message
    case .structuring:
      return String(localized: "Structuring the notes")
    case .illustrating:
      return String(localized: "Composing your notes")
    }
  }

  private static func localizedEngineMessage(_ message: String) -> String {
    switch message {
    case "The selected file has no readable audio or video.":
      return String(localized: "The selected file has no readable audio or video.")
    case "No spoken words or on-screen text could be found in this file.":
      return String(localized: "No spoken words or on-screen text could be found in this file.")
    case "Speech recognition permission was not granted, so only on-screen text was used.":
      return String(
        localized:
          "Speech recognition permission was not granted, so only on-screen text was used.")
    case "Speech recognition is not available on this device.":
      return String(localized: "Speech recognition is not available on this device.")
    case "Transcription was cancelled.":
      return String(localized: "Transcription was cancelled.")
    default:
      if let locale = message.removing(
        prefix: "On-device speech recognition is not available for ")?
        .removing(suffix: "; only on-screen text was used.")
      {
        return String(
          localized:
            "On-device speech recognition is not available for \(locale); only on-screen text was used."
        )
      }
      if let locale = message.removing(prefix: "Speech recognition is not available for ")?
        .removing(suffix: "; only on-screen text was used.")
      {
        return String(
          localized:
            "On-device speech recognition is not available for \(locale); only on-screen text was used."
        )
      }
      if let detail = message.removing(prefix: "Transcription failed: ") {
        return String(localized: "Transcription failed: \(detail)")
      }
      return message
    }
  }

  // MARK: - debug hooks

  func applyDebugHooksOnLaunch() {
    #if DEBUG
      if ProcessInfo.processInfo.environment["VIDEONOTES_UI_TEST_FIXTURE"] == "completed",
        phase == .empty
      {
        loadDebugFixture()
        return
      }
      if let auto = ProcessInfo.processInfo.environment["VIDEONOTES_AUTO"], phase == .empty {
        analyze(URL(fileURLWithPath: auto))
      }
    #endif
  }

  #if DEBUG
    private func loadDebugFixture() {
      let sourceTrace = [
        SketchStroke(points: [
          CGPoint(x: 0.12, y: 0.24), CGPoint(x: 0.48, y: 0.20),
          CGPoint(x: 0.84, y: 0.24),
        ]),
        SketchStroke(points: [
          CGPoint(x: 0.18, y: 0.43), CGPoint(x: 0.50, y: 0.58),
          CGPoint(x: 0.82, y: 0.43),
        ]),
        SketchStroke(points: [
          CGPoint(x: 0.24, y: 0.74), CGPoint(x: 0.50, y: 0.66),
          CGPoint(x: 0.76, y: 0.74),
        ]),
      ]
      let content = ExtractedContent(
        sourceName: "Grounded AI Lecture", duration: 96,
        transcript: [
          TranscriptSegment(
            start: 4, end: 10,
            text: "Training examples teach a model the relationship between inputs and outputs."),
          TranscriptSegment(
            start: 25, end: 34,
            text: "Split the examples into training and validation sets before evaluation."),
          TranscriptSegment(
            start: 48, end: 57,
            text: "Validation measures generalization on examples the model did not train on."),
          TranscriptSegment(
            start: 73, end: 82,
            text: "Review errors, improve representative data, and repeat the evaluation."),
        ],
        visuals: [
          VisualMoment(
            time: 6, lines: ["Inputs", "Training examples", "Outputs"],
            sketch: sourceTrace),
          VisualMoment(time: 50, lines: ["Training set", "Validation set", "Evaluate"]),
        ])
      let fixture = NoteDocument(
        title: "Grounded AI Lecture", subtitle: "A source-cited workflow",
        sections: [
          .concept(
            heading: "Examples connect inputs and outputs",
            body: "Training examples demonstrate the relationship the model should learn.",
            points: ["Use representative examples", "Keep the desired output explicit"],
            iconHints: ["link", "tray.full"], quote: nil, sourceTime: 4,
            sketch: sourceTrace),
          .process(
            heading: "Build an evaluation split",
            steps: ["Collect examples", "Create training and validation sets", "Evaluate"],
            iconHints: ["square.split.2x1", "checkmark.seal"], sourceTime: 25),
          .comparison(
            heading: "Training and validation",
            leftTitle: "Training", leftPoints: ["Examples used to learn"],
            rightTitle: "Validation", rightPoints: ["Unseen examples test generalization"],
            sourceTime: 48),
          .summary(
            heading: "Repeat with evidence",
            points: ["Review errors", "Improve representative data", "Evaluate again"],
            sourceTime: 73),
        ], heroSketch: sourceTrace)

      document = fixture
      extractedContent = content
      sourceName = content.sourceName
      sourceURL = nil
      sourceReference = nil
      baseSeed = 2_026
      seedBump = 0
      transcriptNotice = nil
      groundingReport = Self.makeGroundingReport(document: fixture, content: content)
      sourceEvidence = Self.makeEvidence(from: content)
      failureCanOpenSettings = false
      pages = []
      pdfURL = nil
      readingPages = []
      sessionNotice = nil
      currentPage = 0
      phase = .illustrating
      stageText = "Preparing UI test notes"
      stageIndex = 3
      scanProgress = nil
      // UI relaunch tests terminate the process immediately after rendering.
      // Persist the deterministic fixture synchronously so the test exercises
      // recovery itself instead of racing the production autosave task.
      if let snapshot = makeProjectSnapshot() {
        do {
          try snapshotStore.save(snapshot)
        } catch {
          NSLog("VideoNotes UI fixture recovery save failed: %@", error.localizedDescription)
        }
      }
      rerender()
    }
  #endif
}

extension String {
  fileprivate func removing(prefix: String) -> String? {
    guard hasPrefix(prefix) else { return nil }
    return String(dropFirst(prefix.count))
  }

  fileprivate func removing(suffix: String) -> String? {
    guard hasSuffix(suffix) else { return nil }
    return String(dropLast(suffix.count))
  }

  fileprivate func integerPair(after prefix: String) -> (first: Int, second: Int)? {
    guard let remainder = removing(prefix: prefix) else { return nil }
    let parts = remainder.components(separatedBy: " of ")
    guard parts.count == 2, let first = Int(parts[0]), let second = Int(parts[1]) else {
      return nil
    }
    return (first, second)
  }

  fileprivate func integer(after prefix: String, before suffix: String) -> Int? {
    removing(prefix: prefix)?.removing(suffix: suffix).flatMap(Int.init)
  }
}
