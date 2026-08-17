import CryptoKit
import Foundation

public enum PipelineStage: Equatable, Sendable {
  case probing
  case transcribing
  case scanning(Double)  // 0…1 within the scan
  case structuring
  case illustrating
}

/// End-to-end: media file → NoteDocument (+ deterministic style seed).
/// Rendering is separate so style changes don't re-run analysis.
public enum SketchnotePipeline {

  public struct Result: Sendable {
    public var document: NoteDocument
    public var content: ExtractedContent
    public var seed: UInt64
  }

  public static func analyze(
    url: URL,
    injectedTranscript: [TranscriptSegment]? = nil,
    locale: Locale? = nil,
    progress: @escaping @Sendable (PipelineStage, String) -> Void
  ) async throws -> Result {
    progress(.probing, "Opening \(url.lastPathComponent)")
    let info = try await MediaProbe.probe(url: url)
    let sourceName = url.deletingPathExtension().lastPathComponent

    var transcript: [TranscriptSegment] = []
    var transcriptReason: String?
    if let injectedTranscript {
      transcript = injectedTranscript
    } else if info.hasAudio {
      progress(.transcribing, "Transcribing \(TimeFormat.mmss(info.duration)) of audio on device")
      let speechLocale = Transcriber.preferredLocale(
        requested: locale, sourceLanguageTag: info.languageTag)
      let result = await Transcriber.transcribe(url: url, locale: speechLocale)
      transcript = result.segments ?? []
      transcriptReason = result.reason
      try Task.checkCancellation()
    }

    var visuals: [VisualMoment] = []
    if info.hasVideo {
      // Domain terms heard in the lecture help Vision resolve uncommon
      // names and technical vocabulary on slides.
      let context = Keywords.topPhrases(
        in: transcript.map(\.text).joined(separator: " "), limit: 24)
      visuals = FrameSampler.visualMoments(
        url: url, duration: info.duration,
        contextualWords: context
      ) { fraction, message in
        progress(.scanning(fraction), message)
      }
      try Task.checkCancellation()
    }

    let content = ExtractedContent(
      sourceName: sourceName, duration: info.duration,
      transcript: transcript, visuals: visuals,
      transcriptUnavailableReason: transcriptReason)
    if !info.hasVideo, transcript.isEmpty, let transcriptReason {
      throw ExtractError.transcriptionUnavailable(transcriptReason)
    }
    try Task.checkCancellation()
    progress(.structuring, "Structuring the notes")
    let document = try HeuristicStructurer.structure(content)
    return Result(document: document, content: content, seed: seed(for: url))
  }

  /// Stable style seed: file identity (first MB + size), so the same lecture
  /// always sketches the same way.
  public static func seed(for url: URL) -> UInt64 {
    var hasher = SHA256()
    if let handle = try? FileHandle(forReadingFrom: url) {
      if let chunk = try? handle.read(upToCount: 1 << 20) { hasher.update(data: chunk) }
      let size = (try? handle.seekToEnd()) ?? 0
      withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
      try? handle.close()
    } else {
      hasher.update(data: Data(url.lastPathComponent.utf8))
    }
    let digest = hasher.finalize()
    return digest.withUnsafeBytes { $0.load(as: UInt64.self) }
  }
}

public enum TimeFormat {
  public static func mmss(_ seconds: Double) -> String {
    String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
  }
}
