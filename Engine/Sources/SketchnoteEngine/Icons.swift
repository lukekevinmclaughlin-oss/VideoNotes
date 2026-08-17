@preconcurrency import CoreGraphics
import Foundation

/// Original hand-authored doodle glyphs, defined in a unit square
/// (0…1, y-down). All strokes — the RoughPen gives them the sketch finish.
public enum IconLibrary {

  /// keyword (lowercased content word) → glyph id
  public static let keywordMap: [String: String] = [
    "document": "document", "documents": "document", "doc": "document", "docs": "document",
    "file": "document", "files": "document", "pdf": "document", "page": "document",
    "text": "document",
    "content": "document", "notes": "notebook", "note": "notebook", "notebook": "notebook",
    "book": "book", "books": "book", "read": "book", "reading": "book", "course": "book",
    "brain": "brain", "mind": "brain", "memory": "brain", "think": "brain", "thinking": "brain",
    "intelligence": "brain", "intelligent": "brain", "neural": "brain", "learn": "brain",
    "learning": "brain", "knowledge": "brain",
    "ai": "chip", "model": "chip", "models": "chip", "gpt": "chip", "llm": "chip",
    "algorithm": "chip", "compute": "chip", "network": "network", "networks": "network",
    "chat": "chat", "chatbot": "chat", "conversation": "chat", "answer": "chat", "answers": "chat",
    "assistant": "chat", "bot": "chat", "question": "question", "questions": "question",
    "ask": "question",
    "idea": "bulb", "ideas": "bulb", "insight": "bulb", "creative": "bulb", "innovation": "bulb",
    "search": "magnifier", "find": "magnifier", "discover": "magnifier", "research": "magnifier",
    "settings": "gear", "configure": "gear", "config": "gear", "process": "gear", "system": "gear",
    "tool": "gear", "tools": "gear", "build": "gear", "engine": "gear",
    "lock": "lock", "private": "lock", "security": "lock", "secure": "lock", "protect": "lock",
    "password": "lock", "restrict": "lock", "access": "key", "key": "key", "keys": "key",
    "link": "link", "links": "link", "share": "share", "sharing": "share", "shared": "share",
    "publish": "share", "send": "share", "distribute": "share",
    "cloud": "cloud", "drive": "cloud", "storage": "cloud", "sync": "cloud",
    "upload": "upload", "load": "upload", "import": "upload", "download": "download",
    "folder": "folder", "folders": "folder", "organize": "folder", "library": "folder",
    "chart": "chart", "growth": "chart", "revenue": "chart", "sales": "chart", "data": "chart",
    "analytics": "chart", "metrics": "chart", "results": "chart", "increase": "chart",
    "money": "coin", "price": "coin", "pricing": "coin", "cost": "coin", "pay": "coin",
    "product": "box", "products": "box", "package": "box", "ship": "box", "deliver": "box",
    "customer": "person", "customers": "person", "user": "person", "users": "person",
    "audience": "person", "people": "person", "team": "person", "student": "person",
    "students": "person",
    "globe": "globe", "world": "globe", "global": "globe", "internet": "globe", "web": "globe",
    "online": "globe", "website": "globe",
    "video": "play", "videos": "play", "lecture": "play", "watch": "play", "play": "play",
    "audio": "wave", "sound": "wave", "voice": "wave", "speech": "wave", "listen": "wave",
    "podcast": "wave", "music": "wave",
    "time": "clock", "schedule": "clock", "minutes": "clock", "hours": "clock", "deadline": "clock",
    "goal": "target", "goals": "target", "target": "target", "focus": "target", "aim": "target",
    "launch": "rocket", "start": "rocket", "startup": "rocket", "fast": "rocket", "quick": "rocket",
    "grow": "rocket", "scale": "rocket",
    "write": "pencil", "writing": "pencil", "edit": "pencil", "draft": "pencil", "create": "pencil",
    "check": "check", "done": "check", "complete": "check", "success": "check", "correct": "check",
    "star": "star", "quality": "star", "best": "star", "premium": "star", "important": "star",
    "email": "mail", "mail": "mail", "newsletter": "mail", "inbox": "mail",
    "database": "database", "table": "database", "records": "database",
    "code": "code", "coding": "code", "software": "code", "program": "code", "developer": "code",
    "experiment": "flask", "test": "flask", "science": "flask", "chemistry": "flask",
    "shield": "shield", "safety": "shield", "safe": "shield", "trust": "shield",
    "heart": "heart", "love": "heart", "health": "heart",
    "warning": "warning", "risk": "warning", "danger": "warning", "problem": "warning",
    "laptop": "laptop", "computer": "laptop", "screen": "laptop", "desktop": "laptop",
    "app": "laptop",
  ]

  /// deterministic rotation used when a hint has no glyph
  public static let fallbackGlyphs = ["bulb", "sparkleRing", "ring", "star"]

  public static func glyph(for hint: String) -> CGPath {
    glyphs[hint] ?? glyphs["ring"]!
  }

  public static func resolvedGlyph(hint: String, fallbackIndex: Int) -> CGPath {
    if let path = glyphs[hint] { return path }
    return glyphs[fallbackGlyphs[fallbackIndex % fallbackGlyphs.count]]!
  }

  // MARK: - glyph construction DSL

  private struct P {
    let path = CGMutablePath()
    func move(_ x: CGFloat, _ y: CGFloat) -> P {
      path.move(to: CGPoint(x: x, y: y))
      return self
    }
    func line(_ x: CGFloat, _ y: CGFloat) -> P {
      path.addLine(to: CGPoint(x: x, y: y))
      return self
    }
    func quad(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) -> P {
      path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
      return self
    }
    func close() -> P {
      path.closeSubpath()
      return self
    }
    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> P {
      path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
      return self
    }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0.06) -> P {
      path.addRoundedRect(
        in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r)
      return self
    }
  }

  public static let glyphs: [String: CGPath] = {
    var g: [String: CGPath] = [:]

    g["document"] =
      P().move(0.25, 0.08).line(0.62, 0.08).line(0.78, 0.24).line(0.78, 0.92)
      .line(0.25, 0.92).close()
      .move(0.62, 0.08).line(0.62, 0.24).line(0.78, 0.24)
      .move(0.34, 0.40).line(0.68, 0.40).move(0.34, 0.54).line(0.68, 0.54)
      .move(0.34, 0.68).line(0.56, 0.68).path

    g["notebook"] =
      P().rect(0.22, 0.10, 0.56, 0.80, r: 0.05)
      .move(0.34, 0.10).line(0.34, 0.90)
      .move(0.44, 0.30).line(0.68, 0.30).move(0.44, 0.46).line(0.68, 0.46)
      .move(0.44, 0.62).line(0.68, 0.62).path

    g["book"] =
      P().move(0.50, 0.20).quad(0.30, 0.10, 0.12, 0.18).line(0.12, 0.82)
      .quad(0.30, 0.74, 0.50, 0.84).quad(0.70, 0.74, 0.88, 0.82).line(0.88, 0.18)
      .quad(0.70, 0.10, 0.50, 0.20).move(0.50, 0.20).line(0.50, 0.84).path

    g["brain"] =
      P().move(0.50, 0.14).quad(0.28, 0.10, 0.22, 0.30).quad(0.08, 0.36, 0.14, 0.54)
      .quad(0.10, 0.72, 0.30, 0.78).quad(0.36, 0.92, 0.50, 0.86)
      .quad(0.64, 0.92, 0.70, 0.78).quad(0.90, 0.72, 0.86, 0.54)
      .quad(0.92, 0.36, 0.78, 0.30).quad(0.72, 0.10, 0.50, 0.14).close()
      .move(0.50, 0.14).line(0.50, 0.86)
      .move(0.32, 0.34).quad(0.42, 0.40, 0.38, 0.52)
      .move(0.68, 0.34).quad(0.58, 0.40, 0.62, 0.52)
      .move(0.30, 0.62).quad(0.40, 0.60, 0.42, 0.70).path

    g["chip"] =
      P().rect(0.28, 0.28, 0.44, 0.44, r: 0.04).rect(0.40, 0.40, 0.20, 0.20, r: 0.02)
      .move(0.36, 0.28).line(0.36, 0.14).move(0.50, 0.28).line(0.50, 0.14).move(0.64, 0.28).line(
        0.64, 0.14
      )
      .move(0.36, 0.72).line(0.36, 0.86).move(0.50, 0.72).line(0.50, 0.86).move(0.64, 0.72).line(
        0.64, 0.86
      )
      .move(0.28, 0.36).line(0.14, 0.36).move(0.28, 0.50).line(0.14, 0.50).move(0.28, 0.64).line(
        0.14, 0.64
      )
      .move(0.72, 0.36).line(0.86, 0.36).move(0.72, 0.50).line(0.86, 0.50).move(0.72, 0.64).line(
        0.86, 0.64
      ).path

    g["network"] =
      P().circle(0.50, 0.18, 0.09).circle(0.18, 0.74, 0.09).circle(0.82, 0.74, 0.09)
      .circle(0.50, 0.52, 0.07)
      .move(0.50, 0.27).line(0.50, 0.45).move(0.45, 0.57).line(0.24, 0.67).move(0.55, 0.57).line(
        0.76, 0.67
      ).path

    g["chat"] =
      P().move(0.14, 0.22).quad(0.14, 0.14, 0.24, 0.14).line(0.76, 0.14)
      .quad(0.86, 0.14, 0.86, 0.24).line(0.86, 0.58).quad(0.86, 0.68, 0.76, 0.68)
      .line(0.42, 0.68).line(0.26, 0.86).line(0.28, 0.68).line(0.24, 0.68)
      .quad(0.14, 0.68, 0.14, 0.58).close()
      .move(0.30, 0.36).line(0.70, 0.36).move(0.30, 0.50).line(0.58, 0.50).path

    g["question"] =
      P().move(0.36, 0.32).quad(0.36, 0.16, 0.52, 0.16).quad(0.68, 0.16, 0.66, 0.34)
      .quad(0.65, 0.46, 0.52, 0.52).line(0.51, 0.62)
      .move(0.51, 0.74).line(0.51, 0.80).path

    g["bulb"] =
      P().move(0.50, 0.10).quad(0.24, 0.10, 0.26, 0.38).quad(0.27, 0.52, 0.40, 0.62)
      .line(0.40, 0.72).line(0.60, 0.72).line(0.60, 0.62)
      .quad(0.73, 0.52, 0.74, 0.38).quad(0.76, 0.10, 0.50, 0.10).close()
      .move(0.42, 0.80).line(0.58, 0.80).move(0.44, 0.88).line(0.56, 0.88).path

    g["magnifier"] =
      P().circle(0.42, 0.40, 0.24)
      .move(0.60, 0.58).line(0.84, 0.84).path

    g["gear"] = {
      let p = P()
      _ = p.circle(0.50, 0.50, 0.16)
      for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4
        _ = p.move(0.50 + cos(a) * 0.28, 0.50 + sin(a) * 0.28)
          .line(0.50 + cos(a) * 0.40, 0.50 + sin(a) * 0.40)
      }
      _ = p.circle(0.50, 0.50, 0.30)
      return p.path
    }()

    g["lock"] =
      P().rect(0.26, 0.44, 0.48, 0.42, r: 0.06)
      .move(0.34, 0.44).line(0.34, 0.32).quad(0.34, 0.14, 0.50, 0.14)
      .quad(0.66, 0.14, 0.66, 0.32).line(0.66, 0.44)
      .circle(0.50, 0.62, 0.05).move(0.50, 0.67).line(0.50, 0.76).path

    g["key"] =
      P().circle(0.30, 0.36, 0.16)
      .move(0.42, 0.48).line(0.78, 0.84).move(0.66, 0.72).line(0.58, 0.80)
      .move(0.78, 0.84).line(0.70, 0.92).path

    g["link"] =
      P().move(0.44, 0.32).line(0.56, 0.20).quad(0.70, 0.06, 0.82, 0.18)
      .quad(0.94, 0.30, 0.80, 0.44).line(0.68, 0.56)
      .move(0.56, 0.68).line(0.44, 0.80).quad(0.30, 0.94, 0.18, 0.82)
      .quad(0.06, 0.70, 0.20, 0.56).line(0.32, 0.44)
      .move(0.38, 0.62).line(0.62, 0.38).path

    g["share"] =
      P().circle(0.24, 0.50, 0.10).circle(0.76, 0.22, 0.10).circle(0.76, 0.78, 0.10)
      .move(0.33, 0.45).line(0.67, 0.27).move(0.33, 0.55).line(0.67, 0.73).path

    g["cloud"] =
      P().move(0.26, 0.66).quad(0.10, 0.66, 0.12, 0.52).quad(0.13, 0.40, 0.28, 0.40)
      .quad(0.32, 0.22, 0.50, 0.24).quad(0.66, 0.25, 0.70, 0.40)
      .quad(0.88, 0.40, 0.88, 0.54).quad(0.88, 0.66, 0.74, 0.66).close().path

    g["upload"] =
      P().move(0.50, 0.66).line(0.50, 0.22).move(0.34, 0.38).line(0.50, 0.20).line(0.66, 0.38)
      .move(0.18, 0.72).line(0.18, 0.84).line(0.82, 0.84).line(0.82, 0.72).path

    g["download"] =
      P().move(0.50, 0.20).line(0.50, 0.64).move(0.34, 0.48).line(0.50, 0.66).line(0.66, 0.48)
      .move(0.18, 0.72).line(0.18, 0.84).line(0.82, 0.84).line(0.82, 0.72).path

    g["folder"] =
      P().move(0.12, 0.28).line(0.38, 0.28).line(0.46, 0.38).line(0.88, 0.38)
      .line(0.88, 0.80).line(0.12, 0.80).close().path

    g["chart"] =
      P().move(0.14, 0.14).line(0.14, 0.86).line(0.88, 0.86)
      .move(0.26, 0.86).line(0.26, 0.62).move(0.44, 0.86).line(0.44, 0.46)
      .move(0.62, 0.86).line(0.62, 0.56).move(0.80, 0.86).line(0.80, 0.32)
      .move(0.22, 0.52).quad(0.45, 0.30, 0.60, 0.42).line(0.82, 0.22)
      .move(0.72, 0.22).line(0.82, 0.22).line(0.82, 0.32).path

    g["coin"] =
      P().circle(0.50, 0.50, 0.34)
      .move(0.50, 0.30).line(0.50, 0.70)
      .move(0.62, 0.38).quad(0.50, 0.30, 0.42, 0.40).quad(0.36, 0.50, 0.50, 0.52)
      .quad(0.64, 0.54, 0.58, 0.64).quad(0.50, 0.72, 0.38, 0.62).path

    g["box"] =
      P().move(0.50, 0.12).line(0.86, 0.30).line(0.86, 0.70).line(0.50, 0.88)
      .line(0.14, 0.70).line(0.14, 0.30).close()
      .move(0.14, 0.30).line(0.50, 0.48).line(0.86, 0.30)
      .move(0.50, 0.48).line(0.50, 0.88).path

    g["person"] =
      P().circle(0.50, 0.30, 0.15)
      .move(0.22, 0.86).quad(0.24, 0.56, 0.50, 0.56).quad(0.76, 0.56, 0.78, 0.86).path

    g["globe"] =
      P().circle(0.50, 0.50, 0.36)
      .move(0.14, 0.50).line(0.86, 0.50)
      .move(0.50, 0.14).quad(0.24, 0.50, 0.50, 0.86).move(0.50, 0.14).quad(0.76, 0.50, 0.50, 0.86)
      .path

    g["play"] =
      P().rect(0.12, 0.20, 0.76, 0.60, r: 0.08)
      .move(0.42, 0.36).line(0.64, 0.50).line(0.42, 0.64).close().path

    g["wave"] =
      P().move(0.12, 0.50).line(0.12, 0.50)
      .move(0.16, 0.40).line(0.16, 0.60).move(0.28, 0.28).line(0.28, 0.72)
      .move(0.40, 0.36).line(0.40, 0.64).move(0.52, 0.16).line(0.52, 0.84)
      .move(0.64, 0.32).line(0.64, 0.68).move(0.76, 0.42).line(0.76, 0.58)
      .move(0.88, 0.36).line(0.88, 0.64).path

    g["clock"] =
      P().circle(0.50, 0.50, 0.34)
      .move(0.50, 0.30).line(0.50, 0.52).line(0.66, 0.62).path

    g["target"] =
      P().circle(0.50, 0.50, 0.34).circle(0.50, 0.50, 0.20).circle(0.50, 0.50, 0.06).path

    g["rocket"] =
      P().move(0.50, 0.10).quad(0.68, 0.26, 0.62, 0.56).line(0.38, 0.56)
      .quad(0.32, 0.26, 0.50, 0.10).close()
      .move(0.38, 0.50).quad(0.24, 0.56, 0.24, 0.72).line(0.38, 0.64)
      .move(0.62, 0.50).quad(0.76, 0.56, 0.76, 0.72).line(0.62, 0.64)
      .move(0.46, 0.66).quad(0.50, 0.80, 0.50, 0.88).move(0.54, 0.66).quad(0.50, 0.80, 0.50, 0.88)
      .circle(0.50, 0.34, 0.07).path

    g["pencil"] =
      P().move(0.24, 0.68).line(0.62, 0.30).line(0.74, 0.42).line(0.36, 0.80)
      .line(0.20, 0.84).close()
      .move(0.56, 0.36).line(0.68, 0.48).path

    g["check"] = P().move(0.22, 0.54).line(0.42, 0.74).line(0.80, 0.28).path

    g["star"] = {
      let p = P()
      var first = true
      for i in 0..<10 {
        let a = CGFloat(i) * .pi / 5 - .pi / 2
        let r: CGFloat = i % 2 == 0 ? 0.38 : 0.16
        let x = 0.5 + cos(a) * r
        let y = 0.5 + sin(a) * r
        if first {
          _ = p.move(x, y)
          first = false
        } else {
          _ = p.line(x, y)
        }
      }
      return p.close().path
    }()

    g["mail"] =
      P().rect(0.14, 0.24, 0.72, 0.52, r: 0.05)
      .move(0.14, 0.28).line(0.50, 0.56).line(0.86, 0.28).path

    g["database"] =
      P().move(0.22, 0.24).quad(0.50, 0.10, 0.78, 0.24).line(0.78, 0.76)
      .quad(0.50, 0.90, 0.22, 0.76).close()
      .move(0.22, 0.24).quad(0.50, 0.38, 0.78, 0.24)
      .move(0.22, 0.50).quad(0.50, 0.64, 0.78, 0.50).path

    g["code"] =
      P().move(0.34, 0.30).line(0.14, 0.50).line(0.34, 0.70)
      .move(0.66, 0.30).line(0.86, 0.50).line(0.66, 0.70)
      .move(0.56, 0.22).line(0.44, 0.78).path

    g["flask"] =
      P().move(0.42, 0.12).line(0.42, 0.38).line(0.20, 0.78)
      .quad(0.16, 0.88, 0.28, 0.88).line(0.72, 0.88).quad(0.84, 0.88, 0.80, 0.78)
      .line(0.58, 0.38).line(0.58, 0.12)
      .move(0.36, 0.12).line(0.64, 0.12)
      .move(0.30, 0.62).line(0.70, 0.62).path

    g["shield"] =
      P().move(0.50, 0.10).quad(0.66, 0.20, 0.84, 0.22).quad(0.84, 0.64, 0.50, 0.90)
      .quad(0.16, 0.64, 0.16, 0.22).quad(0.34, 0.20, 0.50, 0.10).close()
      .move(0.36, 0.48).line(0.47, 0.60).line(0.66, 0.36).path

    g["heart"] =
      P().move(0.50, 0.82).quad(0.10, 0.52, 0.20, 0.30)
      .quad(0.30, 0.12, 0.50, 0.30).quad(0.70, 0.12, 0.80, 0.30)
      .quad(0.90, 0.52, 0.50, 0.82).close().path

    g["warning"] =
      P().move(0.50, 0.12).line(0.90, 0.84).line(0.10, 0.84).close()
      .move(0.50, 0.38).line(0.50, 0.62).move(0.50, 0.72).line(0.50, 0.76).path

    g["laptop"] =
      P().rect(0.20, 0.20, 0.60, 0.42, r: 0.04)
      .move(0.12, 0.74).line(0.20, 0.62).move(0.88, 0.74).line(0.80, 0.62)
      .move(0.12, 0.74).line(0.88, 0.74).path

    g["ring"] = P().circle(0.50, 0.50, 0.30).path

    g["sparkleRing"] =
      P().circle(0.50, 0.50, 0.24)
      .move(0.50, 0.10).line(0.50, 0.18).move(0.50, 0.82).line(0.50, 0.90)
      .move(0.10, 0.50).line(0.18, 0.50).move(0.82, 0.50).line(0.90, 0.50).path

    return g
  }()
}
