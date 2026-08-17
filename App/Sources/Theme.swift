import SwiftUI

enum VNTheme {
  static let void = Color(red: 0.02, green: 0.04, blue: 0.08)
  static let abyss = Color(red: 0.04, green: 0.10, blue: 0.18)
  static let cyan = Color(red: 0.44, green: 0.94, blue: 1.0)
  static let gold = Color(red: 1.0, green: 0.82, blue: 0.47)
  static let mint = Color(red: 0.42, green: 1.0, blue: 0.72)

  /// Specular top-edge stroke that sells the liquid-glass look.
  static var glassEdge: LinearGradient {
    LinearGradient(
      colors: [
        .white.opacity(0.38), .white.opacity(0.06), .white.opacity(0.02), cyan.opacity(0.14),
      ],
      startPoint: .top, endPoint: .bottom)
  }
}

// MARK: - Animated holographic background

/// Living HUD backdrop: deep gradient, drifting glow orbs, sparse rising
/// particles and a faint grid. Freezes under Reduce Motion.
struct HUDBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [VNTheme.abyss, VNTheme.void],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      if reduceMotion || reduceTransparency || scenePhase != .active
        || ProcessInfo.processInfo.isLowPowerModeEnabled
      {
        staticGlow
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
          let t = timeline.date.timeIntervalSinceReferenceDate
          Canvas { context, size in
            drawOrbs(context: &context, size: size, t: t)
            drawParticles(context: &context, size: size, t: t)
          }
        }
      }
      grid
    }
    .ignoresSafeArea()
  }

  private var staticGlow: some View {
    RadialGradient(
      colors: [VNTheme.cyan.opacity(0.13), .clear],
      center: .top, startRadius: 0, endRadius: 650)
  }

  private var grid: some View {
    Canvas { context, size in
      for x in stride(from: 0.0, through: size.width, by: 42) {
        var p = Path()
        p.move(to: CGPoint(x: x, y: 0))
        p.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(p, with: .color(VNTheme.cyan.opacity(0.03)), lineWidth: 0.5)
      }
      for y in stride(from: 0.0, through: size.height, by: 42) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(p, with: .color(VNTheme.cyan.opacity(0.018)), lineWidth: 0.5)
      }
    }
    .mask(
      LinearGradient(colors: [.white.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
    )
    .allowsHitTesting(false)
  }

  private func drawOrbs(context: inout GraphicsContext, size: CGSize, t: TimeInterval) {
    struct Orb {
      let speed: Double
      let phase: Double
      let radius: CGFloat
      let color: Color
      let alpha: Double
    }
    let orbs = [
      Orb(speed: 0.055, phase: 0.0, radius: 520, color: VNTheme.cyan, alpha: 0.11),
      Orb(speed: 0.038, phase: 2.1, radius: 430, color: VNTheme.gold, alpha: 0.05),
      Orb(speed: 0.047, phase: 4.4, radius: 470, color: VNTheme.cyan, alpha: 0.07),
    ]
    for orb in orbs {
      let x = size.width * (0.5 + 0.42 * sin(t * orb.speed + orb.phase))
      let y = size.height * (0.42 + 0.34 * cos(t * orb.speed * 1.31 + orb.phase * 1.7))
      let rect = CGRect(
        x: x - orb.radius, y: y - orb.radius, width: orb.radius * 2, height: orb.radius * 2)
      context.fill(
        Path(ellipseIn: rect),
        with: .radialGradient(
          Gradient(colors: [orb.color.opacity(orb.alpha), .clear]),
          center: CGPoint(x: x, y: y), startRadius: 0, endRadius: orb.radius))
    }
  }

  private func drawParticles(context: inout GraphicsContext, size: CGSize, t: TimeInterval) {
    for i in 0..<26 {
      let seed = Double(i) * 61.803
      let speed = 12.0 + (seed.truncatingRemainder(dividingBy: 9))
      let x =
        (seed * 137.5).truncatingRemainder(dividingBy: 1.0) * size.width
        + sin(t * 0.3 + seed) * 14
      let y =
        size.height
        - ((t * speed + seed * 97).truncatingRemainder(dividingBy: Double(size.height) + 80)) + 40
      let r = 1.0 + (seed.truncatingRemainder(dividingBy: 2.2))
      let alpha = 0.05 + 0.10 * (0.5 + 0.5 * sin(t * 0.8 + seed))
      context.fill(
        Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
        with: .color(VNTheme.cyan.opacity(alpha)))
    }
  }
}

// MARK: - Liquid glass surfaces

struct GlassPanel: ViewModifier {
  var cornerRadius: CGFloat = 22
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    surface(content)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.white.opacity(0.045), .clear],
              startPoint: .top, endPoint: .bottom))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(VNTheme.glassEdge, lineWidth: contrast == .increased ? 1.8 : 1)
      )
      .overlay(alignment: .top) {
        Capsule()
          .fill(
            LinearGradient(
              colors: [.clear, .white.opacity(0.7), .clear],
              startPoint: .leading, endPoint: .trailing)
          )
          .frame(width: 120, height: 1)
          .blur(radius: 0.3)
          .padding(.top, 1)
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
          .strokeBorder(.black.opacity(0.16), lineWidth: 1)
          .padding(1)
          .blendMode(.overlay)
      }
      .shadow(
        color: .black.opacity(contrast == .increased ? 0.5 : 0.35),
        radius: contrast == .increased ? 12 : 22, y: 10
      )
      .shadow(
        color: contrast == .increased ? .clear : VNTheme.cyan.opacity(0.055), radius: 18, y: -4
      )
      .compositingGroup()
  }

  @ViewBuilder private func surface(_ content: Content) -> some View {
    if reduceTransparency {
      content.background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(VNTheme.abyss.opacity(0.98)))
    } else if #available(iOS 26.0, macOS 26.0, *) {
      content.glassEffect(
        .regular.tint(VNTheme.cyan.opacity(0.035)),
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      content.background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.ultraThinMaterial))
    }
  }
}

extension View {
  func glassPanel(cornerRadius: CGFloat = 22) -> some View {
    modifier(GlassPanel(cornerRadius: cornerRadius))
  }

  /// Hover glow used across glass controls (no-op on touch platforms).
  func hoverGlow(color: Color = VNTheme.cyan) -> some View { modifier(HoverGlow(color: color)) }
}

struct HoverGlow: ViewModifier {
  let color: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var hovering = false
  func body(content: Content) -> some View {
    content
      .shadow(
        color: color.opacity(hovering && contrast != .increased ? 0.45 : 0),
        radius: hovering ? 14 : 0
      )
      .brightness(hovering ? 0.06 : 0)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
      #if os(macOS)
        .onHover { hovering = $0 }
      #endif
  }
}

/// Capsule glass button. `prominent` fills with the accent for primary actions.
struct GlassButtonStyle: ButtonStyle {
  var tint: Color = VNTheme.cyan
  var prominent = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .padding(.horizontal, 15).padding(.vertical, 9)
      .foregroundStyle(prominent ? .black : tint)
      .background {
        if reduceTransparency {
          Capsule()
            .fill(prominent ? tint.opacity(0.95) : VNTheme.abyss.opacity(0.98))
            .overlay(
              Capsule().strokeBorder(
                prominent ? .white.opacity(0.45) : tint.opacity(0.7),
                lineWidth: contrast == .increased ? 2 : 1))
        } else if #available(iOS 26.0, macOS 26.0, *) {
          Capsule()
            .fill(prominent ? tint.opacity(0.28) : .clear)
            .glassEffect(
              .regular.tint(prominent ? tint : tint.opacity(0.12)).interactive(), in: Capsule())
        } else if prominent {
          Capsule().fill(
            LinearGradient(
              colors: [tint.opacity(0.98), tint.opacity(0.78)],
              startPoint: .top, endPoint: .bottom)
          )
          .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
          .overlay(alignment: .top) {
            Capsule().fill(.white.opacity(0.48)).frame(height: 1).padding(.horizontal, 12)
          }
        } else {
          Capsule().fill(.ultraThinMaterial)
            .overlay(Capsule().strokeBorder(VNTheme.glassEdge, lineWidth: 1))
            .overlay(Capsule().fill(tint.opacity(0.07)))
        }
      }
      .contentShape(Capsule())  // glass shapes don't hit-test without this
      .frame(minHeight: 44)
      .hoverGlow(color: tint)
      .scaleEffect(configuration.isPressed ? 0.955 : 1)
      .brightness(configuration.isPressed ? -0.04 : 0)
      .animation(
        reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6),
        value: configuration.isPressed)
  }
}

// MARK: - Toast

struct Toast: View {
  let text: String
  let icon: String
  var tint: Color = VNTheme.mint
  var body: some View {
    Label(text, systemImage: icon)
      .font(.callout.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 18).padding(.vertical, 11)
      .glassPanel(cornerRadius: 30)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isStaticText)
      .accessibilityIdentifier("toast")
  }
}
