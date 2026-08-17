import CoreGraphics
import CoreText
import Foundation

/// Font roles for the sketchnote look. Bundled OFL hand fonts when registered,
/// rounded system fallback otherwise (non-Latin scripts fall through
/// automatically via CoreText cascading).
public enum FontBook {
    public enum Role { case heading, body, script, mono }

    /// Register bundled fonts (call once at app start; safe to call twice).
    @discardableResult
    public static func register(fontURLs: [URL]) -> Bool {
        guard !fontURLs.isEmpty else { return false }
        var ok = true
        for url in fontURLs {
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { ok = false }
        }
        return ok
    }

    static func candidates(for role: Role) -> [String] {
        switch role {
        case .heading: return ["ShantellSans-Bold", "Shantell Sans", "ShantellSans-Regular"]
        case .body: return ["PatrickHand-Regular", "Patrick Hand"]
        case .script: return ["Caveat-Bold", "Caveat-Regular", "Caveat"]
        case .mono: return []
        }
    }

    public static func font(_ role: Role, size: CGFloat) -> CTFont {
        for name in candidates(for: role) {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // CTFontCreateWithName falls back to Helvetica when missing —
            // detect by comparing requested vs resolved postscript name.
            let resolved = CTFontCopyPostScriptName(font) as String
            if resolved.lowercased().replacingOccurrences(of: " ", with: "")
                .contains(name.lowercased().split(separator: "-").first.map(String.init)?.replacingOccurrences(of: " ", with: "") ?? "~") {
                if role == .heading {
                    // variable font: ask for the bold instance
                    if let bold = boldVariant(of: font, size: size) { return bold }
                }
                return font
            }
        }
        // rounded system fallback
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if role == .heading || role == .script { traits.insert(.traitBold) }
        if let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) {
            return styled
        }
        return base
    }

    static func boldVariant(of font: CTFont, size: CGFloat) -> CTFont? {
        let weightAxis: Int = 0x77676874  // 'wght'
        let variation = [weightAxis: 700] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontVariationAttribute: variation
        ] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
    }
}

public enum TextAlign { case left, center, right }

/// CoreText draw/measure helpers for a top-left-origin (flipped) CGContext.
public struct TextKit {
    let context: CGContext
    public init(context: CGContext) { self.context = context }

    static func attributed(_ text: String, font: CTFont, color: CGColor, lineSpacing: CGFloat) -> CFAttributedString {
        var lineSpace = lineSpacing
        let paragraph = withUnsafeBytes(of: &lineSpace) { pointer -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                                                  valueSize: MemoryLayout<CGFloat>.size,
                                                  value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        return CFAttributedStringCreate(nil, text as CFString, [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: paragraph
        ] as CFDictionary)
    }

    /// Height the text needs when wrapped to `width`.
    public static func measure(_ text: String, font: CTFont, width: CGFloat, lineSpacing: CGFloat = 4) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let attributed = attributed(text, font: font, color: CGColor(gray: 0, alpha: 1), lineSpacing: lineSpacing)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: 100_000), nil)
    }

    /// Draw wrapped text into a top-left-origin rect. Returns the drawn height.
    @discardableResult
    public func draw(_ text: String, font: CTFont, color: CGColor, in rect: CGRect,
                     align: TextAlign = .left, lineSpacing: CGFloat = 4) -> CGFloat {
        guard !text.isEmpty, rect.width > 4 else { return 0 }
        let attributed = TextKit.attributed(text, font: font, color: color, lineSpacing: lineSpacing)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: rect.width, height: rect.height + 2000), nil)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: ceil(size.height) + 8), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        context.saveGState()
        // flip back to CoreText's bottom-left space just for this frame
        context.translateBy(x: rect.minX, y: rect.minY + ceil(size.height) + 8)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity

        // per-line alignment
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var x = origin.x
            switch align {
            case .left: break
            case .center: x = (rect.width - lineWidth) / 2
            case .right: x = rect.width - lineWidth
            }
            context.textPosition = CGPoint(x: x, y: origin.y)
            CTLineDraw(line, context)
        }
        context.restoreGState()
        return size.height
    }

    /// Widths of the first and last laid-out lines when wrapped to `width`.
    public static func lineExtents(_ text: String, font: CTFont, width: CGFloat) -> (first: CGFloat, last: CGFloat, lineCount: Int) {
        let attributed = attributed(text, font: font, color: CGColor(gray: 0, alpha: 1), lineSpacing: 0)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard let firstLine = lines.first, let lastLine = lines.last else { return (0, 0, 0) }
        return (CGFloat(CTLineGetTypographicBounds(firstLine, nil, nil, nil)),
                CGFloat(CTLineGetTypographicBounds(lastLine, nil, nil, nil)),
                lines.count)
    }

    /// Width of a single line (no wrapping).
    public static func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        let attributed = attributed(text, font: font, color: CGColor(gray: 0, alpha: 1), lineSpacing: 0)
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
