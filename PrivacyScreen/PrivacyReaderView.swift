import SwiftUI
import UIKit

private let sampleMessage = """
Lena, the transfer window closes at dusk. Keep the train receipt folded inside the blue notebook and do not answer any number that arrives without a name. If someone asks about the package, say the archive was already moved to the north desk. I will wait for the second bell, then send the final address in three short messages.

The clerk with the yellow scarf knows the counter-sign, but do not let her see the whole note at once. Read one line, move the page, and let the rest fall back into static. The platform cameras are angled toward the lockers, so stand under the broken departure board where the reflection is worst.

If the route changes, use the river entrance and count seven doors from the bakery before crossing. The last door has no number, only a brass plate and a scratched handle. Knock twice, pause, then knock once more. The room will be quiet, and the lights will already be low.

Delete this thread after the address arrives. If I miss the window, keep moving and wait for the morning train. Nobody else should see the plain text.
"""

private enum PrivacyReaderInteractionMode: String, CaseIterable, Identifiable, Equatable {
  case handOnScreen
  case flashlight

  var id: String { rawValue }

  var title: String {
    switch self {
    case .handOnScreen:
      return "Hand on screen"
    case .flashlight:
      return "Flashlight"
    }
  }

  var systemImage: String {
    switch self {
    case .handOnScreen:
      return "hand.raised.fill"
    case .flashlight:
      return "lightbulb.fill"
    }
  }
}

private struct FlashlightLineRevealSpec: Equatable {
  let lineID: Int
  let start: Int
  let length: Int

  var seed: Int {
    lineID &* 193 + start &* 17 + length
  }
}

struct PrivacyReaderView: View {
  let message: String
  let showsFontControls: Bool
  let showsHandPlacementGuide: Bool
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
  @State private var handPlacementGuideTask: Task<Void, Never>?
  @State private var showsTouchHint = false
  @State private var showsHandPlacementGuideOverlay = false
  @State private var didDismissHandPlacementGuide = false
  @State private var didReveal = false
  @State private var didScroll = false
  @State private var pendingExternalLink: PendingExternalLink?
  @State private var interactionMode: PrivacyReaderInteractionMode = .handOnScreen
  @State private var flashlightLocation: CGPoint = .zero
  @State private var didInitializeFlashlightLocation = false
  @State private var latestLineFrames: [LineFrame] = []
  @State private var flashlightRevealSpecs: [Int: FlashlightLineRevealSpec] = [:]

  init(
    message: String = sampleMessage,
    showsFontControls: Bool = true,
    showsHandPlacementGuide: Bool = false,
    bottomChromeBottomPadding: CGFloat = 16,
    onClose: (() -> Void)? = nil,
    onRevealPerformed: @escaping () -> Void = {},
    onScrollPerformed: @escaping () -> Void = {}
  ) {
    self.message = message
    self.showsFontControls = showsFontControls
    self.showsHandPlacementGuide = showsHandPlacementGuide
    self.bottomChromeBottomPadding = bottomChromeBottomPadding
    self.onClose = onClose
    self.onRevealPerformed = onRevealPerformed
    self.onScrollPerformed = onScrollPerformed
  }

  private var revealActive: Bool {
    interactionMode == .handOnScreen && proximitySensor.isRevealActive
  }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let touchButtonTop = max(proxy.safeAreaInsets.top + 44, 84)
      let touchButtonSize = CGSize(width: proxy.size.width * 0.70, height: 58)
      let touchZone = CGRect(
        x: (proxy.size.width - touchButtonSize.width) / 2,
        y: touchButtonTop,
        width: touchButtonSize.width,
        height: touchButtonSize.height
      )
      let touchCaptureZone = CGRect(
        x: 0,
        y: touchZone.minY - 15,
        width: proxy.size.width,
        height: touchZone.height + 30
      )
      let revealTop = touchZone.maxY + 12
      let revealHeight = proxy.size.height * 0.22
      let revealZone = CGRect(x: 0, y: revealTop, width: proxy.size.width, height: revealHeight)
      let textWidth = proxy.size.width - 40
      let lines = TextLineWrapper.wrap(message, width: textWidth, fontSize: fontSize)
      let bottomReadingPadding = max(proxy.safeAreaInsets.bottom + 180, proxy.size.height - revealZone.midY + 96)

      ZStack(alignment: .top) {
        ZStack(alignment: .top) {
          Color(red: 0.045, green: 0.047, blue: 0.043)
            .ignoresSafeArea()

          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: fontSize * 0.32) {
              ForEach(lines) { line in
                Group {
                  if interactionMode == .flashlight {
                    FlashlightLineText(
                      text: line.text,
                      lineID: line.id,
                      fontSize: fontSize,
                      revealSpec: flashlightRevealSpecs[line.id]
                    )
                  } else {
                    ScrambleLineText(
                      text: line.text,
                      attributedText: line.attributedText,
                      lineID: line.id,
                      fontSize: fontSize,
                      isRevealed: revealActive && revealedLineIDs.contains(line.id),
                      isActive: revealActive && activeLineID == line.id
                    )
                  }
                }
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
            latestLineFrames = frames

            switch interactionMode {
            case .handOnScreen:
              updateRevealWindow(frames: frames, revealZone: revealZone)
            case .flashlight:
              updateFlashlightReveal(frames: frames, lines: lines, size: size)
            }
          }

          if interactionMode == .handOnScreen {
            RevealTouchTestButton(
              isRevealActive: revealActive,
              showsHint: showsTouchHint,
              frame: touchZone
            )

            RevealTouchCaptureView { isActive in
              proximitySensor.setScreenCoverActive(isActive)
            }
            .frame(width: touchCaptureZone.width, height: touchCaptureZone.height)
            .position(x: touchCaptureZone.midX, y: touchCaptureZone.midY)
            .accessibilityHidden(true)
          }

          if interactionMode == .flashlight {
            ReaderFlashlightBeamOverlay(
              location: normalizedFlashlightLocation(in: size),
              fontSize: fontSize
            )
            .allowsHitTesting(false)

            ReaderFlashlightHandle(
              location: normalizedFlashlightLocation(in: size),
              fontSize: fontSize
            )
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .named("readerScreen"))
                .onChanged { value in
                  updateFlashlightLocation(value.location, in: size)
                }
            )
          }

          if didReveal && !didScroll {
            ScrollTeachingPill()
              .padding(.bottom, proxy.safeAreaInsets.bottom + 22)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
              .allowsHitTesting(false)
              .transition(.opacity.combined(with: .move(edge: .bottom)))
          }

          ReaderChrome(
            fontSize: $fontSize,
            interactionMode: $interactionMode,
            showsFontControls: showsFontControls,
            onClose: onClose
          )
          .padding(.bottom, proxy.safeAreaInsets.bottom + bottomChromeBottomPadding)
          .padding(.horizontal, 16)
        }
        .blur(radius: showsHandPlacementGuideOverlay ? 4 : 0)
        .animation(.easeOut(duration: 0.24), value: showsHandPlacementGuideOverlay)
        .allowsHitTesting(!showsHandPlacementGuideOverlay)

        if showsHandPlacementGuideOverlay {
          HandPlacementGuideOverlay(onOK: dismissHandPlacementGuide)
            .transition(.opacity)
            .zIndex(10)
        }
      }
      .coordinateSpace(name: "readerScreen")
      .textSelection(.disabled)
      .tint(Color(red: 0.48, green: 1.0, blue: 0.70))
      .environment(\.openURL, OpenURLAction { url in
        pendingExternalLink = PendingExternalLink(url: url)
        return .handled
      })
      .alert(item: $pendingExternalLink) { link in
        Alert(
          title: Text("This message is consumed"),
          message: Text("If you follow the link now, you won't be able to see the message again."),
          primaryButton: .default(Text("Continue to link")) {
            UIApplication.shared.open(link.url)
          },
          secondaryButton: .cancel(Text("Keep reading"))
        )
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("readerScreen"))
          .onChanged { value in
            if interactionMode == .flashlight,
               distance(from: value.startLocation, to: normalizedFlashlightLocation(in: size)) < 46 {
              return
            }

            markScrolledIfNeeded(value.translation)
          }
      )
      .onAppear {
        UIApplication.shared.isIdleTimerDisabled = true
        initializeFlashlightLocationIfNeeded(in: size)
        if interactionMode == .handOnScreen {
          proximitySensor.start()
        }
        presentHandPlacementGuideIfNeeded()
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
        handPlacementGuideTask?.cancel()
      }
      .onChange(of: revealActive) { _, isActive in
        if isActive, activeLineID != nil {
          Haptics.lineTranslated()
        }

        if isActive {
          markRevealed()
        }
      }
      .onChange(of: interactionMode) { _, mode in
        switch mode {
        case .handOnScreen:
          flashlightRevealSpecs.removeAll()
          proximitySensor.start()
        case .flashlight:
          proximitySensor.stop()
          revealedLineIDs.removeAll()
          activeLineID = nil
          pendingLineID = nil
          initializeFlashlightLocationIfNeeded(in: size)
          updateFlashlightReveal(frames: latestLineFrames, lines: lines, size: size)
        }

        Haptics.buttonTap()
      }
      .onChange(of: flashlightLocation) { _, _ in
        updateFlashlightReveal(frames: latestLineFrames, lines: lines, size: size)
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

  private func presentHandPlacementGuideIfNeeded() {
    guard showsHandPlacementGuide, !didDismissHandPlacementGuide else {
      return
    }

    withAnimation(.easeOut(duration: 0.24)) {
      showsHandPlacementGuideOverlay = true
    }

    handPlacementGuideTask?.cancel()
    handPlacementGuideTask = Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        dismissHandPlacementGuide()
      }
    }
  }

  private func dismissHandPlacementGuide() {
    guard showsHandPlacementGuideOverlay else {
      return
    }

    handPlacementGuideTask?.cancel()
    didDismissHandPlacementGuide = true

    withAnimation(.easeOut(duration: 0.42)) {
      showsHandPlacementGuideOverlay = false
    }
  }

  private func markScrolledIfNeeded(_ translation: CGSize) {
    guard !didScroll, abs(translation.height) > 34 else {
      return
    }

    didScroll = true
    onScrollPerformed()
  }

  private func initializeFlashlightLocationIfNeeded(in size: CGSize) {
    guard !didInitializeFlashlightLocation, size.width > 1, size.height > 1 else {
      return
    }

    flashlightLocation = CGPoint(
      x: max(size.width - 68, 64),
      y: max(size.height * 0.72, 150)
    )
    didInitializeFlashlightLocation = true
  }

  private func normalizedFlashlightLocation(in size: CGSize) -> CGPoint {
    guard didInitializeFlashlightLocation else {
      return CGPoint(x: max(size.width - 68, 64), y: max(size.height * 0.72, 150))
    }

    return CGPoint(
      x: min(max(flashlightLocation.x, 38), max(size.width - 38, 38)),
      y: min(max(flashlightLocation.y, 96), max(size.height - 84, 96))
    )
  }

  private func updateFlashlightLocation(_ location: CGPoint, in size: CGSize) {
    initializeFlashlightLocationIfNeeded(in: size)
    flashlightLocation = CGPoint(
      x: min(max(location.x, 38), max(size.width - 38, 38)),
      y: min(max(location.y, 96), max(size.height - 84, 96))
    )
    markRevealed()
  }

  private func updateFlashlightReveal(frames: [LineFrame], lines: [ReaderLine], size: CGSize) {
    guard interactionMode == .flashlight else {
      return
    }

    let location = normalizedFlashlightLocation(in: size)
    let linesByID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
    var nextSpecs: [Int: FlashlightLineRevealSpec] = [:]

    for frame in frames {
      guard let line = linesByID[frame.id],
            let spec = flashlightRevealSpec(for: line, frame: frame.frame, location: location) else {
        continue
      }

      nextSpecs[line.id] = spec
    }

    if flashlightRevealSpecs != nextSpecs {
      flashlightRevealSpecs = nextSpecs
    }
  }

  private func flashlightRevealSpec(
    for line: ReaderLine,
    frame: CGRect,
    location: CGPoint
  ) -> FlashlightLineRevealSpec? {
    let beamTop = location.y - fontSize * 3.35
    let beamBottom = location.y - max(fontSize * 0.42, 10)
    guard frame.midY >= beamTop, frame.midY <= beamBottom else {
      return nil
    }

    let characters = Array(line.text)
    guard !characters.isEmpty else {
      return nil
    }

    let characterAdvance = max(fontSize * 0.60, 1)
    let revealLength = min(characters.count, 9)
    let centerIndex = Int(((location.x - frame.minX) / characterAdvance).rounded(.toNearestOrAwayFromZero))
    guard centerIndex > -revealLength, centerIndex < characters.count + revealLength else {
      return nil
    }

    let start = min(max(centerIndex - revealLength / 2, 0), max(characters.count - revealLength, 0))
    return FlashlightLineRevealSpec(lineID: line.id, start: start, length: revealLength)
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

private struct HandPlacementGuideOverlay: View {
  let onOK: () -> Void

  @State private var countdownProgress = 0.0

  var body: some View {
    GeometryReader { proxy in
      let bottomPadding = max(proxy.safeAreaInsets.bottom + 34, 52)

      ZStack(alignment: .top) {
        Color.black.opacity(0.66)
          .ignoresSafeArea()

        VStack(spacing: 0) {
          Text("Cover the top area of the screen\nto decrypt the message.")
            .font(.system(size: 23, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .foregroundStyle(Color(red: 0.38, green: 0.78, blue: 0.55))
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 28)
            .padding(.top, max(proxy.safeAreaInsets.top + 86, 118))

          Image("HandsOnScreenGuide")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: min(proxy.size.width * 1.12, 520))
            .shadow(color: Color(red: 0.38, green: 0.78, blue: 0.55).opacity(0.28), radius: 16)
            .padding(.top, 72)

          Spacer(minLength: 24)

          HandPlacementOKButton(progress: countdownProgress, action: onOK)
            .frame(height: 58)
            .padding(.horizontal, 52)
            .padding(.bottom, bottomPadding)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
      }
      .accessibilityLabel("Hand placement guide")
      .onAppear {
        countdownProgress = 0

        withAnimation(.linear(duration: 5.0)) {
          countdownProgress = 1
        }
      }
    }
    .ignoresSafeArea()
  }
}

private struct HandPlacementOKButton: View {
  let progress: Double
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.22))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.38, green: 0.78, blue: 0.55), lineWidth: 1.3)
            )

          RoundedRectangle(cornerRadius: 8)
            .fill(Color(red: 0.38, green: 0.78, blue: 0.55))
            .frame(width: proxy.size.width * progress)
            .animation(.linear(duration: 5.0), value: progress)

          Text("ok")
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.38, green: 0.78, blue: 0.55))
            .frame(width: proxy.size.width, height: proxy.size.height)

          Text("ok")
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.035, green: 0.13, blue: 0.085))
            .frame(width: proxy.size.width, height: proxy.size.height)
            .frame(width: proxy.size.width * progress, alignment: .leading)
            .clipped()
            .animation(.linear(duration: 5.0), value: progress)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("OK")
    .accessibilityHint("Dismisses the hand placement guide")
  }
}

struct RevealTouchCaptureView: UIViewRepresentable {
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

final class RevealTouchCaptureUIView: UIView {
  var onActiveChanged: ((Bool) -> Void)?

  private var activeTouchIDs: Set<ObjectIdentifier> = []
  private var isActive = false
  private let touchSlop: CGFloat = 16
  private let releaseDelay: TimeInterval = 0.28
  private var pendingRelease: DispatchWorkItem?

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
    pendingRelease?.cancel()
    pendingRelease = nil
    activeTouchIDs.removeAll()
    publishActiveState(delaysRelease: false)
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

  private func publishActiveState(delaysRelease: Bool = true) {
    let nextValue = !activeTouchIDs.isEmpty

    guard isActive != nextValue else {
      return
    }

    if nextValue {
      pendingRelease?.cancel()
      pendingRelease = nil
      isActive = true
      onActiveChanged?(true)
      return
    }

    pendingRelease?.cancel()

    guard delaysRelease else {
      isActive = false
      onActiveChanged?(false)
      return
    }

    let release = DispatchWorkItem { [weak self] in
      guard let self, self.activeTouchIDs.isEmpty, self.isActive else {
        return
      }

      self.isActive = false
      self.pendingRelease = nil
      self.onActiveChanged?(false)
    }

    pendingRelease = release
    DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay, execute: release)
  }
}

private struct FlashlightLineText: View {
  let text: String
  let lineID: Int
  let fontSize: CGFloat
  let revealSpec: FlashlightLineRevealSpec?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedText = ""
  @State private var animationTask: Task<Void, Never>?

  private var hiddenText: String {
    CipherText.hiddenText(for: text, seed: lineID)
  }

  var body: some View {
    Text(displayedText.isEmpty ? hiddenText : displayedText)
      .font(.system(size: fontSize, weight: revealSpec == nil ? .regular : .semibold, design: .monospaced))
      .foregroundStyle(revealSpec == nil ? Color.white.opacity(0.34) : Color(red: 0.965, green: 0.965, blue: 0.92))
      .lineLimit(1)
      .minimumScaleFactor(0.86)
      .frame(maxWidth: .infinity, minHeight: fontSize * 1.35, alignment: .leading)
      .shadow(color: revealSpec == nil ? .clear : Color(red: 0.3, green: 1.0, blue: 0.66).opacity(0.24), radius: 8, y: 1)
      .accessibilityLabel(revealSpec == nil ? "Encrypted message line" : "Partially revealed message line")
      .privacySensitive()
      .onAppear {
        displayedText = renderedText(progress: revealSpec == nil ? 0 : 1, tick: 0)
      }
      .onDisappear {
        animationTask?.cancel()
      }
      .onChange(of: revealSpec) { _, _ in
        restartAnimation()
      }
      .onChange(of: text) { _, _ in
        restartAnimation()
      }
  }

  private func restartAnimation() {
    animationTask?.cancel()

    guard revealSpec != nil else {
      withAnimation(.easeOut(duration: reduceMotion ? 0.01 : 0.08)) {
        displayedText = hiddenText
      }
      return
    }

    guard !reduceMotion else {
      displayedText = renderedText(progress: 1, tick: 0)
      return
    }

    animationTask = Task {
      let tickCount = 6

      for tick in 0..<tickCount {
        guard !Task.isCancelled else {
          return
        }

        let progress = Double(tick + 1) / Double(tickCount)
        let nextText = renderedText(progress: progress, tick: tick)

        await MainActor.run {
          withAnimation(.linear(duration: 0.018)) {
            displayedText = nextText
          }
        }

        try? await Task.sleep(nanoseconds: 18_000_000)
      }

      await MainActor.run {
        withAnimation(.easeOut(duration: 0.04)) {
          displayedText = renderedText(progress: 1, tick: tickCount)
        }
      }
    }
  }

  private func renderedText(progress: Double, tick: Int) -> String {
    guard let revealSpec else {
      return hiddenText
    }

    var characters = Array(hiddenText)
    let originalCharacters = Array(text)
    guard revealSpec.start < originalCharacters.count else {
      return hiddenText
    }

    let end = min(revealSpec.start + revealSpec.length, originalCharacters.count)
    let segment = String(originalCharacters[revealSpec.start..<end])
    let resolvedSegment = Array(
      CipherText.resolvingText(
        for: segment,
        seed: revealSpec.seed,
        progress: progress,
        tick: tick
      )
    )

    for offset in 0..<resolvedSegment.count {
      let index = revealSpec.start + offset
      guard index < characters.count else {
        break
      }

      characters[index] = resolvedSegment[offset]
    }

    return String(characters)
  }
}

private struct ReaderFlashlightBeamOverlay: View {
  let location: CGPoint
  let fontSize: CGFloat

  var body: some View {
    Canvas { context, _ in
      let beamHeight = fontSize * 3.35
      let apex = CGPoint(x: location.x, y: location.y - 8)
      let beamTop = max(location.y - beamHeight, 0)
      let accent = Color(red: 0.48, green: 1.0, blue: 0.70)

      for step in 0..<5 {
        let inset = CGFloat(step)
        let width = fontSize * (3.9 + inset * 0.62)
        let opacity = 0.14 / Double(step + 1)
        var path = Path()
        path.move(to: CGPoint(x: apex.x - fontSize * 0.20, y: apex.y))
        path.addLine(to: CGPoint(x: apex.x - width / 2, y: beamTop - inset * 1.5))
        path.addLine(to: CGPoint(x: apex.x + width / 2, y: beamTop - inset * 1.5))
        path.addLine(to: CGPoint(x: apex.x + fontSize * 0.20, y: apex.y))
        path.closeSubpath()
        context.fill(path, with: .color(accent.opacity(opacity)))
      }

      let glowRect = CGRect(
        x: location.x - fontSize * 2.3,
        y: location.y - beamHeight - fontSize * 0.8,
        width: fontSize * 4.6,
        height: beamHeight + fontSize
      )
      let gradient = Gradient(stops: [
        .init(color: accent.opacity(0.22), location: 0),
        .init(color: accent.opacity(0.08), location: 0.42),
        .init(color: accent.opacity(0), location: 1)
      ])
      context.fill(
        Path(ellipseIn: glowRect),
        with: .radialGradient(gradient, center: CGPoint(x: location.x, y: location.y - beamHeight * 0.52), startRadius: 0, endRadius: fontSize * 2.6)
      )
    }
    .accessibilityHidden(true)
  }
}

private struct ReaderFlashlightHandle: View {
  let location: CGPoint
  let fontSize: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.14))
        .frame(width: 72, height: 72)
        .blur(radius: 8)

      Circle()
        .fill(Color(red: 0.48, green: 1.0, blue: 0.70))
        .frame(width: 54, height: 54)
        .overlay(Circle().stroke(Color.white.opacity(0.36), lineWidth: 1.2))
        .shadow(color: Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.24), radius: 14, y: 4)

      Image(systemName: "lightbulb.fill")
        .font(.system(size: 21, weight: .bold))
        .foregroundStyle(Color(red: 0.035, green: 0.047, blue: 0.04))
    }
    .frame(width: 84, height: 84)
    .position(location)
    .contentShape(Circle())
    .accessibilityLabel("Flashlight reveal")
    .accessibilityHint("Drag to reveal a small part of the message.")
  }
}

private struct ScrambleLineText: View {
  let text: String
  let attributedText: AttributedString
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
    lineText
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

  @ViewBuilder
  private var lineText: some View {
    if isRevealed && visibleText == text {
      Text(attributedText)
    } else {
      Text(visibleText)
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
  @Binding var interactionMode: PrivacyReaderInteractionMode
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

        ReaderModeSettingsMenu(selection: $interactionMode)
      }
    }
  }
}

private struct ReaderModeSettingsMenu: View {
  @Binding var selection: PrivacyReaderInteractionMode

  var body: some View {
    Menu {
      ForEach(PrivacyReaderInteractionMode.allCases) { mode in
        Button {
          selection = mode
        } label: {
          Label(mode.title, systemImage: mode == selection ? "checkmark" : mode.systemImage)
        }
      }
    } label: {
      Image(systemName: "gearshape.fill")
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 44, height: 44)
        .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.13), lineWidth: 1))
    }
    .accessibilityLabel("Reader settings")
    .accessibilityHint("Choose the reveal mode")
  }
}

struct RevealTouchTestButton: View {
  let isRevealActive: Bool
  let showsHint: Bool
  let frame: CGRect

  var body: some View {
    ZStack {
      HStack(spacing: 0) {
        if showsHint {
          Text("Cover this part with your hand")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
      }
    }
    .frame(width: frame.width, height: frame.height)
    .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.82))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.56),
          style: StrokeStyle(lineWidth: 1.3, dash: [5, 5])
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .opacity(isRevealActive ? 0 : (showsHint ? 1 : 0.01))
    .position(x: frame.midX, y: frame.midY)
    .animation(.easeInOut(duration: 0.20), value: isRevealActive)
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

private struct PendingExternalLink: Identifiable {
  let id = UUID()
  let url: URL
}

private struct LineFramePreferenceKey: PreferenceKey {
  static var defaultValue: [LineFrame] = []

  static func reduce(value: inout [LineFrame], nextValue: () -> [LineFrame]) {
    value.append(contentsOf: nextValue())
  }
}

private func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
  hypot(first.x - second.x, first.y - second.y)
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
