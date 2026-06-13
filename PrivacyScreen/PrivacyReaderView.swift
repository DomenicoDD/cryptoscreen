import SwiftUI
import UIKit

private let sampleMessage = """
Lena, the transfer window closes at dusk. Keep the train receipt folded inside the blue notebook and do not answer any number that arrives without a name. If someone asks about the package, say the archive was already moved to the north desk. I will wait for the second bell, then send the final address in three short messages.

The clerk with the yellow scarf knows the counter-sign, but do not let her see the whole note at once. Read one line, move the page, and let the rest fall back into static. The platform cameras are angled toward the lockers, so stand under the broken departure board where the reflection is worst.

If the route changes, use the river entrance and count seven doors from the bakery before crossing. The last door has no number, only a brass plate and a scratched handle. Knock twice, pause, then knock once more. The room will be quiet, and the lights will already be low.

Delete this thread after the address arrives. If I miss the window, keep moving and wait for the morning train. Nobody else should see the plain text.
"""

struct PrivacyReaderView: View {
  let message: String
  let showsFontControls: Bool
  let bottomChromeBottomPadding: CGFloat
  let onClose: (() -> Void)?
  let onRevealPerformed: () -> Void
  let onScrollPerformed: () -> Void

  @StateObject private var proximitySensor = ProximitySensor()
  @State private var fontSize: CGFloat = 21
  @State private var revealedLineIDs: Set<Int> = []
  @State private var activeLineID: Int?
  @State private var pendingLineID: Int?
  @State private var revealDelayTask: Task<Void, Never>?
  @State private var hintDelayTask: Task<Void, Never>?
  @State private var showsTouchHint = false
  @State private var didReveal = false
  @State private var didScroll = false

  init(
    message: String = sampleMessage,
    showsFontControls: Bool = true,
    bottomChromeBottomPadding: CGFloat = 16,
    onClose: (() -> Void)? = nil,
    onRevealPerformed: @escaping () -> Void = {},
    onScrollPerformed: @escaping () -> Void = {}
  ) {
    self.message = message
    self.showsFontControls = showsFontControls
    self.bottomChromeBottomPadding = bottomChromeBottomPadding
    self.onClose = onClose
    self.onRevealPerformed = onRevealPerformed
    self.onScrollPerformed = onScrollPerformed
  }

  private var revealActive: Bool {
    proximitySensor.isRevealActive
  }

  var body: some View {
    GeometryReader { proxy in
      let touchButtonTop: CGFloat = 8
      let touchButtonSize = CGSize(width: max(proxy.size.width - 40, 180), height: 58)
      let touchZone = CGRect(
        x: (proxy.size.width - touchButtonSize.width) / 2,
        y: touchButtonTop,
        width: touchButtonSize.width,
        height: touchButtonSize.height
      )
      let revealTop = touchZone.maxY + 12
      let revealHeight = proxy.size.height * 0.22
      let revealZone = CGRect(x: 0, y: revealTop, width: proxy.size.width, height: revealHeight)
      let textWidth = proxy.size.width - 40
      let lines = TextLineWrapper.wrap(message, width: textWidth, fontSize: fontSize)
      let bottomReadingPadding = max(proxy.safeAreaInsets.bottom + 180, proxy.size.height - revealZone.midY + 96)

      ZStack(alignment: .top) {
        Color(red: 0.045, green: 0.047, blue: 0.043)
          .ignoresSafeArea()

        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(alignment: .leading, spacing: fontSize * 0.32) {
            ForEach(lines) { line in
              ScrambleLineText(
                text: line.text,
                lineID: line.id,
                fontSize: fontSize,
                isRevealed: revealActive && revealedLineIDs.contains(line.id),
                isActive: revealActive && activeLineID == line.id
              )
              .background(
                GeometryReader { lineProxy in
                  Color.clear.preference(
                    key: LineFramePreferenceKey.self,
                    value: [
                      LineFrame(
                        id: line.id,
                        frame: lineProxy.frame(in: .named("readerScreen"))
                      )
                    ]
                  )
                }
              )
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, revealTop + 8)
          .padding(.bottom, bottomReadingPadding)
        }
        .onPreferenceChange(LineFramePreferenceKey.self) { frames in
          updateRevealWindow(frames: frames, revealZone: revealZone)
        }

        RevealTouchTestButton(
          isRevealActive: revealActive,
          showsHint: showsTouchHint,
          frame: touchZone
        )

        RevealTouchCaptureView { isActive in
          proximitySensor.setScreenCoverActive(isActive)
        }
        .frame(width: touchZone.width, height: touchZone.height)
        .position(x: touchZone.midX, y: touchZone.midY)
        .accessibilityHidden(true)

        if didReveal && !didScroll {
          ScrollTeachingPill()
            .padding(.bottom, proxy.safeAreaInsets.bottom + 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        ReaderChrome(
          fontSize: $fontSize,
          showsFontControls: showsFontControls,
          onClose: onClose
        )
        .padding(.bottom, proxy.safeAreaInsets.bottom + bottomChromeBottomPadding)
        .padding(.horizontal, 16)
      }
      .coordinateSpace(name: "readerScreen")
      .textSelection(.disabled)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("readerScreen"))
          .onChanged { value in
            markScrolledIfNeeded(value.translation)
          }
      )
      .onAppear {
        UIApplication.shared.isIdleTimerDisabled = true
        proximitySensor.start()
        hintDelayTask?.cancel()
        hintDelayTask = Task {
          try? await Task.sleep(nanoseconds: 500_000_000)
          guard !Task.isCancelled else {
            return
          }

          await MainActor.run {
            withAnimation(.easeOut(duration: 0.22)) {
              showsTouchHint = true
            }
          }
        }
      }
      .onDisappear {
        UIApplication.shared.isIdleTimerDisabled = false
        proximitySensor.stop()
        revealDelayTask?.cancel()
        hintDelayTask?.cancel()
      }
      .onChange(of: revealActive) { _, isActive in
        if isActive, activeLineID != nil {
          Haptics.lineTranslated()
        }

        if isActive {
          markRevealed()
        }
      }
    }
  }

  private func markRevealed() {
    guard !didReveal else {
      return
    }

    didReveal = true
    onRevealPerformed()
  }

  private func markScrolledIfNeeded(_ translation: CGSize) {
    guard !didScroll, abs(translation.height) > 34 else {
      return
    }

    didScroll = true
    onScrollPerformed()
  }

  private func updateRevealWindow(frames: [LineFrame], revealZone: CGRect) {
    let revealActivationZone = revealZone.insetBy(dx: 0, dy: 4)
    let visibleLineIDs = Set(
      frames
        .filter { revealActivationZone.contains(CGPoint(x: revealZone.midX, y: $0.frame.midY)) }
        .map(\.id)
    )

    if revealedLineIDs != visibleLineIDs {
      revealedLineIDs = visibleLineIDs
    }

    let targetLineID = frames
      .filter { revealActivationZone.contains(CGPoint(x: revealZone.midX, y: $0.frame.midY)) }
      .min { lhs, rhs in
        abs(lhs.frame.midY - revealZone.midY) < abs(rhs.frame.midY - revealZone.midY)
      }?
      .id

    guard targetLineID != pendingLineID else {
      return
    }

    pendingLineID = targetLineID
    revealDelayTask?.cancel()

    guard let targetLineID else {
      activeLineID = nil
      return
    }

    revealDelayTask = Task {
      try? await Task.sleep(nanoseconds: 95_000_000)

      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        guard pendingLineID == targetLineID else {
          return
        }

        if activeLineID != targetLineID {
          activeLineID = targetLineID

          if proximitySensor.isRevealActive {
            Haptics.lineTranslated()
          }
        }
      }
    }
  }
}

private struct RevealTouchCaptureView: UIViewRepresentable {
  let onActiveChanged: (Bool) -> Void

  func makeUIView(context: Context) -> RevealTouchCaptureUIView {
    let view = RevealTouchCaptureUIView()
    view.onActiveChanged = onActiveChanged
    return view
  }

  func updateUIView(_ uiView: RevealTouchCaptureUIView, context: Context) {
    uiView.onActiveChanged = onActiveChanged
  }

  static func dismantleUIView(_ uiView: RevealTouchCaptureUIView, coordinator: ()) {
    uiView.reset()
  }
}

private final class RevealTouchCaptureUIView: UIView {
  var onActiveChanged: ((Bool) -> Void)?

  private var activeTouchIDs: Set<ObjectIdentifier> = []
  private var isActive = false
  private let touchSlop: CGFloat = 16

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isMultipleTouchEnabled = true
    isOpaque = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.contains(point)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    updateTrackedTouches(touches)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    updateTrackedTouches(touches)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    removeTrackedTouches(touches)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    removeTrackedTouches(touches)
  }

  func reset() {
    activeTouchIDs.removeAll()
    publishActiveState()
  }

  private func updateTrackedTouches(_ touches: Set<UITouch>) {
    let activeBounds = bounds.insetBy(dx: -touchSlop, dy: -touchSlop)

    for touch in touches {
      let touchID = ObjectIdentifier(touch)

      if activeBounds.contains(touch.location(in: self)) {
        activeTouchIDs.insert(touchID)
      } else {
        activeTouchIDs.remove(touchID)
      }
    }

    publishActiveState()
  }

  private func removeTrackedTouches(_ touches: Set<UITouch>) {
    for touch in touches {
      activeTouchIDs.remove(ObjectIdentifier(touch))
    }

    publishActiveState()
  }

  private func publishActiveState() {
    let nextValue = !activeTouchIDs.isEmpty

    guard isActive != nextValue else {
      return
    }

    isActive = nextValue
    onActiveChanged?(nextValue)
  }
}

private struct ScrambleLineText: View {
  let text: String
  let lineID: Int
  let fontSize: CGFloat
  let isRevealed: Bool
  let isActive: Bool

  @State private var displayedText = ""
  @State private var animationTask: Task<Void, Never>?

  private var hiddenText: String {
    CipherText.hiddenText(for: text, seed: lineID)
  }

  private var visibleText: String {
    guard isRevealed else {
      return displayedText.isEmpty ? hiddenText : displayedText
    }

    if displayedText.isEmpty || displayedText == hiddenText {
      return text
    }

    return displayedText
  }

  var body: some View {
    Text(visibleText)
      .font(.system(size: fontSize, weight: isActive ? .semibold : .regular, design: .monospaced))
      .foregroundStyle(isRevealed ? Color(red: 0.965, green: 0.965, blue: 0.92) : Color.white.opacity(0.34))
      .lineLimit(1)
      .minimumScaleFactor(0.86)
      .frame(maxWidth: .infinity, minHeight: fontSize * 1.35, alignment: .leading)
      .shadow(color: isActive ? Color(red: 0.3, green: 1.0, blue: 0.66).opacity(0.28) : .clear, radius: 8, y: 1)
      .accessibilityLabel(isRevealed ? "Revealed message line" : "Encrypted message line")
      .privacySensitive()
      .onAppear {
        displayedText = isRevealed ? text : hiddenText
      }
      .onDisappear {
        animationTask?.cancel()
      }
      .onChange(of: isRevealed) { _, _ in
        restartAnimation()
      }
      .onChange(of: text) { _, _ in
        restartAnimation()
      }
  }

  private func restartAnimation() {
    animationTask?.cancel()

    guard isRevealed else {
      withAnimation(.easeOut(duration: 0.12)) {
        displayedText = hiddenText
      }
      return
    }

    animationTask = Task {
      let tickCount = 10

      for tick in 0..<tickCount {
        guard !Task.isCancelled else {
          return
        }

        let progress = Double(tick + 1) / Double(tickCount)
        let nextText = CipherText.resolvingText(for: text, seed: lineID, progress: progress, tick: tick)

        await MainActor.run {
          withAnimation(.linear(duration: 0.035)) {
            displayedText = nextText
          }
        }

        try? await Task.sleep(nanoseconds: 34_000_000)
      }

      await MainActor.run {
        withAnimation(.easeOut(duration: 0.08)) {
          displayedText = text
        }
      }
    }
  }
}

private struct ReaderChrome: View {
  @Binding var fontSize: CGFloat
  let showsFontControls: Bool
  let onClose: (() -> Void)?

  var body: some View {
    VStack {
      Spacer()

      HStack(alignment: .bottom) {
        if let onClose {
          Button {
            onClose()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .bold))
              .frame(width: 50, height: 50)
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
              .background(.ultraThinMaterial, in: Circle())
              .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
          }
          .accessibilityLabel("Close preview")
        }

        Spacer()

        if showsFontControls {
          HStack(spacing: 6) {
            Button {
              fontSize = max(16, fontSize - 1)
              Haptics.buttonTap()
            } label: {
              Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
            }
            .disabled(fontSize <= 16)
            .accessibilityLabel("Decrease font size")

            Text("\(Int(fontSize))")
              .font(.system(size: 13, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
              .frame(width: 34)

            Button {
              fontSize = min(30, fontSize + 1)
              Haptics.buttonTap()
            } label: {
              Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
            }
            .disabled(fontSize >= 30)
            .accessibilityLabel("Increase font size")
          }
          .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
          .padding(6)
          .background(.ultraThinMaterial, in: Capsule())
          .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
        }
      }
    }
  }
}

private struct RevealTouchTestButton: View {
  let isRevealActive: Bool
  let showsHint: Bool
  let frame: CGRect

  var body: some View {
    HStack(spacing: 0) {
      if showsHint {
        Text("Cover this part with your hand")
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.78)
      }
    }
    .frame(width: frame.width, height: frame.height)
    .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(isRevealActive ? 1 : 0.82))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          Color(red: 0.48, green: 1.0, blue: 0.70).opacity(isRevealActive ? 0.88 : 0.56),
          style: StrokeStyle(lineWidth: 1.3, dash: [5, 5])
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .opacity(showsHint || isRevealActive ? 1 : 0.01)
    .position(x: frame.midX, y: frame.midY)
    .animation(.easeInOut(duration: 0.18), value: isRevealActive)
    .animation(.easeOut(duration: 0.22), value: showsHint)
    .accessibilityLabel("Reveal test area")
  }
}

private struct ScrollTeachingPill: View {
  @State private var movesUp = false

  var body: some View {
    VStack(spacing: 7) {
      ZStack {
        Capsule()
          .stroke(
            Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.62),
            style: StrokeStyle(lineWidth: 1.25, dash: [5, 5])
          )
          .frame(width: 38, height: 70)

        Circle()
          .fill(Color(red: 0.48, green: 1.0, blue: 0.70))
          .frame(width: 12, height: 12)
          .offset(y: movesUp ? -22 : 22)
      }
      .frame(width: 38, height: 70)

      Text("Scroll")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.82))
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(Color.black.opacity(0.001), in: Capsule())
    .onAppear {
      withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
        movesUp = true
      }
    }
    .accessibilityHidden(true)
  }
}

private struct LineFrame: Equatable {
  let id: Int
  let frame: CGRect
}

private struct LineFramePreferenceKey: PreferenceKey {
  static var defaultValue: [LineFrame] = []

  static func reduce(value: inout [LineFrame], nextValue: () -> [LineFrame]) {
    value.append(contentsOf: nextValue())
  }
}

private enum Haptics {
  @MainActor
  static func lineTranslated() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred(intensity: 0.34)
  }

  @MainActor
  static func buttonTap() {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.prepare()
    generator.impactOccurred(intensity: 0.28)
  }
}
