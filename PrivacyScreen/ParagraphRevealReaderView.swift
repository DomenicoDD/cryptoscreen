import SwiftUI
import UIKit

private let paragraphRevealSampleMessage = """
The first instruction is simple: read only the paragraph in front of you. The rest of the note should stay out of reach until you choose to move.

Hold the eye, slide with intent, and let this one section resolve. If the room changes or someone steps close, hide it again before moving on.

The second checkpoint is three streets north of the closed cinema. Wait under the narrow awning, not beside the glass doors, because the reflection makes the screen too easy to read.

When you need the next section, move one paragraph at a time. Nothing else should become plain text just because your thumb slipped or the page moved.

After the address has been memorized, lock the paragraph again. Leave no complete note on the display, and do not let the ritual become casual.
"""

struct ParagraphRevealReaderView: View {
  let message: String
  let bottomChromeBottomPadding: CGFloat
  let onClose: (() -> Void)?
  let onRevealPerformed: () -> Void
  let onScrollPerformed: () -> Void
  let relocksParagraphsOnNavigation: Bool

  @State private var paragraphs: [ParagraphRevealItem]
  @State private var activeParagraphIndex = 0
  @State private var scrollPosition: Int?
  @State private var isTransitioning = false
  @State private var didReportReveal = false
  @State private var didReportNavigation = false
  @State private var transitionTask: Task<Void, Never>?
  @State private var pendingExternalLink: ParagraphPendingExternalLink?

  init(
    message: String = paragraphRevealSampleMessage,
    bottomChromeBottomPadding: CGFloat = 16,
    onClose: (() -> Void)? = nil,
    onRevealPerformed: @escaping () -> Void = {},
    onScrollPerformed: @escaping () -> Void = {},
    relocksParagraphsOnNavigation: Bool = true
  ) {
    let parsedParagraphs = ParagraphRevealParser.parse(message)
    self.message = message
    self.bottomChromeBottomPadding = bottomChromeBottomPadding
    self.onClose = onClose
    self.onRevealPerformed = onRevealPerformed
    self.onScrollPerformed = onScrollPerformed
    self.relocksParagraphsOnNavigation = relocksParagraphsOnNavigation
    _paragraphs = State(initialValue: parsedParagraphs)
    _scrollPosition = State(initialValue: parsedParagraphs.first?.id)
  }

  private var activeParagraphID: Int? {
    paragraphs.indices.contains(activeParagraphIndex) ? paragraphs[activeParagraphIndex].id : nil
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .top) {
        ParagraphRevealPalette.background
          .ignoresSafeArea()

        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(spacing: 0) {
            ForEach(paragraphs) { paragraph in
              ParagraphRevealSection(
                paragraph: paragraph,
                previousParagraph: adjacentParagraph(before: paragraph.id),
                nextParagraph: adjacentParagraph(after: paragraph.id),
                isActive: paragraph.id == activeParagraphID,
                isTransitioning: isTransitioning,
                activeIndex: activeParagraphIndex,
                paragraphCount: paragraphs.count,
                bottomChromeBottomPadding: bottomChromeBottomPadding,
                onSliderComplete: {
                  toggleLockState(for: paragraph.id)
                },
                onPrevious: {
                  moveParagraph(by: -1)
                },
                onNext: {
                  moveParagraph(by: 1)
                }
              )
              .frame(width: proxy.size.width, height: proxy.size.height)
              .id(paragraph.id)
            }
          }
          .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollPosition)
        .ignoresSafeArea()
        .onChange(of: scrollPosition) { _, newValue in
          guard let paragraphID = newValue else {
            return
          }

          activateParagraph(id: paragraphID, reportsNavigation: true)
        }

        ParagraphRevealHeader(
          activeIndex: activeParagraphIndex,
          paragraphCount: paragraphs.count,
          onClose: onClose
        )
        .padding(.horizontal, 18)
        .padding(.top, proxy.safeAreaInsets.top + 10)
      }
      .textSelection(.disabled)
      .privacySensitive()
      .tint(ParagraphRevealPalette.accent)
      .environment(\.openURL, OpenURLAction { url in
        pendingExternalLink = ParagraphPendingExternalLink(url: url)
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
      .onAppear {
        UIApplication.shared.isIdleTimerDisabled = true
      }
      .onDisappear {
        UIApplication.shared.isIdleTimerDisabled = false
        transitionTask?.cancel()
      }
      .onChange(of: message) { _, newMessage in
        resetParagraphs(with: newMessage)
      }
    }
  }

  private func adjacentParagraph(before id: Int) -> ParagraphRevealItem? {
    guard let index = paragraphs.firstIndex(where: { $0.id == id }),
          index > paragraphs.startIndex else {
      return nil
    }

    return paragraphs[index - 1]
  }

  private func adjacentParagraph(after id: Int) -> ParagraphRevealItem? {
    guard let index = paragraphs.firstIndex(where: { $0.id == id }),
          paragraphs.indices.contains(index + 1) else {
      return nil
    }

    return paragraphs[index + 1]
  }

  private func moveParagraph(by offset: Int) {
    let nextIndex = min(max(activeParagraphIndex + offset, 0), max(paragraphs.count - 1, 0))
    guard nextIndex != activeParagraphIndex else {
      return
    }

    activateParagraph(index: nextIndex, reportsNavigation: true)
    withAnimation(.snappy(duration: 0.32, extraBounce: 0.02)) {
      scrollPosition = paragraphs[nextIndex].id
    }
  }

  private func activateParagraph(id: Int, reportsNavigation: Bool) {
    guard let index = paragraphs.firstIndex(where: { $0.id == id }) else {
      return
    }

    activateParagraph(index: index, reportsNavigation: reportsNavigation)
  }

  private func activateParagraph(index: Int, reportsNavigation: Bool) {
    guard paragraphs.indices.contains(index) else {
      return
    }

    let didChangeParagraph = activeParagraphIndex != index
    activeParagraphIndex = index
    paragraphs[index].hasBeenViewed = true

    if relocksParagraphsOnNavigation, didChangeParagraph {
      for paragraphIndex in paragraphs.indices {
        paragraphs[paragraphIndex].isUnlocked = false
      }
    }

    guard didChangeParagraph else {
      return
    }

    ParagraphRevealHaptics.navigation()
    markTransitioning()

    if reportsNavigation, !didReportNavigation {
      didReportNavigation = true
      onScrollPerformed()
    }
  }

  private func toggleLockState(for id: Int) {
    guard let index = paragraphs.firstIndex(where: { $0.id == id }),
          index == activeParagraphIndex else {
      return
    }

    let nextUnlockedState = !paragraphs[index].isUnlocked
    withAnimation(.easeInOut(duration: 0.28)) {
      paragraphs[index].isUnlocked = nextUnlockedState
      paragraphs[index].hasBeenViewed = true
    }

    if nextUnlockedState, !didReportReveal {
      didReportReveal = true
      onRevealPerformed()
    }
  }

  private func markTransitioning() {
    isTransitioning = true
    transitionTask?.cancel()
    transitionTask = Task {
      try? await Task.sleep(nanoseconds: 320_000_000)
      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        isTransitioning = false
      }
    }
  }

  private func resetParagraphs(with message: String) {
    let parsedParagraphs = ParagraphRevealParser.parse(message)
    paragraphs = parsedParagraphs
    activeParagraphIndex = 0
    scrollPosition = parsedParagraphs.first?.id
    isTransitioning = false
    didReportReveal = false
    didReportNavigation = false
  }
}

private struct ParagraphRevealSection: View {
  let paragraph: ParagraphRevealItem
  let previousParagraph: ParagraphRevealItem?
  let nextParagraph: ParagraphRevealItem?
  let isActive: Bool
  let isTransitioning: Bool
  let activeIndex: Int
  let paragraphCount: Int
  let bottomChromeBottomPadding: CGFloat
  let onSliderComplete: () -> Void
  let onPrevious: () -> Void
  let onNext: () -> Void

  var body: some View {
    GeometryReader { proxy in
      let topSafePadding = proxy.safeAreaInsets.top + 78
      let bottomSafePadding = proxy.safeAreaInsets.bottom + bottomChromeBottomPadding + 20
      let cardMaxHeight = min(max(proxy.size.height * 0.44, 278), 390)

      ZStack {
        VStack(spacing: 0) {
          if let previousParagraph {
            AdjacentParagraphPreview(paragraph: previousParagraph, edge: .previous)
              .padding(.horizontal, 24)
              .padding(.top, topSafePadding)
              .opacity(isActive ? 1 : 0.42)
          }

          Spacer(minLength: 0)

          if let nextParagraph {
            AdjacentParagraphPreview(paragraph: nextParagraph, edge: .next)
              .padding(.horizontal, 24)
              .padding(.bottom, bottomSafePadding)
              .opacity(isActive ? 1 : 0.42)
          }
        }
        .allowsHitTesting(false)

        VStack(spacing: 16) {
          Spacer(minLength: topSafePadding + 12)

          ParagraphRevealCard(
            paragraph: paragraph,
            isRevealed: isActive && paragraph.isUnlocked,
            isActive: isActive,
            maxHeight: cardMaxHeight
          )
          .padding(.horizontal, 20)

          ParagraphRevealSlideControl(
            mode: paragraph.isUnlocked && isActive ? .lock : .unlock,
            isEnabled: isActive && !isTransitioning,
            onComplete: onSliderComplete
          )
          .padding(.horizontal, 24)

          ParagraphRevealNavigator(
            activeIndex: activeIndex,
            paragraphCount: paragraphCount,
            onPrevious: onPrevious,
            onNext: onNext
          )
          .padding(.horizontal, 24)

          Spacer(minLength: bottomSafePadding + 12)
        }
      }
    }
  }
}

private struct ParagraphRevealHeader: View {
  let activeIndex: Int
  let paragraphCount: Int
  let onClose: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Cryptoscreen")
          .font(.system(size: 19, weight: .semibold, design: .rounded))
          .foregroundStyle(ParagraphRevealPalette.text)

        Text("Paragraph reveal")
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.52))
      }

      Spacer()

      Text("\(activeIndex + 1) / \(max(paragraphCount, 1))")
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.68))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.07), in: Capsule())
        .accessibilityLabel("Paragraph \(activeIndex + 1) of \(paragraphCount)")

      if let onClose {
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 15, weight: .bold))
            .frame(width: 42, height: 42)
            .foregroundStyle(ParagraphRevealPalette.text)
            .background(Color.white.opacity(0.08), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close message")
      }
    }
  }
}

private struct ParagraphRevealCard: View {
  let paragraph: ParagraphRevealItem
  let isRevealed: Bool
  let isActive: Bool
  let maxHeight: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(isRevealed ? 0.078 : 0.052))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(
              isRevealed
                ? ParagraphRevealPalette.accent.opacity(0.36)
                : Color.white.opacity(isActive ? 0.16 : 0.08),
              lineWidth: 1.2
            )
        )
        .shadow(color: isRevealed ? ParagraphRevealPalette.accent.opacity(0.16) : .clear, radius: 18, y: 4)

      ScrollView(.vertical, showsIndicators: false) {
        ParagraphRevealText(
          paragraph: paragraph,
          isRevealed: isRevealed,
          isActive: isActive
        )
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
      }
      .scrollBounceBehavior(.basedOnSize)

      if !isRevealed {
        HiddenParagraphOverlay(seed: paragraph.id)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .allowsHitTesting(false)
          .transition(.opacity)
      }

      if isRevealed {
        DecryptSweep()
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: 254, maxHeight: maxHeight)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .modifier(ParagraphRevealCardAccessibility(isRevealed: isRevealed))
  }
}

private struct ParagraphRevealText: View {
  let paragraph: ParagraphRevealItem
  let isRevealed: Bool
  let isActive: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedText = ""
  @State private var animationTask: Task<Void, Never>?

  private var hiddenText: String {
    CipherText.hiddenText(for: paragraph.rawText, seed: paragraph.id + 971)
  }

  private var shouldRenderAttributedText: Bool {
    isRevealed && displayedText == paragraph.rawText
  }

  var body: some View {
    Group {
      if shouldRenderAttributedText {
        Text(TextLineWrapper.attributedParagraph(paragraph.rawText))
      } else {
        Text(displayedText.isEmpty ? hiddenText : displayedText)
      }
    }
    .font(.system(size: 21, weight: isRevealed ? .regular : .semibold, design: .monospaced))
    .lineSpacing(6)
    .foregroundStyle(isRevealed ? ParagraphRevealPalette.text : Color.white.opacity(isActive ? 0.34 : 0.22))
    .frame(maxWidth: .infinity, alignment: .leading)
    .privacySensitive()
    .accessibilityHidden(!isRevealed)
    .onAppear {
      displayedText = isRevealed ? paragraph.rawText : hiddenText
    }
    .onDisappear {
      animationTask?.cancel()
    }
    .onChange(of: isRevealed) { _, _ in
      restartAnimation()
    }
    .onChange(of: paragraph.rawText) { _, _ in
      restartAnimation()
    }
  }

  private func restartAnimation() {
    animationTask?.cancel()

    guard isRevealed else {
      withAnimation(.easeOut(duration: reduceMotion ? 0.01 : 0.16)) {
        displayedText = hiddenText
      }
      return
    }

    guard !reduceMotion else {
      displayedText = paragraph.rawText
      return
    }

    displayedText = hiddenText
    animationTask = Task {
      let tickCount = 9

      for tick in 0..<tickCount {
        guard !Task.isCancelled else {
          return
        }

        let progress = Double(tick + 1) / Double(tickCount)
        let nextText = CipherText.resolvingText(
          for: paragraph.rawText,
          seed: paragraph.id + 971,
          progress: progress,
          tick: tick
        )

        await MainActor.run {
          withAnimation(.linear(duration: 0.032)) {
            displayedText = nextText
          }
        }

        try? await Task.sleep(nanoseconds: 32_000_000)
      }

      await MainActor.run {
        withAnimation(.easeOut(duration: 0.08)) {
          displayedText = paragraph.rawText
        }
      }
    }
  }
}

private struct ParagraphRevealCardAccessibility: ViewModifier {
  let isRevealed: Bool

  func body(content: Content) -> some View {
    if isRevealed {
      content
        .accessibilityElement(children: .contain)
    } else {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Locked paragraph")
        .accessibilityHint("Use the slide control to decrypt this paragraph.")
    }
  }
}

private struct ParagraphRevealSlideControl: View {
  enum Mode: Equatable {
    case unlock
    case lock

    var label: String {
      switch self {
      case .unlock:
        return "Slide to decrypt"
      case .lock:
        return "Slide to lock"
      }
    }

    var iconName: String {
      switch self {
      case .unlock:
        return "eye.fill"
      case .lock:
        return "lock.fill"
      }
    }

    var accessibilityAction: String {
      switch self {
      case .unlock:
        return "Decrypt paragraph"
      case .lock:
        return "Lock paragraph"
      }
    }
  }

  let mode: Mode
  let isEnabled: Bool
  let onComplete: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHolding = false
  @State private var isArmed = false
  @State private var dragProgress: CGFloat = 0
  @State private var isCompleted = false
  @State private var holdTask: Task<Void, Never>?
  @State private var completionTask: Task<Void, Never>?

  private let knobSize: CGFloat = 54
  private let holdDurationNanoseconds: UInt64 = 220_000_000
  private let completionThreshold: CGFloat = 0.82

  var body: some View {
    GeometryReader { proxy in
      let trackHeight: CGFloat = 62
      let horizontalInset: CGFloat = 4
      let travelDistance = max(proxy.size.width - knobSize - horizontalInset * 2, 1)
      let knobOffset = horizontalInset + travelDistance * dragProgress

      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.075))
          .overlay(
            Capsule()
              .stroke(trackStrokeColor, lineWidth: 1.2)
          )
          .shadow(color: isArmed ? ParagraphRevealPalette.accent.opacity(0.18) : .clear, radius: 14)

        Capsule()
          .fill(ParagraphRevealPalette.accent.opacity(mode == .unlock ? 0.18 : 0.12))
          .frame(width: max(knobSize, proxy.size.width * dragProgress))
          .opacity(dragProgress > 0 ? 1 : 0)

        Text(mode.label)
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.white.opacity(isArmed ? 0.78 : 0.48))
          .frame(maxWidth: .infinity)
          .padding(.leading, knobSize * 0.4)

        Circle()
          .fill(knobFill)
          .frame(width: knobSize, height: knobSize)
          .overlay(
            Image(systemName: mode.iconName)
              .font(.system(size: 20, weight: .bold))
              .foregroundStyle(Color(red: 0.035, green: 0.045, blue: 0.04))
          )
          .overlay(Circle().stroke(Color.white.opacity(0.34), lineWidth: 1))
          .shadow(color: ParagraphRevealPalette.accent.opacity(isArmed ? 0.36 : 0.14), radius: isArmed ? 14 : 7, y: 2)
          .offset(x: knobOffset)
          .scaleEffect(isHolding ? 1.035 : 1)
          .gesture(slideGesture(travelDistance: travelDistance))
      }
      .frame(height: trackHeight)
      .opacity(isEnabled ? 1 : 0.58)
      .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.18), value: isHolding)
      .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.18), value: isArmed)
      .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: dragProgress)
    }
    .frame(height: 62)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(mode.label)
    .accessibilityHint("Hold the knob, then drag right. Double tap to use the accessible action.")
    .accessibilityAction {
      completeFromAccessibility()
    }
    .accessibilityAction(named: Text(mode.accessibilityAction)) {
      completeFromAccessibility()
    }
    .onChange(of: mode) { _, _ in
      reset(animated: false)
    }
    .onDisappear {
      holdTask?.cancel()
      completionTask?.cancel()
    }
  }

  private var trackStrokeColor: Color {
    if isCompleted {
      return ParagraphRevealPalette.accent.opacity(0.78)
    }

    if isArmed {
      return ParagraphRevealPalette.accent.opacity(0.48)
    }

    return Color.white.opacity(0.13)
  }

  private var knobFill: Color {
    switch mode {
    case .unlock:
      return ParagraphRevealPalette.accent
    case .lock:
      return Color(red: 0.86, green: 0.94, blue: 0.88)
    }
  }

  private func slideGesture(travelDistance: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        guard isEnabled, !isCompleted else {
          return
        }

        beginHoldIfNeeded()

        guard isArmed else {
          return
        }

        dragProgress = min(max(value.translation.width / travelDistance, 0), 1)
      }
      .onEnded { _ in
        finishSlide()
      }
  }

  private func beginHoldIfNeeded() {
    guard !isHolding else {
      return
    }

    isHolding = true
    ParagraphRevealHaptics.hold()
    holdTask?.cancel()
    holdTask = Task {
      try? await Task.sleep(nanoseconds: holdDurationNanoseconds)
      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        guard isHolding else {
          return
        }

        isArmed = true
      }
    }
  }

  private func finishSlide() {
    holdTask?.cancel()

    guard isEnabled, isArmed, dragProgress >= completionThreshold else {
      reset(animated: true)
      return
    }

    isCompleted = true
    ParagraphRevealHaptics.success()

    withAnimation(.easeOut(duration: reduceMotion ? 0.01 : 0.12)) {
      dragProgress = 1
    }

    completionTask?.cancel()
    completionTask = Task {
      try? await Task.sleep(nanoseconds: reduceMotion ? 10_000_000 : 120_000_000)
      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        onComplete()
        reset(animated: false)
      }
    }
  }

  private func completeFromAccessibility() {
    guard isEnabled else {
      return
    }

    holdTask?.cancel()
    completionTask?.cancel()
    isCompleted = true
    dragProgress = 1
    ParagraphRevealHaptics.success()
    onComplete()
    reset(animated: false)
  }

  private func reset(animated: Bool) {
    holdTask?.cancel()
    isHolding = false
    isArmed = false
    isCompleted = false

    let updates = {
      dragProgress = 0
    }

    if animated {
      withAnimation(.spring(response: reduceMotion ? 0.01 : 0.28, dampingFraction: 0.78)) {
        updates()
      }
    } else {
      updates()
    }
  }
}

private struct ParagraphRevealNavigator: View {
  let activeIndex: Int
  let paragraphCount: Int
  let onPrevious: () -> Void
  let onNext: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onPrevious) {
        Image(systemName: "chevron.up")
          .font(.system(size: 17, weight: .bold))
          .frame(width: 48, height: 44)
      }
      .buttonStyle(ParagraphRevealIconButtonStyle())
      .disabled(activeIndex == 0)
      .accessibilityLabel("Previous paragraph")

      Spacer()

      Text("\(activeIndex + 1) / \(max(paragraphCount, 1))")
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.56))
        .accessibilityHidden(true)

      Spacer()

      Button(action: onNext) {
        Image(systemName: "chevron.down")
          .font(.system(size: 17, weight: .bold))
          .frame(width: 48, height: 44)
      }
      .buttonStyle(ParagraphRevealIconButtonStyle())
      .disabled(activeIndex >= paragraphCount - 1)
      .accessibilityLabel("Next paragraph")
    }
  }
}

private struct ParagraphRevealIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? ParagraphRevealPalette.text : Color.white.opacity(0.20))
      .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.075), in: Circle())
      .overlay(Circle().stroke(Color.white.opacity(isEnabled ? 0.12 : 0.05), lineWidth: 1))
  }
}

private struct AdjacentParagraphPreview: View {
  enum Edge {
    case previous
    case next

    var iconName: String {
      switch self {
      case .previous:
        return "chevron.up"
      case .next:
        return "chevron.down"
      }
    }
  }

  let paragraph: ParagraphRevealItem
  let edge: Edge

  private var previewText: String {
    let collapsed = paragraph.rawText
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = String(collapsed.prefix(118))
    return CipherText.hiddenText(for: prefix, seed: paragraph.id + 4301)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 11) {
      Image(systemName: edge.iconName)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(ParagraphRevealPalette.accent.opacity(0.62))
        .frame(width: 26, height: 26)
        .background(Color.white.opacity(0.055), in: Circle())

      Text(previewText)
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .lineLimit(2)
        .foregroundStyle(Color.white.opacity(0.28))
        .blur(radius: 0.9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    .accessibilityHidden(true)
  }
}

private struct HiddenParagraphOverlay: View {
  let seed: Int

  var body: some View {
    TimelineView(.animation) { context in
      Canvas { canvasContext, size in
        let tick = Int(context.date.timeIntervalSinceReferenceDate * 12)
        var generator = SeededGenerator(seed: UInt64(seed + tick + 73) &* 0x9E3779B97F4A7C15)
        let rowHeight: CGFloat = 13
        let rows = Int(size.height / rowHeight)

        for row in 0..<rows {
          let width = CGFloat(Int(generator.next() % 90) + 42)
          let x = CGFloat(Int(generator.next() % UInt64(max(Int(size.width - width), 1))))
          let y = CGFloat(row) * rowHeight + 5
          let rect = CGRect(x: x, y: y, width: min(width, size.width - x), height: 2)
          canvasContext.fill(
            Path(roundedRect: rect, cornerRadius: 1),
            with: .color(ParagraphRevealPalette.accent.opacity(0.08))
          )
        }
      }
    }
    .opacity(0.72)
  }
}

private struct DecryptSweep: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      Rectangle()
        .fill(
          LinearGradient(
            colors: [
              .clear,
              ParagraphRevealPalette.accent.opacity(0.20),
              .clear
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .frame(width: proxy.size.width, height: 80)
        .offset(y: -80 + (proxy.size.height + 160) * progress)
        .opacity(reduceMotion ? 0 : 1)
    }
    .onAppear {
      guard !reduceMotion else {
        return
      }

      progress = 0
      withAnimation(.easeOut(duration: 0.34)) {
        progress = 1
      }
    }
  }
}

private struct ParagraphRevealItem: Identifiable, Equatable {
  let id: Int
  let rawText: String
  var isUnlocked = false
  var hasBeenViewed = false
}

private enum ParagraphRevealParser {
  static func parse(_ message: String) -> [ParagraphRevealItem] {
    let normalizedMessage = message.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalizedMessage.components(separatedBy: "\n")
    var paragraphs: [String] = []
    var currentLines: [String] = []

    func flushCurrentParagraph() {
      let paragraph = currentLines
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if !paragraph.isEmpty {
        paragraphs.append(paragraph)
      }

      currentLines.removeAll()
    }

    for line in lines {
      if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        flushCurrentParagraph()
      } else {
        currentLines.append(line)
      }
    }

    flushCurrentParagraph()

    if paragraphs.isEmpty {
      let fallback = normalizedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      paragraphs = [fallback]
    }

    return paragraphs.enumerated().map { index, rawText in
      ParagraphRevealItem(id: index, rawText: rawText, hasBeenViewed: index == 0)
    }
  }
}

private enum ParagraphRevealPalette {
  static let background = Color(red: 0.045, green: 0.047, blue: 0.043)
  static let text = Color(red: 0.965, green: 0.965, blue: 0.92)
  static let accent = Color(red: 0.48, green: 1.0, blue: 0.70)
}

private enum ParagraphRevealHaptics {
  @MainActor
  static func hold() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred(intensity: 0.24)
  }

  @MainActor
  static func success() {
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(.success)
  }

  @MainActor
  static func navigation() {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.prepare()
    generator.impactOccurred(intensity: 0.22)
  }
}

private struct ParagraphPendingExternalLink: Identifiable {
  let id = UUID()
  let url: URL
}

#Preview("Paragraph reveal reader") {
  ParagraphRevealReaderView(message: paragraphRevealSampleMessage)
}
