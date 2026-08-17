import AVFoundation
import Foundation
import Speech
import Vision

public struct TranscriptSegment: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  public var text: String
  public init(start: Double, end: Double, text: String) {
    self.start = start
    self.end = end
    self.text = text
  }
}

public struct VisualMoment: Codable, Equatable, Sendable {
  public var time: Double
  public var lines: [String]
  /// Traced line drawing of the actual frame (normalized strokes).
  public var sketch: [SketchStroke]?
  public init(time: Double, lines: [String], sketch: [SketchStroke]? = nil) {
    self.time = time
    self.lines = lines
    self.sketch = sketch
  }
}

public struct ExtractedContent: Sendable {
  public var sourceName: String
  public var duration: Double
  public var transcript: [TranscriptSegment]
  public var visuals: [VisualMoment]
  public var transcriptUnavailableReason: String?
  public init(
    sourceName: String, duration: Double, transcript: [TranscriptSegment],
    visuals: [VisualMoment], transcriptUnavailableReason: String? = nil
  ) {
    self.sourceName = sourceName
    self.duration = duration
    self.transcript = transcript
    self.visuals = visuals
    self.transcriptUnavailableReason = transcriptUnavailableReason
  }
}

public enum ExtractError: LocalizedError {
  case invalidMedia
  case noContent
  case transcriptionUnavailable(String)
  public var errorDescription: String? {
    switch self {
    case .invalidMedia: return "The selected file has no readable audio or video."
    case .noContent: return "No spoken words or on-screen text could be found in this file."
    case .transcriptionUnavailable(let reason): return reason
    }
  }
}

public struct MediaInfo: Sendable {
  public var duration: Double
  public var hasVideo: Bool
  public var hasAudio: Bool
  /// BCP-47 language metadata carried by the primary audio track, when the
  /// source container provides it.
  public var languageTag: String?
}

public enum MediaProbe {
  public static func probe(url: URL) async throws -> MediaInfo {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0 else { throw ExtractError.invalidMedia }
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    guard !video.isEmpty || !audio.isEmpty else { throw ExtractError.invalidMedia }
    let languageTag: String?
    if let primaryAudio = audio.first {
      languageTag = try? await primaryAudio.load(.extendedLanguageTag)
    } else {
      languageTag = nil
    }
    return MediaInfo(
      duration: duration, hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty,
      languageTag: languageTag)
  }
}

// MARK: - Transcription (on-device only; audio never leaves the machine)

/// Coarse state the transcriber reports back to the UI while it works.
public enum TranscriptionProgress: Sendable {
  /// Recognition is actively producing results.
  case transcribing
  /// No results have arrived yet and enough time has passed that the OS is
  /// almost certainly performing the one-time on-device speech-model
  /// download. Surfacing this lets the UI stop pretending it is "transcribing"
  /// and tell the user an install is happening.
  case preparingModel
}

public enum Transcriber {
  /// Best-effort on-device transcription. Returns segments, or nil with a
  /// human-readable reason when transcription cannot run (no permission,
  /// no on-device model). Never sends audio to a server.
  ///
  /// `onProgress` fires with `.preparingModel` when the first recognition
  /// callback has not arrived within a grace window (the OS is downloading the
  /// on-device model on first use), and `.transcribing` once results flow. A
  /// watchdog guarantees this call always returns — it can never hang forever
  /// even if the model download stalls.
  public static func transcribe(
    url: URL, locale: Locale = .current,
    onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
  ) async -> (
    segments: [TranscriptSegment]?, reason: String?
  ) {
    let status = await requestAuthorization()
    guard status == .authorized else {
      return (
        nil, "Speech recognition permission was not granted, so only on-screen text was used."
      )
    }
    let supportedLocales = SFSpeechRecognizer.supportedLocales()
    guard let recognitionLocale = recognitionLocale(requested: locale, supported: supportedLocales)
    else {
      return (
        nil,
        "Speech recognition is not available for \(locale.identifier); only on-screen text was used."
      )
    }
    guard let recognizer = SFSpeechRecognizer(locale: recognitionLocale), recognizer.isAvailable
    else {
      return (nil, "Speech recognition is not available on this device.")
    }
    guard recognizer.supportsOnDeviceRecognition else {
      return (
        nil,
        "On-device speech recognition is not available for \(recognitionLocale.identifier); only on-screen text was used."
      )
    }
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    // Partial results give the watchdog a heartbeat, so it can tell a slow
    // first-run model download (no callbacks at all) apart from active
    // recognition (callbacks flowing). Finals are still collected as before.
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    request.taskHint = .dictation

    let cancellation = SpeechCancellationBox()
    let monitor = ActivityMonitor()
    do {
      let segments: [TranscriptSegment] = try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
          group.addTask {
            try await withCheckedThrowingContinuation { continuation in
              let collector = TranscriptionCollector(continuation: continuation, monitor: monitor)
              let task = recognizer.recognitionTask(with: request, delegate: collector)
              collector.retain(task: task)
              cancellation.install(task)
            }
          }
          group.addTask {
            try await watchdog(monitor: monitor, onProgress: onProgress)
          }
          // Whichever finishes first wins: recognition returns segments, or the
          // watchdog throws a timeout. Either way the other task is torn down.
          let first = try await group.next()!
          group.cancelAll()
          cancellation.cancel()
          return first
        }
      } onCancel: {
        cancellation.cancel()
      }
      return (segments.sorted { $0.start < $1.start }, nil)
    } catch let timeout as TranscriptionTimeout {
      cancellation.cancel()
      return (nil, timeout.reason)
    } catch {
      if error is CancellationError || Task.isCancelled {
        return (nil, "Transcription was cancelled.")
      }
      return (nil, "Transcription failed: \(error.localizedDescription)")
    }
  }

  /// Monitors the recognition heartbeat and guarantees the transcribe call
  /// terminates. Never returns normally — it either keeps waiting or throws.
  private static func watchdog(
    monitor: ActivityMonitor, onProgress: (@Sendable (TranscriptionProgress) -> Void)?
  ) async throws -> [TranscriptSegment] {
    let firstResultGrace: TimeInterval = 18  // no callback within this → likely model download
    let maxPrepareWait: TimeInterval = 15 * 60  // hard ceiling: never hang forever
    let stallTimeout: TimeInterval = 120  // callbacks started then went silent → stalled
    let start = Date()
    var announcedPreparing = false
    while true {
      try await Task.sleep(nanoseconds: 2_000_000_000)
      let snapshot = await monitor.snapshot()
      let now = Date()
      if snapshot.started {
        if announcedPreparing {
          onProgress?(.transcribing)
          announcedPreparing = false
        }
        if now.timeIntervalSince(snapshot.lastActivity) > stallTimeout {
          throw TranscriptionTimeout.stalled
        }
      } else {
        if !announcedPreparing, now.timeIntervalSince(start) > firstResultGrace {
          announcedPreparing = true
          onProgress?(.preparingModel)
        }
        if now.timeIntervalSince(start) > maxPrepareWait {
          throw TranscriptionTimeout.preparingTimedOut
        }
      }
    }
  }

  enum TranscriptionTimeout: Error {
    case preparingTimedOut
    case stalled
    var reason: String {
      switch self {
      case .preparingTimedOut:
        return
          "The on-device speech model is still downloading. Please stay connected to the internet and try again in a few minutes."
      case .stalled:
        return "Transcription stopped unexpectedly. Please try again."
      }
    }
  }

  /// Tracks the last time the recognition task produced any output, so the
  /// watchdog can distinguish "downloading model" from "actively working".
  private actor ActivityMonitor {
    struct Snapshot: Sendable {
      var started: Bool
      var lastActivity: Date
    }
    private var started = false
    private var lastActivity = Date()
    func touch() {
      started = true
      lastActivity = Date()
    }
    func snapshot() -> Snapshot { Snapshot(started: started, lastActivity: lastActivity) }
  }

  /// Select an exact locale when possible, otherwise a deterministic locale
  /// in the same language family. A German, French, or other non-English
  /// request is never silently routed through an English recognizer.
  static func recognitionLocale(requested: Locale, supported: Set<Locale>) -> Locale? {
    let normalizedRequested = normalizedLocaleIdentifier(requested.identifier)
    if let exact = supported.first(where: {
      normalizedLocaleIdentifier($0.identifier) == normalizedRequested
    }) {
      return exact
    }

    guard let languageCode = requested.language.languageCode?.identifier.lowercased(),
      languageCode != "und"
    else { return nil }
    let sameLanguage = supported.filter {
      $0.language.languageCode?.identifier.lowercased() == languageCode
    }
    guard !sameLanguage.isEmpty else { return nil }

    let preferredIdentifier: String?
    switch languageCode {
    case "de": preferredIdentifier = "de-DE"
    case "en": preferredIdentifier = "en-US"
    default: preferredIdentifier = nil
    }
    if let preferredIdentifier,
      let preferred = sameLanguage.first(where: {
        normalizedLocaleIdentifier($0.identifier)
          == normalizedLocaleIdentifier(preferredIdentifier)
      })
    {
      return preferred
    }
    return sameLanguage.sorted {
      normalizedLocaleIdentifier($0.identifier) < normalizedLocaleIdentifier($1.identifier)
    }.first
  }

  /// Explicit user intent wins, followed by valid audio-track language
  /// metadata and finally the device language. Invalid/undefined container
  /// tags never displace the device fallback.
  static func preferredLocale(
    requested: Locale?, sourceLanguageTag: String?, deviceLocale: Locale = .current
  ) -> Locale {
    if let requested { return requested }
    if let sourceLanguageTag {
      let normalized = sourceLanguageTag.replacingOccurrences(of: "_", with: "-")
      let languageSubtag = normalized.split(separator: "-", maxSplits: 1).first.map(String.init)
      if let languageSubtag,
        (2...3).contains(languageSubtag.count),
        languageSubtag.allSatisfy(\.isLetter),
        !["mul", "und", "zxx"].contains(languageSubtag.lowercased())
      {
        return Locale(identifier: normalized)
      }
    }
    return deviceLocale
  }

  private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
    identifier.replacingOccurrences(of: "_", with: "-").lowercased()
  }

  private final class SpeechCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    func install(_ task: SFSpeechRecognitionTask) {
      lock.lock()
      self.task = task
      let shouldCancel = cancelled
      lock.unlock()
      if shouldCancel { task.cancel() }
    }
    func cancel() {
      lock.lock()
      cancelled = true
      let task = task
      lock.unlock()
      task?.cancel()
    }
  }

  private final class TranscriptionCollector: NSObject, SFSpeechRecognitionTaskDelegate,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var finals: [TranscriptSegment] = []
    private var task: SFSpeechRecognitionTask?
    private var selfRetain: TranscriptionCollector?
    private let monitor: ActivityMonitor

    init(continuation: CheckedContinuation<[TranscriptSegment], Error>, monitor: ActivityMonitor) {
      self.continuation = continuation
      self.monitor = monitor
      super.init()
      selfRetain = self
    }
    func retain(task: SFSpeechRecognitionTask) {
      lock.lock()
      self.task = task
      lock.unlock()
    }

    // Any partial hypothesis is a heartbeat: recognition is running, not
    // stuck downloading the model.
    func speechRecognitionTask(
      _ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription
    ) {
      let monitor = monitor
      Task { await monitor.touch() }
    }

    func speechRecognitionTask(
      _ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult
    ) {
      let segments = Transcriber.sentences(from: result.bestTranscription)
      lock.lock()
      finals.append(contentsOf: segments)
      lock.unlock()
      let monitor = monitor
      Task { await monitor.touch() }
    }
    func speechRecognitionTask(
      _ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool
    ) {
      lock.lock()
      guard let continuation else {
        lock.unlock()
        return
      }
      self.continuation = nil
      let finals = finals
      selfRetain = nil
      self.task = nil
      lock.unlock()
      if successfully || !finals.isEmpty {
        continuation.resume(returning: finals)
      } else {
        continuation.resume(throwing: task.error ?? ScanFailure.recognitionFailed)
      }
    }
    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
      lock.lock()
      let continuation = continuation
      self.continuation = nil
      let finals = finals
      selfRetain = nil
      self.task = nil
      lock.unlock()
      continuation?.resume(returning: finals)
    }
    enum ScanFailure: Error { case recognitionFailed }
  }

  private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
      return SFSpeechRecognizer.authorizationStatus()
    }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  /// Group word-level segments into sentence-level TranscriptSegments on
  /// punctuation and pauses.
  static func sentences(from transcription: SFTranscription) -> [TranscriptSegment] {
    var out: [TranscriptSegment] = []
    var words: [SFTranscriptionSegment] = []
    func flush() {
      guard let first = words.first, let last = words.last else { return }
      let text = words.map(\.substring).joined(separator: " ")
        .replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ,", with: ",")
        .replacingOccurrences(of: " ?", with: "?").replacingOccurrences(of: " !", with: "!")
      out.append(
        TranscriptSegment(
          start: first.timestamp,
          end: last.timestamp + last.duration,
          text: text))
      words = []
    }
    for seg in transcription.segments {
      if let prev = words.last, seg.timestamp - (prev.timestamp + prev.duration) > 1.6 { flush() }
      words.append(seg)
      if seg.substring.hasSuffix(".") || seg.substring.hasSuffix("?")
        || seg.substring.hasSuffix("!")
      {
        flush()
      }
      if words.count >= 40 { flush() }  // runaway sentence guard
    }
    flush()
    return out
  }

  /// DEBUG/test injection format: lines of `start|end|text`.
  public static func parseInjected(_ raw: String) -> [TranscriptSegment] {
    raw.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "|", maxSplits: 2)
      guard parts.count == 3, let s = Double(parts[0]), let e = Double(parts[1]) else { return nil }
      return TranscriptSegment(
        start: s, end: e, text: String(parts[2]).trimmingCharacters(in: .whitespaces))
    }
  }
}

// MARK: - Keyframe sampling + OCR

public enum FrameSampler {
  /// Find scene changes cheaply, then run expensive OCR and contour tracing
  /// only on the most representative frames. This keeps long lectures
  /// accurate without treating a two-hour recording as 48 arbitrary stills.
  public static func visualMoments(
    url: URL, duration: Double,
    contextualWords: [String] = [],
    progress: @escaping @Sendable (Double, String) -> Void
  ) -> [VisualMoment] {
    let asset = AVURLAsset(url: url)
    let probe = configuredGenerator(asset: asset, maximumSize: CGSize(width: 192, height: 120))

    // Pass 1 is intentionally tiny: inspect roughly every six seconds
    // (up to 600 probes) and score actual visual change. The larger cap
    // prevents long lectures from silently missing short-lived slides.
    let probeCount = min(600, max(12, Int(ceil(duration / 6))))
    var candidates: [(time: Double, hash: UInt64)] = []
    let progressStride = max(1, probeCount / 80)
    for index in 0..<probeCount {
      guard !Task.isCancelled else { return [] }
      if index % progressStride == 0 || index == probeCount - 1 {
        progress(
          Double(index) / Double(max(1, probeCount)) * 0.28,
          "Finding meaningful scenes \(index + 1) of \(probeCount)")
      }
      let second = duration * (Double(index) + 0.5) / Double(probeCount)
      let time = CMTime(seconds: second, preferredTimescale: 600)
      var actualTime = CMTime.invalid
      guard let image = try? probe.copyCGImage(at: time, actualTime: &actualTime) else { continue }
      let resolvedTime = actualTime.isValid ? actualTime.seconds : second
      candidates.append((resolvedTime, FrameSketcher.perceptualHash(image)))
    }

    let detailedLimit = min(120, max(12, Int(ceil(duration / 18))))
    let selected = representativeIndices(candidates.map(\.hash), limit: detailedLimit)
    let generator = configuredGenerator(
      asset: asset, maximumSize: CGSize(width: 1920, height: 1200))

    // Long-GOP videos snap to distant keyframes with the default infinite
    // tolerance; a tight window keeps timestamps honest.
    var candidateMoments: [VisualMoment] = []
    var candidateHashes: [UInt64] = []
    for (position, index) in selected.enumerated() {
      guard !Task.isCancelled else { return [] }
      let fraction = 0.28 + Double(position) / Double(max(1, selected.count)) * 0.72
      progress(fraction, "Reading key scene \(position + 1) of \(selected.count)")
      let second = candidates[index].time
      let time = CMTime(seconds: second, preferredTimescale: 600)
      var actualTime = CMTime.invalid
      guard let image = try? generator.copyCGImage(at: time, actualTime: &actualTime) else {
        continue
      }
      let evidenceTime = actualTime.isValid ? actualTime.seconds : second
      let evidence = recognizeTextEvidence(in: image, contextualWords: contextualWords)
      let lines = evidence.lines
      let dominantFace = hasDominantFace(in: image)
      let tracedSketch = FrameSketcher.trace(image, excludingTextRegions: evidence.regions)
      // Captioned talking heads still contribute OCR, but their faces must
      // never become the page illustration. A sketch is only source art
      // when the retained frame is not face-dominant.
      let sketch: [SketchStroke]? = dominantFace ? nil : tracedSketch

      // Blank transitions and talking heads are not educational art.
      // Textless frames need substantial drawable structure and must
      // not be dominated by a face before they can become evidence.
      if lines.isEmpty {
        guard tracedSketch.count >= 3, !dominantFace else { continue }
      }

      let hash = FrameSketcher.perceptualHash(image)
      // the traced drawing is what makes each page's art THIS video's art
      candidateMoments.append(VisualMoment(time: evidenceTime, lines: lines, sketch: sketch))
      candidateHashes.append(hash)
    }
    let output = deduplicatedVisualMoments(candidateMoments, hashes: candidateHashes)
    progress(1, "Finished reading \(output.count) distinct scenes")
    return output
  }

  /// Deduplicate extracted scenes only when textual and visual evidence
  /// agree. The same title can legitimately appear over different charts,
  /// and a distant prefix-like slide can be an unrelated section.
  static func deduplicatedVisualMoments(_ moments: [VisualMoment], hashes: [UInt64])
    -> [VisualMoment]
  {
    guard moments.count == hashes.count else { return moments }
    var output: [VisualMoment] = []
    var outputHashes: [UInt64] = []

    for (moment, hash) in zip(moments, hashes) {
      if moment.lines.isEmpty {
        guard !outputHashes.contains(where: { FrameSketcher.hammingDistance($0, hash) < 10 })
        else { continue }
        output.append(moment)
        outputHashes.append(hash)
        continue
      }

      let signature = textSignature(moment.lines)
      guard !signature.isEmpty else { continue }

      // An exact OCR signature is only a duplicate when a nearby retained
      // scene is visually the same. This preserves repeated titles used on
      // different diagrams, charts or examples.
      let exactDuplicate = output.indices.reversed().contains { index in
        !output[index].lines.isEmpty
          && moment.time - output[index].time <= 45
          && textSignature(output[index].lines) == signature
          && FrameSketcher.hammingDistance(outputHashes[index], hash) < 8
      }
      if exactDuplicate { continue }

      if let previousIndex = output.indices.last {
        let nearby = moment.time - output[previousIndex].time <= 45
        let visuallySimilar = FrameSketcher.hammingDistance(outputHashes[previousIndex], hash) < 8
        if nearby, visuallySimilar {
          // OCR fluctuates slightly between frames of the same slide.
          if textSimilarity(output[previousIndex].lines, moment.lines) >= 0.92 {
            let previousLength = output[previousIndex].lines.joined().count
            let currentLength = moment.lines.joined().count
            if currentLength > previousLength {
              output[previousIndex] = moment
              outputHashes[previousIndex] = hash
            }
            continue
          }
          // Progressive reveal: only an adjacent, nearby and visually
          // similar fuller frame may replace the previous state.
          if isPrefixLike(previous: output[previousIndex].lines, current: moment.lines) {
            output[previousIndex] = moment
            outputHashes[previousIndex] = hash
            continue
          }
        }
      }

      output.append(moment)
      outputHashes.append(hash)
    }
    return output
  }

  private static func configuredGenerator(asset: AVAsset, maximumSize: CGSize)
    -> AVAssetImageGenerator
  {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumSize
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    return generator
  }

  /// Highest-change frames win, while the opening/closing context is kept.
  /// A minimum index gap prevents animated transitions from consuming the
  /// entire budget. Returned indices are chronological.
  static func representativeIndices(_ hashes: [UInt64], limit: Int) -> [Int] {
    guard !hashes.isEmpty, limit > 0 else { return [] }
    guard hashes.count > limit else { return Array(hashes.indices) }

    var scored = hashes.indices.map { index -> (index: Int, score: Int) in
      let previous =
        index > 0 ? FrameSketcher.hammingDistance(hashes[index], hashes[index - 1]) : 64
      let next =
        index + 1 < hashes.count
        ? FrameSketcher.hammingDistance(hashes[index], hashes[index + 1]) : 64
      return (index, previous + next)
    }
    scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }

    let minimumGap = max(1, hashes.count / max(1, limit * 2))
    var kept: [Int] = [0, hashes.count - 1]
    for candidate in scored where kept.count < limit {
      guard !kept.contains(where: { abs($0 - candidate.index) < minimumGap }) else { continue }
      kept.append(candidate.index)
    }
    if kept.count < limit {
      for index in hashes.indices where kept.count < limit && !kept.contains(index) {
        kept.append(index)
      }
    }
    return Array(kept.prefix(limit)).sorted()
  }

  /// True when `previous` looks like an earlier build state of `current`
  /// (progressively revealed slide).
  static func isPrefixLike(previous: [String], current: [String]) -> Bool {
    guard previous.count < current.count else { return false }
    let overlap = previous.filter { current.contains($0) }.count
    return Double(overlap) >= Double(previous.count) * 0.8
  }

  static func textSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
    func tokens(_ lines: [String]) -> Set<String> {
      Set(
        lines.joined(separator: " ").lowercased()
          .components(separatedBy: CharacterSet.alphanumerics.inverted)
          .filter { $0.count >= 2 }
          .map { word in word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word })
    }
    let a = tokens(lhs)
    let b = tokens(rhs)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    return Double(a.intersection(b).count) / Double(a.union(b).count)
  }

  /// Stable OCR signature that retains mathematical meaning and line
  /// boundaries. "12.3%" must never collapse into "123%", nor "A-B" into
  /// "AB", because those can be different lecture claims.
  static func textSignature(_ lines: [String]) -> String {
    let meaningfulPunctuation = CharacterSet(charactersIn: ".,%+-=×÷/^:()[]")
    return lines.map { line in
      line.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || meaningfulPunctuation.contains($0)
      }.map(String.init).joined()
    }.joined(separator: "|")
  }

  private static func hasDominantFace(in image: CGImage) -> Bool {
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cgImage: image).perform([request])
    let areas = (request.results ?? []).map { $0.boundingBox.width * $0.boundingBox.height }
    return (areas.max() ?? 0) >= 0.12 || areas.reduce(0, +) >= 0.2
  }

  static func recognizeText(in image: CGImage) -> [String] {
    recognizeTextEvidence(in: image, contextualWords: []).lines
  }

  private static func recognizeTextEvidence(
    in image: CGImage,
    contextualWords: [String]
  ) -> (lines: [String], regions: [CGRect]) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    request.customWords = Array(contextualWords.prefix(50))
    try? VNImageRequestHandler(cgImage: image).perform([request])
    let observations = (request.results ?? []).sorted {
      if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
        return $0.boundingBox.midY > $1.boundingBox.midY
      }
      return $0.boundingBox.minX < $1.boundingBox.minX
    }
    var lines: [String] = []
    var regions: [CGRect] = []
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else {
        continue
      }
      let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !isStatusBarNoise(line),
        !isInterfaceChromeNoise(line, contextualWords: contextualWords),
        !lines.contains(line)
      else { continue }
      lines.append(line)
      let box = observation.boundingBox
      regions.append(CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
    }
    return (lines, regions)
  }

  /// Phone/desktop chrome the OCR always sees but notes never want:
  /// clock, battery, carrier and other status-bar debris.
  static func isStatusBarNoise(_ line: String) -> Bool {
    if line.count <= 2 { return true }
    // clock: "14:35", "9:41 AM", "14:35 ⚡"
    if line.range(of: #"^\d{1,2}:\d{2}(\s?(AM|PM|am|pm))?\W*$"#, options: .regularExpression) != nil
    {
      return true
    }
    // battery / signal / carrier fragments
    if line.range(of: #"^\d{1,3}\s?%$"#, options: .regularExpression) != nil { return true }
    let noise = ["5G", "5G+", "5GE", "LTE", "4G", "3G", "wifi", "Wi-Fi", "No SIM", "VPN"]
    if noise.contains(where: { line.caseInsensitiveCompare($0) == .orderedSame }) { return true }
    // symbol-only lines (signal bars, battery glyphs misread)
    if line.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return true }
    return false
  }

  /// Exclude incomplete file-browser/navigation chrome that can otherwise
  /// masquerade as a lesson step. A navigation term is retained whenever
  /// the transcript vocabulary supports it.
  static func isInterfaceChromeNoise(_ line: String, contextualWords: [String]) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.contains("/") || lower.contains("\\") || lower.hasPrefix("~") { return true }
    if lower.hasSuffix("...") || lower.hasSuffix("…") { return true }
    if lower.range(
      of: #"^(?:[a-z]{0,3}\s*\d{1,3}|\d{1,3}\s*[a-z]{0,3})$"#,
      options: .regularExpression) != nil
    {
      return true
    }

    let words = Keywords.contentWords(lower)
    let context = Set(contextualWords.flatMap { Keywords.contentWords($0) })
    let navigationWords = Set([
      "back", "cancel", "chat", "close", "context", "desktop", "documents", "done",
      "downloads", "home", "menu", "next", "open", "pictures", "projects", "search",
      "settings",
    ])
    return words.count == 1 && navigationWords.contains(words[0]) && !context.contains(words[0])
  }
}
