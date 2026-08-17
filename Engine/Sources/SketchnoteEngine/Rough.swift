import CoreGraphics
import Foundation

/// Deterministic PRNG — the whole sketch look derives from one seed, so a
/// document re-renders identically (golden-testable) and "shuffle style"
/// is just a new seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    public mutating func range(_ r: ClosedRange<CGFloat>) -> CGFloat { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
}

/// 1-D value noise for stroke wobble: smooth, seeded, cheap.
struct ValueNoise {
    private let seed: UInt64
    init(seed: UInt64) { self.seed = seed }
    private func lattice(_ i: Int) -> CGFloat {
        var h = UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15 ^ seed
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        return CGFloat(h >> 11) / CGFloat(1 << 53) * 2 - 1
    }
    func value(_ x: CGFloat) -> CGFloat {
        let i = Int(floor(x))
        let f = x - floor(x)
        let t = f * f * (3 - 2 * f)  // smoothstep
        return lattice(i) * (1 - t) + lattice(i + 1) * t
    }
}

// MARK: - Palette

public struct Palette: Sendable, Equatable {
    public var name: String
    public var paper: CGColor
    public var ink: CGColor
    public var highlight: CGColor
    public var accent: CGColor   // arrows / structure
    public var gold: CGColor     // sparkles / warm accents

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public static let paperAndInk = Palette(
        name: "Paper & Ink",
        paper: rgb(0.968, 0.957, 0.925), ink: rgb(0.17, 0.17, 0.17),
        highlight: rgb(0.956, 0.913, 0.282), accent: rgb(0.357, 0.447, 0.522),
        gold: rgb(0.788, 0.635, 0.153))

    public static let blueprint = Palette(
        name: "Blueprint",
        paper: rgb(0.912, 0.936, 0.965), ink: rgb(0.10, 0.17, 0.30),
        highlight: rgb(0.60, 0.83, 0.98), accent: rgb(0.23, 0.42, 0.66),
        gold: rgb(0.85, 0.60, 0.13))

    public static let chalkboard = Palette(
        name: "Chalkboard",
        paper: rgb(0.145, 0.19, 0.17), ink: rgb(0.93, 0.93, 0.88),
        highlight: rgb(0.98, 0.83, 0.30, 0.55), accent: rgb(0.62, 0.78, 0.72),
        gold: rgb(0.96, 0.79, 0.35))

    public static let pastel = Palette(
        name: "Pastel",
        paper: rgb(0.99, 0.965, 0.955), ink: rgb(0.30, 0.25, 0.28),
        highlight: rgb(0.99, 0.80, 0.83), accent: rgb(0.55, 0.63, 0.79),
        gold: rgb(0.93, 0.70, 0.35))

    public static let all: [Palette] = [.paperAndInk, .blueprint, .chalkboard, .pastel]
}

// MARK: - Rough pen

/// Draws everything with a hand-sketched marker feel: paths are resampled,
/// perturbed perpendicular to their direction with value noise, and inked in
/// two slightly different passes.
public struct RoughPen {
    var rng: SplitMix64
    let context: CGContext

    public init(context: CGContext, seed: UInt64) {
        self.context = context
        self.rng = SplitMix64(seed: seed)
    }

    // MARK: primitives

    mutating func perturb(_ points: [CGPoint], amplitude: CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return points }
        let noise = ValueNoise(seed: rng.next())
        let phase = rng.range(0...100)
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            let prev = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            let dx = next.x - prev.x, dy = next.y - prev.y
            let len = max(0.001, sqrt(dx * dx + dy * dy))
            let (nx, ny) = (-dy / len, dx / len)
            // pin the ends so shapes still meet up
            let endFade: CGFloat = (i == 0 || i == points.count - 1) ? 0.35 : 1
            let offset = noise.value(phase + CGFloat(i) * 0.7) * amplitude * endFade
            out.append(CGPoint(x: p.x + nx * offset, y: p.y + ny * offset))
        }
        return out
    }

    static func resample(_ points: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var out: [CGPoint] = [points[0]]
        var carry: CGFloat = 0
        for i in 1..<points.count {
            var from = points[i - 1]
            let to = points[i]
            var segment = hypot(to.x - from.x, to.y - from.y)
            while carry + segment >= step {
                let t = (step - carry) / segment
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                out.append(p)
                from = p
                segment = hypot(to.x - from.x, to.y - from.y)
                carry = 0
            }
            carry += segment
        }
        if out.last != points.last { out.append(points.last!) }
        return out
    }

    mutating func strokePolyline(_ points: [CGPoint], color: CGColor, width: CGFloat,
                                 wobble: CGFloat = 2.2, passes: Int = 2, closed: Bool = false) {
        var base = RoughPen.resample(points, step: 12)
        if closed, let first = base.first { base.append(first) }
        for pass in 0..<passes {
            let jittered = perturb(base, amplitude: wobble)
            let path = CGMutablePath()
            path.addLines(between: jittered)
            if closed { path.closeSubpath() }
            context.saveGState()
            context.setStrokeColor(color.copy(alpha: pass == 0 ? 0.92 : 0.45) ?? color)
            context.setLineWidth(pass == 0 ? width : width * 0.75)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: shapes

    public mutating func line(from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat, wobble: CGFloat = 2.2) {
        strokePolyline([from, to], color: color, width: width, wobble: wobble)
    }

    public mutating func rect(_ rect: CGRect, color: CGColor, width: CGFloat, cornerRadius: CGFloat = 14, wobble: CGFloat = 2.4) {
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius + rng.range(-3...3),
                          cornerHeight: cornerRadius + rng.range(-3...3), transform: nil)
        for polyline in RoughPen.flatten(path) {
            strokePolyline(polyline, color: color, width: width, wobble: wobble, closed: true)
        }
    }

    public mutating func ellipse(in rect: CGRect, color: CGColor, width: CGFloat, wobble: CGFloat = 2.4) {
        let path = CGPath(ellipseIn: rect, transform: nil)
        for polyline in RoughPen.flatten(path) {
            strokePolyline(polyline, color: color, width: width, wobble: wobble, closed: true)
        }
    }

    public mutating func path(_ path: CGPath, in frame: CGRect, unitSpace: Bool, color: CGColor,
                              width: CGFloat, wobble: CGFloat = 1.6) {
        var transform = CGAffineTransform.identity
        if unitSpace {
            transform = CGAffineTransform(translationX: frame.minX, y: frame.minY)
                .scaledBy(x: frame.width, y: frame.height)
        }
        let placed = path.copy(using: &transform) ?? path
        for polyline in RoughPen.flatten(placed) {
            let closed = polyline.count > 2 && hypot(polyline[0].x - polyline.last!.x, polyline[0].y - polyline.last!.y) < 2
            strokePolyline(polyline, color: color, width: width, wobble: wobble, closed: closed)
        }
    }

    /// Fat highlighter swipe behind text (multiply-blended).
    public mutating func highlight(_ rect: CGRect, color: CGColor) {
        let mid = rect.midY + rng.range(-2...2)
        let noise = ValueNoise(seed: rng.next())
        var points: [CGPoint] = []
        let steps = max(2, Int(rect.width / 30))
        for i in 0...steps {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
            points.append(CGPoint(x: x, y: mid + noise.value(CGFloat(i) * 0.9) * 3))
        }
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setStrokeColor(color.copy(alpha: 0.75) ?? color)
        context.setLineWidth(rect.height)
        context.setLineCap(.round)
        let path = CGMutablePath()
        path.addLines(between: points)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Chunky filled arrow like the reference's steel-blue arrows.
    public mutating func fatArrow(from: CGPoint, to: CGPoint, color: CGColor, thickness: CGFloat = 26) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(1, hypot(dx, dy))
        let (ux, uy) = (dx / len, dy / len)
        let (nx, ny) = (-uy, ux)
        let headLength = min(len * 0.42, thickness * 2.1)
        let bodyEnd = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        let halfBody = thickness / 2
        let halfHead = thickness * 1.05
        // slight banana curve for hand-drawn feel
        let bow = rng.range(-0.12...0.12) * len
        let mid = CGPoint(x: (from.x + bodyEnd.x) / 2 + nx * bow, y: (from.y + bodyEnd.y) / 2 + ny * bow)
        func edge(_ side: CGFloat) -> [CGPoint] {
            [CGPoint(x: from.x + nx * halfBody * side, y: from.y + ny * halfBody * side),
             CGPoint(x: mid.x + nx * halfBody * side, y: mid.y + ny * halfBody * side),
             CGPoint(x: bodyEnd.x + nx * halfBody * side, y: bodyEnd.y + ny * halfBody * side)]
        }
        var outline = edge(1)
        outline += [CGPoint(x: bodyEnd.x + nx * halfHead, y: bodyEnd.y + ny * halfHead), to,
                    CGPoint(x: bodyEnd.x - nx * halfHead, y: bodyEnd.y - ny * halfHead)]
        outline += edge(-1).reversed()
        let jittered = perturb(RoughPen.resample(outline + [outline[0]], step: 14), amplitude: 1.8)
        let path = CGMutablePath()
        path.addLines(between: jittered)
        path.closeSubpath()
        context.saveGState()
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// Thin squiggle arrow for annotations.
    public mutating func squiggleArrow(from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat = 3.5) {
        let mid = CGPoint(x: (from.x + to.x) / 2 + rng.range(-30...30),
                          y: (from.y + to.y) / 2 + rng.range(-30...30))
        strokePolyline([from, mid, to], color: color, width: width, wobble: 3.5)
        let angle = atan2(to.y - mid.y, to.x - mid.x)
        for side: CGFloat in [-1, 1] {
            let a = angle + .pi + side * 0.5
            let tip = CGPoint(x: to.x + cos(a) * 16, y: to.y + sin(a) * 16)
            strokePolyline([to, tip], color: color, width: width, wobble: 1.2, passes: 1)
        }
    }

    public mutating func sparkle(at center: CGPoint, size: CGFloat, color: CGColor) {
        let path = CGMutablePath()
        let r = size / 2, k = size * 0.14
        path.move(to: CGPoint(x: center.x, y: center.y - r))
        path.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: CGPoint(x: center.x + k, y: center.y - k))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: CGPoint(x: center.x + k, y: center.y + k))
        path.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: CGPoint(x: center.x - k, y: center.y + k))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: CGPoint(x: center.x - k, y: center.y - k))
        path.closeSubpath()
        context.saveGState()
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: path flattening

    /// CGPath → polylines (curves sampled) so everything can be rough-stroked.
    static func flatten(_ path: CGPath, curveSteps: Int = 14) -> [[CGPoint]] {
        var polylines: [[CGPoint]] = []
        var current: [CGPoint] = []
        var subpathStart = CGPoint.zero
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                if current.count > 1 { polylines.append(current) }
                current = [element.points[0]]
                subpathStart = element.points[0]
            case .addLineToPoint:
                current.append(element.points[0])
            case .addQuadCurveToPoint:
                guard let from = current.last else { break }
                let c = element.points[0], to = element.points[1]
                for i in 1...curveSteps {
                    let t = CGFloat(i) / CGFloat(curveSteps)
                    let mt = 1 - t
                    current.append(CGPoint(
                        x: mt * mt * from.x + 2 * mt * t * c.x + t * t * to.x,
                        y: mt * mt * from.y + 2 * mt * t * c.y + t * t * to.y))
                }
            case .addCurveToPoint:
                guard let from = current.last else { break }
                let c1 = element.points[0], c2 = element.points[1], to = element.points[2]
                for i in 1...curveSteps {
                    let t = CGFloat(i) / CGFloat(curveSteps)
                    let mt = 1 - t
                    current.append(CGPoint(
                        x: mt * mt * mt * from.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * to.x,
                        y: mt * mt * mt * from.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * to.y))
                }
            case .closeSubpath:
                current.append(subpathStart)
                if current.count > 1 { polylines.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if current.count > 1 { polylines.append(current) }
        return polylines
    }
}
