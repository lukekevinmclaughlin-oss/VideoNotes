import CoreGraphics
import Foundation
import Vision

/// One traced polyline from a video frame, normalized to 0…1 (y-down).
public struct SketchStroke: Codable, Equatable, Sendable {
  public var points: [CGPoint]
  public init(points: [CGPoint]) { self.points = points }
}

/// Turns a video frame into a hand-traceable line drawing: Vision contour
/// detection, polygon simplification, and salience filtering. Deterministic
/// for identical frames, so re-renders stay stable.
public enum FrameSketcher {

  public static func trace(
    _ image: CGImage, excludingTextRegions textRegions: [CGRect] = [],
    maxStrokes: Int = 30, maxPoints: Int = 1400
  ) -> [SketchStroke] {
    let request = VNDetectContoursRequest()
    request.contrastAdjustment = 1.6
    request.maximumImageDimension = 512
    request.detectsDarkOnLight = true
    try? VNImageRequestHandler(cgImage: image).perform([request])
    guard let observation = request.results?.first else { return [] }

    // Vision normalizes both axes to 0…1; stretch y by the frame's aspect
    // so redrawn shapes keep their true proportions.
    let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))

    var candidates: [(score: CGFloat, points: [CGPoint])] = []
    for index in 0..<observation.contourCount {
      guard let contour = try? observation.contour(at: index) else { continue }
      let simplified = (try? contour.polygonApproximation(epsilon: 0.005)) ?? contour
      var points = simplified.normalizedPoints.map {
        CGPoint(x: CGFloat($0.x), y: CGFloat(1 - $0.y) * aspect)  // Vision is y-up
      }
      guard points.count >= 3 else { continue }
      if points.count > 90 {
        points = stride(from: 0, to: points.count, by: points.count / 90 + 1).map { points[$0] }
      }

      let xs = points.map(\.x)
      let ys = points.map(\.y)
      let w = (xs.max() ?? 0) - (xs.min() ?? 0)
      let h = ((ys.max() ?? 0) - (ys.min() ?? 0)) / max(0.01, aspect)
      let diagonal = hypot(w, h)
      // drop letter-glyph noise and full-frame borders
      guard diagonal > 0.04, diagonal < 1.35, w < 0.98 || h < 0.98 else { continue }
      let normalizedBounds = CGRect(
        x: xs.min() ?? 0, y: (ys.min() ?? 0) / max(0.01, aspect),
        width: w, height: h)
      let isRecognizedText = textRegions.contains { region in
        region.insetBy(dx: -0.008, dy: -0.006).contains(
          CGPoint(x: normalizedBounds.midX, y: normalizedBounds.midY)
        ) && normalizedBounds.width <= region.width * 1.35
          && normalizedBounds.height <= region.height * 1.8
      }
      guard !isRecognizedText else { continue }
      var perimeter: CGFloat = 0
      for i in 1..<points.count {
        perimeter += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
      }
      candidates.append((score: diagonal + perimeter * 0.35, points: points))
    }

    candidates.sort { $0.score > $1.score }
    var strokes: [SketchStroke] = []
    var budget = maxPoints
    for candidate in candidates.prefix(maxStrokes) where budget > 0 {
      strokes.append(SketchStroke(points: candidate.points))
      budget -= candidate.points.count
    }
    return strokes
  }

  /// 64-bit perceptual hash for near-duplicate frame detection. The lower
  /// 48 bits encode spatial contrast; the upper 16 encode absolute average
  /// luminance. Keeping both prevents solid black, white and grey frames
  /// from all collapsing to the same hash.
  public static func perceptualHash(_ image: CGImage) -> UInt64 {
    let width = 8
    let height = 6
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let space = CGColorSpace(name: CGColorSpace.linearGray),
      let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width, space: space,
        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return 0 }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
    var hash: UInt64 = 0
    for (i, value) in pixels.enumerated() where Int(value) > mean {
      hash |= (1 << UInt64(i))
    }
    let luminanceLevel = min(16, (mean + 15) / 16)
    let luminanceMask: UInt64 =
      luminanceLevel == 16
      ? 0xFFFF
      : (luminanceLevel == 0 ? 0 : (1 << UInt64(luminanceLevel)) - 1)
    hash |= luminanceMask << 48
    return hash
  }

  public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
    (a ^ b).nonzeroBitCount
  }
}
