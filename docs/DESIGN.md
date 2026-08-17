# VideoNotes: Design System (Holographic Study HUD)

The 2026 look and feel: an Iron-Man-style holographic HUD that scans a lecture and assembles knowledge in front of you, wrapped around study content that stays perfectly legible. This doc defines the design language, the Liquid Glass materials, the motion system, the signature animations, component specs, and how to build them in SwiftUI without hurting readability, performance, or accessibility.

Applies to `App/` (SwiftUI) and the `Design/` tokens. See `ARCHITECTURE.md` §9 for where screens live and `ENGINE.md` for the events the animations visualise.

---

## 1. The core idea: two surfaces, one system

A study app has a tension: a JARVIS HUD wants to be dark, glowing, and busy; study notes need to be calm and readable. VideoNotes resolves it by separating two surfaces that share one palette and motion language.

| Surface | Where | Character |
| --- | --- | --- |
| **The HUD** (holographic chrome) | Import, Analyze, all processing, toolbars, rails, progress, the "assembly" moments | Dark, holographic, Liquid Glass, animated. This is where the spectacle lives, and where there is no dense reading to protect. This is the "scanning data complexes and assembling them" feeling. |
| **The Study surface** (smart paper) | Note cards, sketches, the reading and export views | Calm and legible. Light "paper" by default, graphite in dark mode. Ink-on-paper sketches. The HUD frames it; the glass panels float it. |

Default appearance is **light study content inside a subtly holographic glass HUD**. A single switch, **Immersive (HUD) theme**, turns the whole app into forced-dark full-holographic mode for users who want maximum JARVIS (consistent with the forced-dark JARVIS apps in Luke's lineup, but opt-in here so the study surface stays readable by default). Processing screens are always the immersive HUD regardless of theme, because there is nothing to read there, only to watch.

Guiding rule: **never sacrifice note legibility for atmosphere.** Glass and glow live in the chrome and the transitions, not behind body text or formulas.

## 2. Colour

**HUD palette** (chrome, processing, accents):

| Token | Value | Use |
| --- | --- | --- |
| `hud/void` | `#05080F` | Deepest background |
| `hud/abyss` | `#0A1526` | Panel base, radial-lit |
| `hud/slate` | `#122A44` | Raised HUD surface |
| `holo/cyan` | `#6FF0FF` | Primary holographic line and glow |
| `holo/cyan-deep` | `#22D3EE` | Secondary cyan, fills |
| `holo/ink` | `#3BE0F5` | Hairlines, reticles at low opacity |
| `arc/gold` | `#FFD37A` | The arc-reactor core accent: the single warm highlight, used sparingly for the active/primary focus (mirrors Stark's reactor). One gold moment per view. |
| `text/hud` | `#DCF1F7` | Text on HUD |
| `text/hud-muted` | `#84A9BC` | Secondary HUD text, telemetry |

**Study palette** (content, sketches, export):

| Token | Value (light / dark) | Use |
| --- | --- | --- |
| `paper` | `#FBFCFE` / `#0E1621` | Note card surface |
| `ink` | `#141A22` / `#E8F0F6` | Body text |
| `ink-muted` | `#5A6B78` / `#93A6B4` | Secondary text |
| `sketch/ink` | `#1D9E75`, `#D85A30`, `#22D3EE`, graphite | The 2 to 3 accent inks a Study Set draws with (the StyleToken picks a set) |

Semantic roles (`success/warning/danger/info`) map onto the standard system colours, tuned for both surfaces. Colour never carries meaning alone (accessibility): pair with icon, label, or shape.

## 3. Liquid Glass

The chrome is built from a small set of glass materials, layered for depth. On 2026 OS versions this uses the system Liquid Glass material; on the `macOS 14 / iOS 17` floor it falls back to `.ultraThinMaterial` / custom blur so nothing breaks.

| Material | Recipe | Where |
| --- | --- | --- |
| `glass/panel` | translucent tint over blur(14) saturate(140%), 1px inner specular highlight (top edge), 1px holo hairline border, 16px radius | Rails, cards' chrome, inspectors |
| `glass/bar` | thinner blur, stronger bottom hairline | Toolbars, title bars |
| `glass/hud` | darker abyss tint + radial light from top, faint reticle texture | Full processing backdrops |
| `glass/reactor` | radial gold-to-transparent core glow behind the active element | The one focused/primary control per view |

Rules: glass panels get a **specular edge** (a 1px inner top highlight) so they read as physical; depth is expressed by tint darkness and blur amount, not drop shadows; never stack more than two glass elevations; content behind glass is decorative (the HUD), never the text you need to read.

## 4. Typography

- **HUD / telemetry**: SF Pro Rounded, with **monospaced digits** for all live numerics (frame counts, timers, percentages) so they do not jitter as they tick. Uppercase micro-labels with wide tracking for HUD captions only (never for content).
- **Study content**: SF Pro Text / Display for UI, and a readable body face for notes with a **dyslexia-friendly option**; formulas via SwiftMath. Full Dynamic Type support on the content surface.
- **Scale**: Title 28, Heading 20, Subhead 16, Body 16 (content) / 14 (HUD), Caption 13, Micro 11. Two weights in play at once (regular + medium); avoid heavy weights against glass.

## 5. Iconography

Thin-line holographic icons in the chrome (SF Symbols with hierarchical rendering and a cyan tint, holographic-glow variant for active state). Content icons are simple and quiet. The app icon and mark come from `assets/logo.svg` and `assets/logo-mark.svg` (the reticle-and-core). The classic play-into-notes mark is kept as `assets/logo-classic.svg` for light contexts.

## 6. Motion system

Motion is the product here: the app should feel like a live instrument scanning and assembling. But motion is disciplined, not noisy.

**Timing**

| Token | Duration | Use |
| --- | --- | --- |
| `snap` | 120 ms | Presses, toggles, hovers |
| `base` | 240 ms | Most transitions, panel moves |
| `flow` | 400 ms | Screen changes, assembly moves |
| `reveal` | 700 ms | Card generation, sketch draw-on |
| `ambient` | 8 to 26 s loops | Reticle rotation, telemetry drift, core pulse (subtle, background) |

**Easing**: springs for anything that moves in space (`response 0.4, damping 0.8` default; snappier for micro-interactions), ease-in-out for opacity and scan sweeps. Ambient loops are linear and slow.

**Principles**: every animation maps to a real engine event (a frame scored, a card assembled), never decorative churn; one focal motion at a time; ambient loops stay under the content's attention threshold; everything honours Reduce Motion.

## 7. Signature animations

These are the moments that make the app feel frontier. Each is tied to real pipeline state (`ENGINE.md`).

1. **Arc-reactor boot.** On launch, the logo reticle powers on: rings spin up, the core ignites gold, a soft shockwave settles into the home screen. ~900 ms, once.
2. **The Scan (Analyze hero).** A scan line sweeps the current frame; a rotating targeting reticle locks onto content; live telemetry (frames scanned/kept/dropped) ticks in monospaced digits. Rejected frames desaturate and fall away; **kept keyframes fly along a path into the outline rail** (`matchedGeometryEffect`), snapping into a growing node-lattice that is the study set forming. This is the literal "data complexes being scanned and assembled."
3. **Completeness lock.** When the picker settles on the finished frame in a segment (the "not half-written" moment), the frame gets a brief gold reticle lock and a crisp tick. It makes the core intelligence visible.
4. **Card assembly.** For each card: OCR text motes drift up from the frame and coalesce into the heading; the **vector sketch draws itself** (Core Graphics path trim / stroke-on, like a plotter); note lines write in with a shimmer; a progress arc-reactor fills. ~700 ms, staggered down the page.
5. **Ambient HUD.** Reticle rings rotate slowly, telemetry values breathe, the core pulses. Always subtle, paused when the window is inactive or on low power.
6. **Export beam.** On export, the study set collapses into a compact glass "capsule" that emits the chosen file formats as labelled chips. Playful, ~600 ms.

## 8. Component specs

- **Glass panel / rail**: `glass/panel`, 16px radius, specular top edge, holo hairline. Content inside uses the study palette.
- **HUD stat readout**: big monospaced number (`text/hud`), uppercase micro-label under it, hairline dividers between stats. Numbers roll with an odometer animation on change.
- **Scanning filmstrip**: a row of frame cells; states = scanning (scan line), kept (cyan glow border + tick), dropped (dimmed, small reason label). Horizontally scrollable timeline underneath with keyframe markers.
- **Note card**: study-paper surface floated in a glass frame; sketch on top, structured notes below, a timestamp chip that scrubs to the source clip, an inspector on select. Editable everywhere.
- **Sensitivity control**: not a plain slider but a **HUD dial** (an arc gauge) that re-picks keyframes live; the filmstrip re-flows as you turn it.
- **Primary action**: the one `glass/reactor` gold-cored button per view (Generate, Export). Everything else is quiet cyan-outline or ghost.
- **Progress**: an arc-reactor ring (segmented) for overall run; per-card mini arcs.
- **Toasts / telemetry log**: a thin HUD ticker for background events (a provider retry, a card cached), dismissible, never modal.
- **Empty state**: the reticle idle over a "drop a lecture to begin" target, with a "try the sample lecture" affordance.

## 9. Accessibility and comfort (non-negotiable)

- **Reduce Motion**: disables all ambient loops, the scan sweep, and fly-in paths; replaces them with instant state changes and a single quiet fade. The app is fully usable and still handsome with motion off.
- **Increase Contrast / Reduce Transparency**: glass becomes near-solid, glow is removed, hairlines strengthen, the study surface goes maximum-contrast. Legibility always wins.
- **Dynamic Type + Larger Text**: the content surface scales fully; HUD chrome scales within bounds and never clips telemetry.
- **VoiceOver**: every animated state has a static label; the Analyze screen announces progress ("28 keyframes kept of 1,842 scanned"); decorative HUD elements are hidden from AT.
- **Colour independence**: keep/drop, success/danger, and sketch categories always carry an icon or shape in addition to colour.
- **Focus / calm mode**: a one-tap toggle strips the HUD to a minimal, still, high-legibility reading view for revision sessions.

## 10. Building it in SwiftUI

- **Ambient HUD and scan effects**: `TimelineView(.animation)` + `Canvas` for the reticle, telemetry, and scan line; a `Metal` `ShaderLibrary` fragment for the holographic scan/scanline and the glass specular sheen (falls back to layered gradients if unavailable).
- **Assembly (frames to outline)**: `matchedGeometryEffect` across the filmstrip and the outline rail, driven by the engine's `AsyncStream` of kept-keyframe events.
- **Sequenced reveals** (card assembly, boot): `PhaseAnimator` / `KeyframeAnimator`; the self-drawing sketch uses an animatable trim on the Core Graphics path (a `Shape` with animatable `trimTo`).
- **Materials**: system Liquid Glass on new OSes via the glass modifiers, `.ultraThinMaterial` + custom overlay on the `macOS 14 / iOS 17` floor. One `GlassPanel` view wraps the recipe so it is consistent and swappable.
- **SF Symbols**: hierarchical + holographic-glow rendering, symbol-effect on state changes (bounce on keep, pulse while scanning).
- **Performance**: animate only `opacity`, `transform`, and shader uniforms; cap ambient loop frame rate; pause all loops when the scene is inactive, on Low Power Mode, or when thermally throttled (especially iOS); reuse a single Metal pipeline. Target a steady 120fps on ProMotion, graceful at 60.

---

Related: `ARCHITECTURE.md` (screens, materials fallback, performance), `SPEC.md` (UX flow, accessibility requirements), `AUDIT.md` (the improvements this design pass introduced).
