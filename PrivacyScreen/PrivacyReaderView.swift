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

  @StateObject private var proximitySensor = ProximitySensor()
  @State private var fontSize: CGFloat = 21
  @State private var revealedLineIDs: Set<Int> = []
  @State private var activeLineID: Int?
  @State private var pendingLineID: Int?
  @State private var revealDelayTask: Task<Void, Never>?

  init(message: String = sampleMessage) {
    self.message = message
  }

  private var revealActive: Bool {
    proximitySensor.isRevealActive
  }

  var body: some View {
    GeometryReader { proxy in
      let revealTop = max(proxy.safeAreaInsets.top + 8 - 30, 28)
      let revealHeight = proxy.size.height * 0.26
      let revealZone = CGRect(x: 0, y: revealTop, width: proxy.size.width, height: revealHeight)
      let textWidth = proxy.size.width - 40
      let lines = TextLineWrapper.wrap(message, width: textWidth, fontSize: fontSize)

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
          .padding(.top, revealTop + 16)
          .padding(.bottom, proxy.safeAreaInsets.bottom + 116)
        }
        .onPreferenceChange(LineFramePreferenceKey.self) { frames in
          updateRevealWindow(frames: frames, revealZone: revealZone)
        }

        RevealWindowOverlay(topOffset: revealTop, height: revealHeight, isActive: revealActive)

        ReaderChrome(
          proximitySensor: proximitySensor,
          fontSize: $fontSize,
          isRevealActive: revealActive
        )
        .padding(.bottom, proxy.safeAreaInsets.bottom + 16)
        .padding(.horizontal, 16)
      }
      .coordinateSpace(name: "readerScreen")
      .textSelection(.disabled)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("readerScreen"))
          .onChanged { value in
            proximitySensor.setScreenCoverActive(revealZone.contains(value.location))
          }
          .onEnded { _ in
            proximitySensor.setScreenCoverActive(false)
          }
      )
      .onAppear {
        UIApplication.shared.isIdleTimerDisabled = true
        proximitySensor.start()
      }
      .onDisappear {
        UIApplication.shared.isIdleTimerDisabled = false
        proximitySensor.stop()
        revealDelayTask?.cancel()
      }
      .onChange(of: revealActive) { _, isActive in
        if isActive, activeLineID != nil {
          Haptics.lineTranslated()
        }
      }
    }
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

  var body: some View {
    Text(displayedText.isEmpty ? hiddenText : displayedText)
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
  @ObservedObject var proximitySensor: ProximitySensor
  @Binding var fontSize: CGFloat
  let isRevealActive: Bool

  var body: some View {
    VStack {
      Spacer()

      HStack(alignment: .bottom) {
        Button {
          proximitySensor.isManualRevealEnabled.toggle()
          Haptics.buttonTap()
        } label: {
          Image(systemName: proximitySensor.isManualRevealEnabled ? "hand.raised.fill" : "hand.raised")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 42, height: 42)
            .foregroundStyle(isRevealActive ? Color(red: 0.45, green: 1.0, blue: 0.7) : Color(red: 0.965, green: 0.965, blue: 0.92))
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(isRevealActive ? 0.28 : 0.12), lineWidth: 1))
        }
        .accessibilityLabel("Toggle reveal")

        Spacer()

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

private struct RevealWindowOverlay: View {
  let topOffset: CGFloat
  let height: CGFloat
  let isActive: Bool

  var body: some View {
    VStack(spacing: 0) {
      Color.clear
        .frame(height: topOffset)

      Rectangle()
        .fill(Color.white.opacity(isActive ? 0.055 : 0.012))
        .frame(height: height)

      Spacer(minLength: 0)
    }
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.18), value: isActive)
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
