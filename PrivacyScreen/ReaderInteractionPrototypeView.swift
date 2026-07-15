import SwiftUI
import UIKit

#if !APPCLIP && (DEBUG || READER_LAB)
enum ReaderInteractionMode: String, CaseIterable, Identifiable {
  case classic
  case flashlight
  case eraser
  case sand
  case elasticWeb

  var id: String { rawValue }

  var title: String {
    switch self {
    case .classic:
      return "Classic"
    case .flashlight:
      return "Flashlight"
    case .eraser:
      return "Eraser"
    case .sand:
      return "Sand"
    case .elasticWeb:
      return "Web"
    }
  }

  var systemImage: String {
    switch self {
    case .classic:
      return "hand.raised.fill"
    case .flashlight:
      return "lightbulb.fill"
    case .eraser:
      return "eraser.fill"
    case .sand:
      return "circle.grid.cross.fill"
    case .elasticWeb:
      return "point.topleft.down.curvedto.point.bottomright.up"
    }
  }

  var toolLabel: String {
    switch self {
    case .classic:
      return "Cover target"
    case .flashlight:
      return "Light"
    case .eraser:
      return "Eraser"
    case .sand:
      return "Brush"
    case .elasticWeb:
      return "Hook"
    }
  }
}

struct ReaderInteractionPrototypeView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedMode: ReaderInteractionMode = .flashlight
  @State private var contentKind: ReaderLabContentKind = .text
  @State private var toolMode: ReaderLabToolMode = .tool
  @State private var imageShape: ReaderLabImageShape = .portrait

  var body: some View {
    ZStack {
      Color(red: 0.045, green: 0.047, blue: 0.043)
        .ignoresSafeArea()

      VStack(spacing: 14) {
        header

        ReaderInteractionPrototypeRenderer(
          mode: selectedMode,
          contentKind: contentKind,
          toolMode: toolMode,
          image: imageShape.image
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))

        controls
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 18)
    }
    .textSelection(.disabled)
    .preferredColorScheme(.dark)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Reader Lab")
          .font(.system(size: 25, weight: .semibold, design: .rounded))
          .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

        Text("Prototype-only reveal interactions")
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.56))
      }

      Spacer()

      Button {
        dismiss()
        readerLabSoftHaptic()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 15, weight: .bold))
          .frame(width: 40, height: 40)
          .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
          .background(Color.white.opacity(0.08), in: Circle())
          .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
      }
      .accessibilityLabel("Close reader lab")
    }
  }

  private var controls: some View {
    VStack(spacing: 10) {
      Picker("Content", selection: $contentKind) {
        ForEach(ReaderLabContentKind.allCases) { contentKind in
          Label(contentKind.title, systemImage: contentKind.systemImage)
            .tag(contentKind)
        }
      }
      .pickerStyle(.segmented)

      if contentKind == .image {
        Picker("Image shape", selection: $imageShape) {
          ForEach(ReaderLabImageShape.allCases) { shape in
            Text(shape.title).tag(shape)
          }
        }
        .pickerStyle(.segmented)
      }

      if selectedMode != .flashlight {
        Picker("Interaction", selection: $toolMode) {
          ForEach(ReaderLabToolMode.allCases) { mode in
            Label(mode.title, systemImage: mode.systemImage)
              .tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(ReaderInteractionMode.allCases) { mode in
            Button {
              selectedMode = mode
              readerLabSoftHaptic()
            } label: {
              Label(mode.title, systemImage: mode.systemImage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(selectedMode == mode ? Color(red: 0.045, green: 0.047, blue: 0.043) : Color(red: 0.965, green: 0.965, blue: 0.92))
                .background(selectedMode == mode ? Color(red: 0.48, green: 1.0, blue: 0.70) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(selectedMode == mode ? 0 : 0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}

private enum ReaderLabContentKind: String, CaseIterable, Identifiable {
  case text
  case image

  var id: String { rawValue }

  var title: String {
    switch self {
    case .text:
      return "Text"
    case .image:
      return "Image"
    }
  }

  var systemImage: String {
    switch self {
    case .text:
      return "text.alignleft"
    case .image:
      return "photo.fill"
    }
  }
}

private enum ReaderLabToolMode: String, CaseIterable, Identifiable {
  case tool
  case hand

  var id: String { rawValue }

  var title: String {
    switch self {
    case .tool:
      return "Tool"
    case .hand:
      return "Hand"
    }
  }

  var systemImage: String {
    switch self {
    case .tool:
      return "wand.and.stars"
    case .hand:
      return "hand.draw.fill"
    }
  }
}

private enum ReaderLabImageShape: String, CaseIterable, Identifiable {
  case portrait
  case landscape

  var id: String { rawValue }

  var title: String {
    switch self {
    case .portrait:
      return "Portrait"
    case .landscape:
      return "Landscape"
    }
  }

  var image: UIImage {
    switch self {
    case .portrait:
      return readerLabDemoImage()
    case .landscape:
      return readerLabDemoImage().readerLabLandscapeCrop()
    }
  }
}

private struct ReaderInteractionPrototypeRenderer: View {
  let mode: ReaderInteractionMode
  let contentKind: ReaderLabContentKind
  let toolMode: ReaderLabToolMode
  let image: UIImage

  @State private var toolLocation: CGPoint = .zero
  @State private var didInitializeToolLocation = false
  @State private var revealTrail: [CGPoint] = []
  @State private var imageScale: CGFloat = 1
  @State private var lastImageScale: CGFloat = 1
  @State private var imageOffset: CGSize = .zero
  @State private var lastImageOffset: CGSize = .zero

  private var isToolActive: Bool {
    toolMode == .tool && mode != .flashlight
  }

  private var effectiveToolMode: ReaderLabToolMode {
    mode == .flashlight ? .tool : toolMode
  }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size

      ZStack {
        Color(red: 0.035, green: 0.036, blue: 0.033)

        ReaderLabContentSurface(
          contentKind: contentKind,
          image: image,
          imageScale: imageScale,
          imageOffset: imageOffset,
          scrollDisabled: isToolActive
        )

        ReaderLabCoverLayer(
          mode: mode,
          contentKind: contentKind,
          image: image,
          imageScale: imageScale,
          imageOffset: imageOffset,
          toolLocation: normalizedToolLocation(in: size),
          revealTrail: revealTrail
        )

        if mode == .elasticWeb {
          ReaderLabElasticWebOverlay(toolLocation: normalizedToolLocation(in: size))
            .allowsHitTesting(false)
        }

        if mode == .flashlight {
          ReaderLabFlashlightBeamOverlay(toolLocation: normalizedToolLocation(in: size))
            .allowsHitTesting(false)
        }

        if mode == .flashlight {
          ReaderLabToolHandle(
            mode: mode,
            toolMode: effectiveToolMode,
            location: normalizedToolLocation(in: size)
          )
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
              .onChanged { value in
                updateToolLocation(value.location, in: size)
              }
          )
        } else {
          ReaderLabToolHandle(
            mode: mode,
            toolMode: effectiveToolMode,
            location: normalizedToolLocation(in: size)
          )
          .allowsHitTesting(false)
        }

        VStack {
          ReaderLabHint(mode: mode, toolMode: effectiveToolMode, contentKind: contentKind)
            .padding(.top, 12)
            .padding(.horizontal, 12)

          Spacer()
        }
      }
      .contentShape(Rectangle())
      .overlay {
        if isToolActive || (contentKind == .image && toolMode == .hand) {
          Color.clear
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                  if isToolActive {
                    updateToolLocation(value.location, in: size)
                  } else if contentKind == .image {
                    updateImageOffset(value.translation)
                  }
                }
                .onEnded { _ in
                  if contentKind == .image && toolMode == .hand {
                    lastImageOffset = imageOffset
                  }
                }
            )
            .simultaneousGesture(
              MagnificationGesture()
                .onChanged { value in
                  guard contentKind == .image && toolMode == .hand else {
                    return
                  }

                  imageScale = min(max(lastImageScale * value, 1), 4)
                }
                .onEnded { _ in
                  guard contentKind == .image && toolMode == .hand else {
                    return
                  }

                  imageScale = min(max(imageScale, 1), 4)
                  lastImageScale = imageScale
                }
            )
        }
      }
      .onAppear {
        initializeToolLocationIfNeeded(in: size)
      }
      .onChange(of: size) { _, newSize in
        initializeToolLocationIfNeeded(in: newSize)
      }
      .onChange(of: mode) { _, _ in
        resetRevealTrail(keeping: normalizedToolLocation(in: size))
      }
      .onChange(of: contentKind) { _, _ in
        resetImageTransform()
        resetRevealTrail(keeping: normalizedToolLocation(in: size))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func normalizedToolLocation(in size: CGSize) -> CGPoint {
    if didInitializeToolLocation {
      return CGPoint(
        x: min(max(toolLocation.x, 24), max(size.width - 24, 24)),
        y: min(max(toolLocation.y, 72), max(size.height - 72, 72))
      )
    }

    return CGPoint(x: size.width * 0.5, y: size.height * 0.42)
  }

  private func initializeToolLocationIfNeeded(in size: CGSize) {
    guard !didInitializeToolLocation, size.width > 1, size.height > 1 else {
      return
    }

    let initialLocation = CGPoint(x: size.width * 0.5, y: size.height * 0.42)
    toolLocation = initialLocation
    revealTrail = [initialLocation]
    didInitializeToolLocation = true
  }

  private func updateToolLocation(_ location: CGPoint, in size: CGSize) {
    let clamped = CGPoint(
      x: min(max(location.x, 24), max(size.width - 24, 24)),
      y: min(max(location.y, 72), max(size.height - 72, 72))
    )

    toolLocation = clamped

    switch mode {
    case .eraser, .sand:
      if revealTrail.last.map({ hypot($0.x - clamped.x, $0.y - clamped.y) > 10 }) ?? true {
        revealTrail.append(clamped)
        if revealTrail.count > 160 {
          revealTrail.removeFirst(revealTrail.count - 160)
        }
      }
    default:
      revealTrail = [clamped]
    }
  }

  private func updateImageOffset(_ translation: CGSize) {
    imageOffset = CGSize(
      width: lastImageOffset.width + translation.width,
      height: lastImageOffset.height + translation.height
    )
  }

  private func resetRevealTrail(keeping location: CGPoint) {
    revealTrail = [location]
  }

  private func resetImageTransform() {
    imageScale = 1
    lastImageScale = 1
    imageOffset = .zero
    lastImageOffset = .zero
  }
}

private struct ReaderLabContentSurface: View {
  let contentKind: ReaderLabContentKind
  let image: UIImage
  let imageScale: CGFloat
  let imageOffset: CGSize
  let scrollDisabled: Bool

  var body: some View {
    switch contentKind {
    case .text:
      ScrollView(.vertical, showsIndicators: false) {
        Text(readerLabMessage)
          .font(.system(size: 20, weight: .regular, design: .rounded))
          .lineSpacing(8)
          .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 22)
          .padding(.top, 84)
          .padding(.bottom, 140)
      }
      .scrollDisabled(scrollDisabled)
    case .image:
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .scaleEffect(imageScale)
        .offset(imageOffset)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
  }
}

private struct ReaderLabCoverLayer: View {
  let mode: ReaderInteractionMode
  let contentKind: ReaderLabContentKind
  let image: UIImage
  let imageScale: CGFloat
  let imageOffset: CGSize
  let toolLocation: CGPoint
  let revealTrail: [CGPoint]

  var body: some View {
    ZStack {
      coverSurface

      ReaderLabRevealMask(mode: mode, toolLocation: toolLocation, revealTrail: revealTrail)
        .blendMode(.destinationOut)
    }
    .compositingGroup()
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private var coverSurface: some View {
    switch contentKind {
    case .text:
      ReaderLabTextCover(mode: mode)
    case .image:
      Image(uiImage: image.readerLabPixelated())
        .resizable()
        .scaledToFit()
        .scaleEffect(imageScale)
        .offset(imageOffset)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(ReaderLabTextCover(mode: mode).opacity(mode == .sand ? 0.54 : 0.34))
    }
  }
}

private struct ReaderLabRevealMask: View {
  let mode: ReaderInteractionMode
  let toolLocation: CGPoint
  let revealTrail: [CGPoint]

  var body: some View {
    Canvas { context, size in
      switch mode {
      case .classic:
        let rect = CGRect(x: 0, y: size.height * 0.24, width: size.width, height: size.height * 0.22)
        context.fill(Path(roundedRect: rect, cornerRadius: 14), with: .color(.black))
      case .flashlight:
        drawFlashlightCone(in: &context, at: toolLocation)
      case .eraser:
        for point in revealTrail {
          drawRadialReveal(in: &context, at: point, radius: 34)
        }
      case .sand:
        for point in revealTrail {
          drawRadialReveal(in: &context, at: point, radius: 48)
        }
      case .elasticWeb:
        let horizontal = CGRect(x: 0, y: toolLocation.y - 38, width: size.width, height: 76)
        let vertical = CGRect(x: toolLocation.x - 34, y: 0, width: 68, height: size.height)
        context.fill(Path(ellipseIn: horizontal), with: .color(.black.opacity(0.82)))
        context.fill(Path(ellipseIn: vertical), with: .color(.black.opacity(0.62)))
        drawRadialReveal(in: &context, at: toolLocation, radius: 54)
      }
    }
  }

  private func drawRadialReveal(in context: inout GraphicsContext, at point: CGPoint, radius: CGFloat) {
    let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    let gradient = Gradient(stops: [
      .init(color: .black, location: 0),
      .init(color: .black.opacity(0.94), location: 0.58),
      .init(color: .black.opacity(0.0), location: 1)
    ])
    context.fill(Path(ellipseIn: rect), with: .radialGradient(gradient, center: point, startRadius: 0, endRadius: radius))
  }

  private func drawFlashlightCone(in context: inout GraphicsContext, at point: CGPoint) {
    let apex = CGPoint(x: point.x, y: point.y - 8)
    let height: CGFloat = 78

    for step in 0..<5 {
      let spread = CGFloat(step) * 10
      let topY = apex.y - height - CGFloat(step) * 2
      let halfWidth = 42 + spread
      let opacity = 1.0 - Double(step) * 0.16
      var path = Path()
      path.move(to: CGPoint(x: apex.x - 5, y: apex.y))
      path.addLine(to: CGPoint(x: apex.x - halfWidth, y: topY))
      path.addLine(to: CGPoint(x: apex.x + halfWidth, y: topY))
      path.addLine(to: CGPoint(x: apex.x + 5, y: apex.y))
      path.closeSubpath()
      context.fill(path, with: .color(.black.opacity(opacity)))
    }
  }
}

private struct ReaderLabTextCover: View {
  let mode: ReaderInteractionMode

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Rectangle()
          .fill(baseColor)

        switch mode {
        case .classic, .flashlight:
          ReaderLabStaticGlyphs()
            .opacity(0.72)
        case .eraser:
          ReaderLabScribbleCover()
        case .sand:
          ReaderLabSandCover()
        case .elasticWeb:
          ReaderLabStaticGlyphs()
            .opacity(0.45)
          ReaderLabElasticLines(size: proxy.size, hook: CGPoint(x: proxy.size.width * 0.5, y: proxy.size.height * 0.42))
            .opacity(0.38)
        }
      }
    }
  }

  private var baseColor: Color {
    switch mode {
    case .sand:
      return Color(red: 0.52, green: 0.46, blue: 0.34).opacity(0.94)
    case .elasticWeb:
      return Color(red: 0.025, green: 0.026, blue: 0.025).opacity(0.90)
    default:
      return Color(red: 0.025, green: 0.026, blue: 0.025).opacity(0.94)
    }
  }
}

private struct ReaderLabStaticGlyphs: View {
  private let glyphs = Array("01#%@/\\{}<>+=-")

  var body: some View {
    GeometryReader { proxy in
      Canvas { context, size in
        let columns = max(Int(size.width / 14), 1)
        let rows = max(Int(size.height / 18), 1)
        let font = Font.system(size: 12, weight: .medium, design: .monospaced)

        for row in 0..<rows {
          for column in 0..<columns {
            let index = abs((row * 17 + column * 31) % glyphs.count)
            let text = Text(String(glyphs[index]))
              .font(font)
              .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(Double((index % 5) + 2) / 10.0))
            context.draw(text, at: CGPoint(x: CGFloat(column) * 14 + 5, y: CGFloat(row) * 18 + 8))
          }
        }
      }
    }
  }
}

private struct ReaderLabScribbleCover: View {
  var body: some View {
    Canvas { context, size in
      for index in 0..<72 {
        var path = Path()
        let y = CGFloat(index) / 72 * size.height
        let startX = CGFloat((index * 29) % 80) - 40
        path.move(to: CGPoint(x: startX, y: y))
        path.addCurve(
          to: CGPoint(x: size.width + 44, y: y + CGFloat((index % 5) - 2) * 11),
          control1: CGPoint(x: size.width * 0.28, y: y - CGFloat((index % 7) + 2) * 8),
          control2: CGPoint(x: size.width * 0.72, y: y + CGFloat((index % 6) + 1) * 9)
        )
        context.stroke(path, with: .color(Color(red: 0.92, green: 0.93, blue: 0.84).opacity(0.44)), lineWidth: CGFloat((index % 4) + 2))
      }
    }
  }
}

private struct ReaderLabSandCover: View {
  var body: some View {
    Canvas { context, size in
      let columns = max(Int(size.width / 5), 1)
      let rows = max(Int(size.height / 5), 1)

      for row in 0..<rows {
        for column in 0..<columns {
          let seed = (row * 73 + column * 37) % 100
          let opacity = 0.18 + Double(seed % 44) / 100.0
          let color = Color(
            red: 0.74 + Double(seed % 6) / 100.0,
            green: 0.65 + Double(seed % 9) / 100.0,
            blue: 0.43 + Double(seed % 5) / 100.0
          )
          let rect = CGRect(
            x: CGFloat(column) * 5 + CGFloat(seed % 3),
            y: CGFloat(row) * 5 + CGFloat((seed / 3) % 3),
            width: CGFloat((seed % 3) + 2),
            height: CGFloat((seed % 3) + 2)
          )
          context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
        }
      }
    }
  }
}

private struct ReaderLabFlashlightBeamOverlay: View {
  let toolLocation: CGPoint

  var body: some View {
    Canvas { context, _ in
      let accent = Color(red: 0.48, green: 1.0, blue: 0.70)
      let apex = CGPoint(x: toolLocation.x, y: toolLocation.y - 8)
      let height: CGFloat = 78

      for step in 0..<5 {
        let halfWidth = 42 + CGFloat(step) * 10
        let topY = apex.y - height - CGFloat(step) * 2
        var path = Path()
        path.move(to: CGPoint(x: apex.x - 5, y: apex.y))
        path.addLine(to: CGPoint(x: apex.x - halfWidth, y: topY))
        path.addLine(to: CGPoint(x: apex.x + halfWidth, y: topY))
        path.addLine(to: CGPoint(x: apex.x + 5, y: apex.y))
        path.closeSubpath()
        context.fill(path, with: .color(accent.opacity(0.12 / Double(step + 1))))
      }
    }
    .accessibilityHidden(true)
  }
}

private struct ReaderLabElasticWebOverlay: View {
  let toolLocation: CGPoint

  var body: some View {
    GeometryReader { proxy in
      ReaderLabElasticLines(size: proxy.size, hook: toolLocation)
        .allowsHitTesting(false)
    }
  }
}

private struct ReaderLabElasticLines: View {
  let size: CGSize
  let hook: CGPoint

  var body: some View {
    Canvas { context, _ in
      let lineColor = Color(red: 0.74, green: 0.90, blue: 0.86).opacity(0.42)
      let accentColor = Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.62)
      let anchors = elasticAnchors(in: size)

      for (index, anchor) in anchors.enumerated() {
        var path = Path()
        path.move(to: anchor)
        let pull = min(0.34 + CGFloat(index % 4) * 0.08, 0.58)
        let control = CGPoint(
          x: anchor.x + (hook.x - anchor.x) * pull,
          y: anchor.y + (hook.y - anchor.y) * pull
        )
        path.addQuadCurve(to: oppositeAnchor(for: anchor, in: size), control: control)
        context.stroke(path, with: .color(index % 3 == 0 ? accentColor : lineColor), lineWidth: index % 3 == 0 ? 1.3 : 0.8)
      }
    }
  }

  private func elasticAnchors(in size: CGSize) -> [CGPoint] {
    let verticalCount = 8
    let horizontalCount = 5
    var anchors: [CGPoint] = []

    for index in 0..<verticalCount {
      let y = CGFloat(index + 1) / CGFloat(verticalCount + 1) * size.height
      anchors.append(CGPoint(x: 0, y: y))
      anchors.append(CGPoint(x: size.width, y: y + CGFloat((index % 3) - 1) * 9))
    }

    for index in 0..<horizontalCount {
      let x = CGFloat(index + 1) / CGFloat(horizontalCount + 1) * size.width
      anchors.append(CGPoint(x: x, y: 0))
      anchors.append(CGPoint(x: x + CGFloat((index % 3) - 1) * 10, y: size.height))
    }

    return anchors
  }

  private func oppositeAnchor(for anchor: CGPoint, in size: CGSize) -> CGPoint {
    if anchor.x <= 0 {
      return CGPoint(x: size.width, y: size.height - anchor.y)
    }
    if anchor.x >= size.width {
      return CGPoint(x: 0, y: size.height - anchor.y)
    }
    if anchor.y <= 0 {
      return CGPoint(x: size.width - anchor.x, y: size.height)
    }
    return CGPoint(x: size.width - anchor.x, y: 0)
  }
}

private struct ReaderLabToolHandle: View {
  let mode: ReaderInteractionMode
  let toolMode: ReaderLabToolMode
  let location: CGPoint

  var body: some View {
    ZStack {
      if toolMode == .tool {
        Circle()
          .fill(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(mode == .flashlight ? 0.12 : 0.07))
          .frame(width: mode == .flashlight ? 118 : 82, height: mode == .flashlight ? 118 : 82)
          .blur(radius: mode == .flashlight ? 12 : 6)
      }

      Circle()
        .fill(toolMode == .tool ? Color(red: 0.48, green: 1.0, blue: 0.70) : Color.white.opacity(0.20))
        .frame(width: 48, height: 48)
        .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 6)

      Image(systemName: mode.systemImage)
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(Color(red: 0.045, green: 0.047, blue: 0.043))
    }
    .position(location)
    .opacity(toolMode == .tool ? 1 : 0.70)
  }
}

private struct ReaderLabHint: View {
  let mode: ReaderInteractionMode
  let toolMode: ReaderLabToolMode
  let contentKind: ReaderLabContentKind

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: toolMode.systemImage)
        .font(.system(size: 12, weight: .bold))

      Text(text)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.78)

      Spacer()
    }
    .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92).opacity(0.82))
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Color.black.opacity(0.32), in: Capsule())
    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
  }

  private var text: String {
    switch toolMode {
    case .tool:
      return "Drag the \(mode.toolLabel.lowercased()) to reveal."
    case .hand:
      return contentKind == .image ? "Drag or pinch the image." : "Scroll the message."
    }
  }
}

private let readerLabMessage = """
The address is hidden under the old platform clock. Drag the tool across the screen and reveal only what you need.

This prototype is not changing the real message format yet. It is a playground for reading styles: light, eraser, sand, and elastic web.

Longer notes should still be usable. With the flashlight, scroll normally and drag the light by its handle. The other prototype tools still keep separate Tool and Hand controls.

For images, Hand moves the image while Tool moves the reveal object. The production version can reuse the same idea after we decide which styles feel worth shipping.
"""

private func readerLabDemoImage() -> UIImage {
  if let image = UIImage(named: "DemoCard") {
    return image
  }

  let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200))
  return renderer.image { context in
    UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
    UIColor(red: 0.76, green: 0.86, blue: 0.70, alpha: 1).setFill()
    let title = "Reader Lab" as NSString
    title.draw(
      at: CGPoint(x: 120, y: 360),
      withAttributes: [
        .font: UIFont.systemFont(ofSize: 72, weight: .semibold),
        .foregroundColor: UIColor(red: 0.76, green: 0.86, blue: 0.70, alpha: 1)
      ]
    )
  }
}

private func readerLabSoftHaptic() {
  UIImpactFeedbackGenerator(style: .soft).impactOccurred()
}

private extension UIImage {
  func readerLabPixelated() -> UIImage {
    let targetWidth: CGFloat = 28
    let scaleFactor = max(size.width / targetWidth, 1)
    let pixelSize = CGSize(width: max(size.width / scaleFactor, 1), height: max(size.height / scaleFactor, 1))
    let rendererFormat = UIGraphicsImageRendererFormat()
    rendererFormat.scale = 1

    let renderer = UIGraphicsImageRenderer(size: pixelSize, format: rendererFormat)
    return renderer.image { _ in
      draw(in: CGRect(origin: .zero, size: pixelSize))
    }
  }

  func readerLabLandscapeCrop() -> UIImage {
    let targetSize = CGSize(width: 1200, height: 760)
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { _ in
      let scale = max(targetSize.width / size.width, targetSize.height / size.height)
      let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
      let origin = CGPoint(
        x: (targetSize.width - drawSize.width) / 2,
        y: (targetSize.height - drawSize.height) / 2
      )
      draw(in: CGRect(origin: origin, size: drawSize))
    }
  }
}

#Preview("Reader Lab") {
  ReaderInteractionPrototypeView()
}
#endif
