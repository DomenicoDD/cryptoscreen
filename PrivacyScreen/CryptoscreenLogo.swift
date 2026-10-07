import SwiftUI

// MARK: - Geometry

/// The cryptoscreen logo (pixel lock + feather), taken from the Figma splash icon.
/// Everything lives in a 999-unit square, the size of the source artwork, and is
/// scaled at draw time.
enum CSLogo {
  static let unit: CGFloat = 999
  static let cellSize: CGFloat = 36
  static let cornerRadius: CGFloat = 220

  enum Layer {
    /// The faded lower-right lock body (a gradient boolean union in Figma).
    case body
    /// Lock pixels drawn under the feather.
    case lock
    /// The right side of the shackle and the bottom row sit above the feather.
    case aboveFeather
  }

  struct Cell {
    let origin: CGPoint
    let color: Color
    let opacity: Double
    let layer: Layer
    /// Decrypt window in ms for lock cells: glyphs flicker between start and end.
    var start: Double = 0
    var end: Double = 0
    /// Fade-in delay in ms for body cells.
    var fadeDelay: Double = 0

    var rect: CGRect { CGRect(origin: origin, size: CGSize(width: cellSize, height: cellSize)) }
  }

  static let cells: [Cell] = makeCells()

  /// Feather outline, positioned in icon space.
  static let featherPath: Path = {
    var path = Path()
    let offset = CGPoint(x: 218.0008, y: 139.0003)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + offset.x, y: y + offset.y) }
    path.move(to: p(110.416, 501.481))
    path.addCurve(to: p(34.9355, 674.851), control1: p(101.826, 518.037), control2: p(15.1138, 660.776))
    path.addCurve(to: p(63.2562, 659.584), control1: p(54.7573, 688.925), control2: p(59.4133, 667.17))
    path.addCurve(to: p(127.869, 545.853), control1: p(78.4411, 629.606), control2: p(106.675, 569.814))
    path.addCurve(to: p(217.158, 477.429), control1: p(146.935, 524.299), control2: p(181.654, 499.033))
    path.addCurve(to: p(173.851, 477.049), control1: p(204.499, 477.318), control2: p(195.142, 480.622))
    path.addCurve(to: p(340.213, 383.328), control1: p(224.84, 461.99), control2: p(325.383, 402.838))
    path.addCurve(to: p(272.269, 382.731), control1: p(331.522, 386.638), control2: p(295.546, 387.677))
    path.addCurve(to: p(363.374, 353.499), control1: p(286.933, 382.183), control2: p(340.397, 362.307))
    path.addCurve(to: p(392.75, 300.074), control1: p(377.886, 335.238), control2: p(385.419, 320.435))
    path.addCurve(to: p(313.233, 310.994), control1: p(386.063, 302.724), control2: p(343.833, 316.681))
    path.addCurve(to: p(407.82, 258.508), control1: p(329.89, 311.141), control2: p(397.982, 280.892))
    path.addCurve(to: p(555.067, 37.0224), control1: p(442.228, 180.225), control2: p(515.177, 81.1608))
    path.addCurve(to: p(373.196, 100.025), control1: p(574.222, 15.8268), control2: p(477.22, 30.0845))
    path.addCurve(to: p(191.792, 279.81), control1: p(302.029, 147.874), control2: p(242.894, 199.333))
    path.addCurve(to: p(143.878, 439.3), control1: p(140.691, 360.287), control2: p(143.952, 430.888))
    path.addCurve(to: p(141.029, 444.265), control1: p(143.804, 447.712), control2: p(143.23, 449.133))
    path.addCurve(to: p(129.156, 399.283), control1: p(138.827, 439.398), control2: p(134.472, 426.649))
    path.addCurve(to: p(121.102, 433.05), control1: p(127.443, 402.69), control2: p(121.22, 419.639))
    path.addCurve(to: p(110.416, 501.481), control1: p(120.985, 446.461), control2: p(123.324, 476.605))
    path.closeSubpath()
    return path
  }()

  static let featherGradient = Gradient(stops: [
    .init(color: Color(hex: 0xEAFFF3), location: 0.09),
    .init(color: .white, location: 0.32),
    .init(color: Color(hex: 0xD5F7EE), location: 0.84)
  ])
  static let featherGradientStart = CGPoint(x: 187.87 + 218.0008, y: 265.909 + 139.0003)
  static let featherGradientEnd = CGPoint(x: 379.014 + 218.0008, y: 383.669 + 139.0003)
  /// Pivot for the feather's drop-in: near the quill.
  static let featherPivot = CGPoint(x: 354, y: 757)

  static let tileGradient = Gradient(colors: [Color(hex: 0x062B1D), Color(hex: 0x001107)])

  private static func makeCells() -> [Cell] {
    let green = Color(hex: 0x5FBD86), light = Color(hex: 0x64B686), dark = Color(hex: 0x2F8954), deep = Color(hex: 0x0D4725)
    // [x, y, color, opacity] from the Figma icon, in paint order.
    let lock: [(CGFloat, CGFloat, Color, Double)] = [
      (254, 460, light, 1), (295, 460, green, 1), (336, 460, green, 1), (377, 460, green, 1), (418, 460, green, 1), (459, 460, green, 1),
      (254, 501, light, 1), (295, 501, green, 1), (336, 501, green, 1), (377, 501, green, 1), (418, 501, green, 1), (459, 501, green, 1),
      (254, 542, green, 1), (295, 542, green, 1), (336, 542, green, 1), (377, 542, green, 1), (418, 542, green, 1), (459, 542, green, 1),
      (254, 583, green, 1), (295, 583, green, 1), (254, 623, green, 1), (295, 623, green, 1), (254, 664, green, 1), (295, 664, green, 1),
      (254, 705, green, 1), (582, 583, green, 0.33), (664, 623, green, 0.25), (459, 664, green, 0.7), (295, 746, green, 0.32),
      (541, 746, green, 0.12), (664, 746, green, 0.1),
      (418, 173, light, 1), (459, 173, green, 1), (459, 214, dark, 1), (500, 173, green, 1), (500, 214, dark, 1), (541, 173, green, 1),
      (295, 419, green, 1), (295, 378, green, 1), (295, 337, green, 1), (295, 296, light, 1), (336, 255, light, 1), (377, 214, light, 1),
      (336, 419, dark, 1), (336, 378, dark, 1), (336, 337, dark, 1), (377, 255, dark, 1), (336, 296, dark, 1), (418, 214, dark, 1),
      (541, 214, green, 1), (584, 214, green, 1)
    ]
    let bottomRow: [(CGFloat, CGFloat, Color, Double)] = [
      (254, 787, green, 1), (377, 787, deep, 0.8), (295, 787, green, 1), (336, 787, green, 1), (418, 787, green, 0.8), (459, 787, green, 0.8),
      (500, 787, deep, 0.8), (541, 787, green, 0.8), (582, 787, deep, 0.8), (623, 787, green, 0.8), (664, 787, deep, 0.4), (705, 787, green, 0.4)
    ]
    let shackleRight: [(CGFloat, CGFloat, Color, Double)] = [
      (583, 255, green, 1), (624, 255, dark, 1), (623, 296, green, 1), (623, 337, green, 1), (623, 378, green, 1),
      (623, 419, dark, 1), (664, 296, dark, 1), (664, 337, dark, 1), (664, 378, dark, 1), (664, 419, dark, 1)
    ]
    let body: [(CGFloat, CGFloat)] = [
      (500, 460), (541, 460), (582, 460), (623, 460), (664, 460), (705, 460), (500, 501), (541, 501), (582, 501), (623, 501), (664, 501), (705, 501),
      (500, 542), (541, 542), (582, 542), (623, 542), (664, 542), (705, 542), (336, 583), (377, 583), (418, 583), (459, 583), (500, 583), (541, 583),
      (623, 583), (705, 583), (336, 623), (377, 623), (418, 623), (459, 623), (500, 623), (541, 623), (582, 623), (623, 623), (705, 623),
      (336, 664), (377, 664), (418, 664), (500, 664), (541, 664), (582, 664), (623, 664), (664, 664), (705, 664), (295, 705), (336, 705),
      (377, 705), (418, 705), (459, 705), (500, 705), (541, 705), (582, 705), (623, 705), (664, 705), (705, 705), (254, 746), (336, 746),
      (377, 746), (418, 746), (459, 746), (500, 746), (582, 746), (623, 746), (705, 746)
    ]

    var cells: [Cell] = body.map { x, y in
      let distance = hypot(x + 18 - 300, y + 18 - 470)
      var cell = Cell(origin: CGPoint(x: x, y: y), color: green, opacity: max(0.06, 0.95 - distance / 520), layer: .body)
      cell.fadeDelay = 560 + Double((x - 254) + (y - 460)) / 900 * 400
      return cell
    }

    var decrypting: [Cell] = lock.map { Cell(origin: CGPoint(x: $0.0, y: $0.1), color: $0.2, opacity: $0.3, layer: .lock) }
    decrypting += bottomRow.map { Cell(origin: CGPoint(x: $0.0, y: $0.1), color: $0.2, opacity: $0.3, layer: .aboveFeather) }
    decrypting += shackleRight.map { Cell(origin: CGPoint(x: $0.0, y: $0.1), color: $0.2, opacity: $0.3, layer: .aboveFeather) }

    // Decrypt top to bottom with jitter; seeded so every launch looks the same.
    var generator = SplitMix64(seed: 0xC0FFEE)
    let order = decrypting.indices.map { ($0, Double(decrypting[$0].origin.y) + generator.unit() * 120) }.sorted { $0.1 < $1.1 }
    for (rank, entry) in order.enumerated() {
      decrypting[entry.0].start = 220 + Double(rank) * 11
      decrypting[entry.0].end = decrypting[entry.0].start + 160 + generator.unit() * 180
    }

    cells += decrypting
    return cells
  }
}

struct SplitMix64 {
  private var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}

// MARK: - Timing helpers

enum CSMotion {
  /// CSS-style cubic-bezier easing, solved for x with Newton iterations.
  static func bezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
    let t = min(max(t, 0), 1)
    func sample(_ a: Double, _ b: Double, _ s: Double) -> Double {
      let u = 1 - s
      return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }
    var s = t
    for _ in 0..<8 {
      let x = sample(x1, x2, s) - t
      let u = 1 - s
      let dx = 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2)
      guard abs(dx) > 1e-6 else { break }
      s = min(max(s - x / dx, 0), 1)
    }
    return sample(y1, y2, s)
  }

  /// The site's `--ease-out`: cubic-bezier(0.22, 1, 0.36, 1).
  static func easeOut(_ t: Double) -> Double { bezier(t, 0.22, 1, 0.36, 1) }

  static func progress(_ time: Double, from start: Double, duration: Double) -> Double {
    min(max((time - start) / duration, 0), 1)
  }

  static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

  static let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#$%&*+-/<>[]{}")

  /// A glyph that changes every 55 ms, stable within a tick.
  static func glyph(seed: Int, time: Double) -> Character {
    var generator = SplitMix64(seed: UInt64(bitPattern: Int64(seed &* 7919 &+ Int(time / 55))))
    return glyphs[Int(generator.next() % UInt64(glyphs.count))]
  }
}

// MARK: - Drawing

/// Draws the logo at a moment of the launch sequence. `time == nil` draws the settled logo.
struct CSLogoRenderer {
  var time: Double?

  private func settled(_ value: Double) -> Bool { time.map { $0 >= value } ?? true }

  func draw(in context: inout GraphicsContext, size: CGFloat) {
    let s = size / CSLogo.unit
    let t = time ?? .greatestFiniteMagnitude

    // Tile
    let tileP = time == nil ? 1 : CSMotion.easeOut(CSMotion.progress(t, from: 520, duration: 640))
    if tileP > 0 {
      context.drawLayer { layer in
        layer.opacity = tileP
        let scale = 0.92 + 0.08 * tileP
        layer.translateBy(x: size / 2, y: size / 2)
        layer.scaleBy(x: scale * s, y: scale * s)
        layer.translateBy(x: -CSLogo.unit / 2, y: -CSLogo.unit / 2)
        let rect = CGRect(x: 0, y: 0, width: CSLogo.unit, height: CSLogo.unit)
        let tile = RoundedRectangle(cornerRadius: CSLogo.cornerRadius, style: .continuous).path(in: rect)
        layer.fill(tile, with: .radialGradient(CSLogo.tileGradient, center: CGPoint(x: 420, y: 620), startRadius: 0, endRadius: 620))
        layer.stroke(
          RoundedRectangle(cornerRadius: CSLogo.cornerRadius - 1.5, style: .continuous).path(in: rect.insetBy(dx: 1.5, dy: 1.5)),
          with: .linearGradient(
            Gradient(colors: [CSTheme.accent.opacity(0.22), CSTheme.accent.opacity(0.03)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: CSLogo.unit)
          ),
          lineWidth: 3
        )
      }
    }

    // Body and lock pixels under the feather
    context.drawLayer { layer in
      layer.scaleBy(x: s, y: s)
      for cell in CSLogo.cells where cell.layer == .body {
        let p = time == nil ? 1 : CSMotion.progress(t, from: cell.fadeDelay, duration: 420)
        guard p > 0 else { continue }
        layer.fill(cellPath(cell.rect), with: .color(cell.color.opacity(cell.opacity * p)))
      }
      drawDecryptingCells(in: &layer, layer: .lock, t: t)
    }

    drawFeather(in: &context, s: s, t: t)

    // Bottom row, then the right side of the shackle with its own soft shadow
    context.drawLayer { layer in
      layer.scaleBy(x: s, y: s)
      drawDecryptingCells(in: &layer, layer: .aboveFeather, t: t, filter: { $0.origin.y == 787 })
    }
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: Color(hex: 0x044A21, opacity: 0.31), radius: 10 * s, x: -10 * s, y: 13 * s))
      layer.scaleBy(x: s, y: s)
      drawDecryptingCells(in: &layer, layer: .aboveFeather, t: t, filter: { $0.origin.y != 787 })
    }

    // Cipher glyphs over cells that are still decrypting
    if let time, time < 1400 {
      context.drawLayer { layer in
        layer.addFilter(.shadow(color: CSTheme.accent.opacity(0.85), radius: 10 * s))
        for (index, cell) in CSLogo.cells.enumerated() where cell.layer != .body && time >= cell.start && time < cell.end {
          let center = CGPoint(x: (cell.origin.x + 18) * s, y: (cell.origin.y + 18) * s)
          let glyph = Text(String(CSMotion.glyph(seed: index, time: time)))
            .font(.system(size: 34 * s, weight: .semibold, design: .monospaced))
            .foregroundStyle(CSTheme.accent)
          layer.draw(glyph, at: center)
        }
      }
    }
  }

  private func cellPath(_ rect: CGRect) -> Path {
    Path(roundedRect: rect, cornerRadius: 2)
  }

  private func drawDecryptingCells(in layer: inout GraphicsContext, layer kind: CSLogo.Layer, t: Double, filter: (CSLogo.Cell) -> Bool = { _ in true }) {
    for cell in CSLogo.cells where cell.layer == kind && filter(cell) {
      if time == nil {
        layer.fill(cellPath(cell.rect), with: .color(cell.color.opacity(cell.opacity)))
        continue
      }
      let p = CSMotion.progress(t, from: cell.end, duration: 260)
      guard p > 0 else { continue }
      // Pop: 0.4 → 1.12 → 1, brightening past its final opacity on the way.
      let e = CSMotion.easeOut(p)
      let scale = e < 0.6 ? 0.4 + 0.72 * (e / 0.6) : 1.12 - 0.12 * ((e - 0.6) / 0.4)
      let peak = min(1, cell.opacity + 0.25)
      let opacity = e < 0.6 ? peak * (e / 0.6) : peak + (cell.opacity - peak) * ((e - 0.6) / 0.4)
      let rect = cell.rect.insetBy(dx: CSLogo.cellSize * (1 - scale) / 2, dy: CSLogo.cellSize * (1 - scale) / 2)
      layer.fill(cellPath(rect), with: .color(cell.color.opacity(opacity)))
    }
  }

  private func drawFeather(in context: inout GraphicsContext, s: CGFloat, t: Double) {
    let drop = time == nil ? 1 : CSMotion.easeOut(CSMotion.progress(t, from: 1150, duration: 650))
    guard drop > 0 else { return }
    let reveal = time == nil ? 1 : 1 - pow(1 - CSMotion.progress(t, from: 1150, duration: 560), 3)

    context.drawLayer { layer in
      layer.opacity = drop
      layer.addFilter(.shadow(color: Color(red: 0, green: 0.153, blue: 0.063, opacity: 0.6), radius: 20 * s, x: 8 * s, y: 12 * s))
      layer.addFilter(.shadow(color: Color(red: 0, green: 0.153, blue: 0.063, opacity: 0.5), radius: 3 * s, x: 3 * s, y: 4 * s))
      layer.scaleBy(x: s, y: s)

      // Drop in from the top right, rotating -14° → 0° around the quill.
      let pivot = CSLogo.featherPivot
      layer.translateBy(x: 140 * (1 - drop), y: -170 * (1 - drop))
      layer.translateBy(x: pivot.x, y: pivot.y)
      layer.rotate(by: .degrees(-14 * (1 - drop)))
      layer.translateBy(x: -pivot.x, y: -pivot.y)

      // Written in from tip to quill.
      if reveal < 1 {
        let band = Path(CGRect(x: -400, y: -800, width: 1800, height: 2000 * reveal))
          .applying(CGAffineTransform(translationX: 500, y: 500).rotated(by: -38 * .pi / 180).translatedBy(x: -500, y: -500))
        layer.clip(to: band)
      }

      layer.fill(
        CSLogo.featherPath,
        with: .linearGradient(CSLogo.featherGradient, startPoint: CSLogo.featherGradientStart, endPoint: CSLogo.featherGradientEnd)
      )

      // Glint across the feather once it has landed.
      if let time {
        let p = CSMotion.progress(time, from: 1800, duration: 620)
        if p > 0 && p < 1 {
          let alpha = p < 0.3 ? 0.9 * (p / 0.3) : 0.9 * (1 - (p - 0.3) / 0.7)
          var shine = layer
          shine.clip(to: CSLogo.featherPath)
          shine.translateBy(x: 300, y: 380)
          shine.rotate(by: .degrees(28))
          shine.translateBy(x: -300 + 820 * p, y: -380)
          shine.fill(
            Path(CGRect(x: -200, y: 0, width: 140, height: 760)),
            with: .linearGradient(
              Gradient(colors: [.white.opacity(0), .white.opacity(0.95 * alpha), .white.opacity(0)]),
              startPoint: CGPoint(x: -200, y: 0), endPoint: CGPoint(x: -60, y: 0)
            )
          )
        }
      }
    }
  }
}

/// The settled logo, used in the app header.
struct CryptoscreenLogoMark: View {
  var size: CGFloat = 40

  var body: some View {
    Canvas { context, canvasSize in
      CSLogoRenderer(time: nil).draw(in: &context, size: min(canvasSize.width, canvasSize.height))
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

// MARK: - Splash

/// Launch sequence: CRT power-on, the lock's pixels decrypt from cipher glyphs, the
/// feather writes in, the wordmark resolves, then the icon flies into the header.
/// Mirrors the prototype at claude.ai/artifact/SyrD2YxvStPfuFMRHWJ61H.
struct CryptoscreenSplashView: View {
  /// Where the header logo sits, in global coordinates. The icon lands there.
  var landingFrame: CGRect?
  /// Set when the launch has somewhere to be (e.g. a message link): jump to the exit.
  var skipRequested: Bool = false
  let onFinished: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startDate = Date()
  @State private var skipOffset: Double = 0
  @State private var didFinish = false

  // Timeline (ms)
  static let loadingStart: Double = 2500
  static let exitStart: Double = 4025
  static let exitDuration: Double = 900
  private static let flightDelay: Double = 140
  private static let flightDuration: Double = 640
  private static let wordmark = Array("cryptoscreen.app")
  private static let launchBackground = Color(red: 0, green: 0.122, blue: 0.047)

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        if reduceMotion {
          reducedMotionBody(size: proxy.size)
        } else {
          TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(startDate) * 1000 + skipOffset
            scene(t: t, proxy: proxy)
          }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
    .contentShape(Rectangle())
    .onTapGesture(perform: skip)
    .onChange(of: skipRequested) { _, requested in
      if requested { skip() }
    }
    .task(id: skipOffset) {
      let total = reduceMotion ? 900 : Self.exitStart + Self.exitDuration
      let remaining = total - (Date().timeIntervalSince(startDate) * 1000 + skipOffset)
      if remaining > 0 {
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
      }
      guard !Task.isCancelled else { return }
      finish()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("cryptoscreen")
    .accessibilityAddTraits(.isImage)
  }

  private func skip() {
    let now = Date().timeIntervalSince(startDate) * 1000 + skipOffset
    if now < Self.exitStart {
      skipOffset += Self.exitStart - now
    }
  }

  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    CSHaptics.tap(0.4)
    onFinished()
  }

  // MARK: Frame

  @ViewBuilder
  private func scene(t: Double, proxy: GeometryProxy) -> some View {
    let size = proxy.size
    let iconSize = min(200, size.width * 0.51)
    let iconRest = CGRect(x: (size.width - iconSize) / 2, y: size.height * 0.272, width: iconSize, height: iconSize)
    let exit = CSMotion.progress(t, from: Self.exitStart, duration: Self.exitDuration)
    let fade = 1 - CSMotion.progress(t, from: Self.exitStart + Self.flightDelay, duration: 760)

    ZStack(alignment: .topLeading) {
      // Launch screen colour, then the green bloom once the tube warms up.
      Self.launchBackground
        .opacity(fade)
      RadialGradient(
        colors: [Color(hex: 0x062B1D), Color(hex: 0x021A0E), Color(hex: 0x000F07)],
        center: UnitPoint(x: 0.46, y: 0.38),
        startRadius: 0,
        endRadius: max(size.width, size.height) * 0.75
      )
      .opacity(CSMotion.progress(t, from: 120, duration: 310) * fade)
      CSTheme.accent
        .opacity(0.12 * flash(t) * fade)

      powerLine(t: t, size: size)

      wordmark(t: t)
        .frame(width: size.width)
        .offset(y: iconRest.maxY + 38)
        .opacity(fade)

      loadingIndicators(t: t)
        .frame(width: size.width)
        .offset(y: iconRest.maxY + 98)
        .opacity(fade)

      CRTOverlay(time: t, size: size)
        .opacity(1 - CSMotion.progress(t, from: Self.exitStart + 300, duration: 500))

      icon(t: t, rest: iconRest, proxy: proxy)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .opacity(exit >= 1 ? 0 : 1)
  }

  private func flash(_ t: Double) -> Double {
    let rise = CSMotion.progress(t, from: 120, duration: 310)
    let decay = CSMotion.progress(t, from: 430, duration: 310)
    return rise * (1 - decay)
  }

  private func powerLine(t: Double, size: CGSize) -> some View {
    let p = CSMotion.progress(t, from: 0, duration: 380)
    let widen = min(1, p / 0.55)
    let collapse = max(0, (p - 0.55) / 0.45)
    return Rectangle()
      .fill(Color(hex: 0xD9FFE9))
      .frame(width: size.width * widen, height: 2 * (1 + 39 * collapse))
      .shadow(color: CSTheme.accent.opacity(0.7), radius: 18)
      .opacity(p > 0 && p < 1 ? 1 - collapse : 0)
      .position(x: size.width / 2, y: size.height / 2)
  }

  private func icon(t: Double, rest: CGRect, proxy: GeometryProxy) -> some View {
    let flight = CSMotion.bezier(
      CSMotion.progress(t, from: Self.exitStart + Self.flightDelay, duration: Self.flightDuration),
      0.65, 0, 0.2, 1
    )
    var target = rest
    if let landingFrame {
      let origin = proxy.frame(in: .global).origin
      target = landingFrame.offsetBy(dx: -origin.x, dy: -origin.y)
    }
    let rect = CGRect(
      x: CSMotion.lerp(rest.minX, target.minX, flight),
      y: CSMotion.lerp(rest.minY, target.minY, flight),
      width: CSMotion.lerp(rest.width, target.width, flight),
      height: CSMotion.lerp(rest.height, target.height, flight)
    )

    return ZStack(alignment: .topLeading) {
      Canvas { context, size in
        CSLogoRenderer(time: t).draw(in: &context, size: size.width)
      }
      scanLine(t: t, iconSize: rest.width)
    }
    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
    .offset(x: rect.minX, y: rect.minY)
  }

  /// The image reader's reveal-window scan line, sweeping the icon while loading.
  private func scanLine(t: Double, iconSize: CGFloat) -> some View {
    let k = iconSize / 200
    let visible = CSMotion.progress(t, from: Self.loadingStart, duration: 240) * (1 - CSMotion.progress(t, from: Self.exitStart, duration: 160))
    let cycle = max(0, t - Self.loadingStart) / 1050
    let leg = cycle.truncatingRemainder(dividingBy: 2)
    let phase = leg < 1 ? leg : 2 - leg
    let eased = CGFloat(CSMotion.bezier(phase, 0.42, 0, 0.58, 1))
    let width: CGFloat = iconSize - 28 * k
    let y: CGFloat = (30 + 137 * eased) * k
    return Capsule()
      .fill(CSTheme.accent)
      .frame(width: width, height: 3 * k)
      .shadow(color: CSTheme.accent.opacity(0.7), radius: 8 * k)
      .offset(x: 14 * k, y: y)
      .opacity(0.85 * visible)
  }

  // MARK: Wordmark

  /// Per-character scramble windows (ms): in, from 1.7 s with a 70 ms stagger; out, from the exit.
  private static let wordmarkTimings: [(inStart: Double, inEnd: Double, outStart: Double, outEnd: Double)] = {
    var generator = SplitMix64(seed: 0x5EED)
    let count = wordmark.count
    return (0..<count).map { index in
      let inStart = 1700 + Double(index) * 70
      let outStart = Double(count - index) * 22
      return (inStart, inStart + 760 * (0.55 + generator.unit() * 0.6), outStart, outStart + 300 * (0.55 + generator.unit() * 0.6))
    }
  }()

  private func wordmark(t: Double) -> some View {
    let exitT = t - Self.exitStart

    return HStack(spacing: 0) {
      ForEach(0..<Self.wordmark.count, id: \.self) { index in
        let character = Self.wordmark[index]
        let (inStart, inEnd, outStart, outEnd) = Self.wordmarkTimings[index]

        let scrambling = (t >= inStart && t < inEnd) || (exitT >= outStart && exitT < outEnd)
        let resolved = t >= inEnd && exitT < outStart

        Text(String(character))
          .opacity(resolved ? 1 : 0)
          .overlay {
            if scrambling {
              Text(String(CSMotion.glyph(seed: 500 + index, time: t)))
                .foregroundStyle(CSTheme.accent)
                .shadow(color: CSTheme.accent.opacity(0.7), radius: 7)
                .fixedSize()
            }
          }
      }
    }
    .font(.custom("AlphaLyrae-Medium", fixedSize: 34))
    .foregroundStyle(.white)
    .shadow(color: CSTheme.accent.opacity(0.18), radius: 7)
    .lineLimit(1)
  }

  // MARK: Loading

  private static let cellOnTimes: [Double] = (0..<12).map { k in
    loadingStart + (k <= 7 ? Double(k) * 95 : 665 + Double(k - 7) * 140)
  }

  private func loadingIndicators(t: Double) -> some View {
    let visible = CSMotion.progress(t, from: Self.loadingStart, duration: 300) * (1 - CSMotion.progress(t, from: Self.exitStart, duration: 200))
    let lit = Self.cellOnTimes.filter { t >= $0 }.count
    let status = lit >= 10 ? "ready" : (lit >= 5 ? "verifying device" : "sealing channel")

    return VStack(spacing: 13) {
      HStack(spacing: 4) {
        ForEach(0..<12, id: \.self) { index in
          RoundedRectangle(cornerRadius: 1.5)
            .fill(index < lit ? Color(hex: 0x5FBD86) : Color(hex: 0x5FBD86, opacity: 0.16))
            .frame(width: 9, height: 9)
            .shadow(color: CSTheme.accent.opacity(index < lit ? 0.6 : 0), radius: 4)
        }
      }
      Text(status.uppercased())
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .tracking(0.9)
        .foregroundStyle(Color(red: 0.56, green: 0.86, blue: 0.67).opacity(0.55))
    }
    .opacity(visible)
  }

  // MARK: Reduced motion

  private func reducedMotionBody(size: CGSize) -> some View {
    ZStack {
      RadialGradient(
        colors: [Color(hex: 0x062B1D), Color(hex: 0x000F07)],
        center: UnitPoint(x: 0.46, y: 0.38),
        startRadius: 0,
        endRadius: max(size.width, size.height) * 0.75
      )
      VStack(spacing: 38) {
        CryptoscreenLogoMark(size: min(200, size.width * 0.51))
        Text("cryptoscreen.app")
          .font(.custom("AlphaLyrae-Medium", fixedSize: 34))
          .foregroundStyle(.white)
      }
    }
  }
}

/// Phosphor grid, vignette, rolling bar and flicker from cryptoscreen.app.
private struct CRTOverlay: View {
  let time: Double
  let size: CGSize

  var body: some View {
    ZStack(alignment: .top) {
      CRTGrid()
      RadialGradient(
        colors: [.clear, Color(red: 0, green: 0.04, blue: 0.016).opacity(0.55)],
        center: .center,
        startRadius: min(size.width, size.height) * 0.58,
        endRadius: max(size.width, size.height) * 0.7
      )
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: CSTheme.accent.opacity(0.045), location: 0.55),
          .init(color: Color(red: 0.67, green: 1, blue: 0.82).opacity(0.07), location: 0.62),
          .init(color: .clear, location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: size.height * 0.34)
      .offset(y: rollOffset)
    }
    .frame(width: size.width, height: size.height, alignment: .top)
    .opacity(flicker)
    .allowsHitTesting(false)
  }

  private var rollOffset: CGFloat {
    let p = time.truncatingRemainder(dividingBy: 9000) / 9000
    return size.height * (-0.4 + 1.5 * p)
  }

  private var flicker: Double {
    let p = time.truncatingRemainder(dividingBy: 6000) / 6000
    if p >= 0.41 && p < 0.42 { return 0.94 }
    if p >= 0.77 && p < 0.78 { return 0.97 }
    return 1
  }
}

/// 4 pt phosphor cells: a dark scan gap, a faint green scan line and faint green columns.
private struct CRTGrid: View {
  var body: some View {
    Canvas { context, size in
      var gaps = Path(), scans = Path(), columns = Path()
      var y: CGFloat = 0
      while y < size.height {
        gaps.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
        scans.addRect(CGRect(x: 0, y: y + 1, width: size.width, height: 1))
        y += 4
      }
      var x: CGFloat = 0
      while x < size.width {
        columns.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
        x += 4
      }
      context.fill(gaps, with: .color(.black.opacity(0.26)))
      context.fill(scans, with: .color(CSTheme.accent.opacity(0.075)))
      context.fill(columns, with: .color(CSTheme.accent.opacity(0.07)))
    }
    .drawingGroup()
  }
}

/// Reports the header logo's frame so the splash knows where to land.
struct CSBrandMarkFrameKey: PreferenceKey {
  static let defaultValue: CGRect? = nil
  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
    value = nextValue() ?? value
  }
}

#Preview("Splash") {
  CryptoscreenSplashView(onFinished: {})
}

#Preview("Logo mark") {
  HStack(spacing: 20) {
    CryptoscreenLogoMark(size: 40)
    CryptoscreenLogoMark(size: 120)
  }
  .padding()
  .background(CSTheme.background)
}
