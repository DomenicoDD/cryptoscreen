import SwiftUI
import UIKit

final class ScreenCaptureMonitor: ObservableObject {
  @Published private(set) var isCaptured = UIScreen.main.isCaptured
  @Published private(set) var redactsAfterScreenshot = false

  private var screenshotTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  init() {
    let notificationCenter = NotificationCenter.default
    observers = [
      notificationCenter.addObserver(
        forName: UIScreen.capturedDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.isCaptured = UIScreen.main.isCaptured
      },
      notificationCenter.addObserver(
        forName: UIApplication.userDidTakeScreenshotNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.redactBrieflyAfterScreenshot()
      }
    ]
  }

  deinit {
    screenshotTask?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  private func redactBrieflyAfterScreenshot() {
    screenshotTask?.cancel()
    redactsAfterScreenshot = true

    screenshotTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_800_000_000)
      guard !Task.isCancelled else {
        return
      }

      redactsAfterScreenshot = false
    }
  }
}

struct CaptureShield<Content: View>: View {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var monitor = ScreenCaptureMonitor()

  let content: Content
  let onScreenshotDetected: () -> Void

  init(
    onScreenshotDetected: @escaping () -> Void = {},
    @ViewBuilder content: () -> Content
  ) {
    self.onScreenshotDetected = onScreenshotDetected
    self.content = content()
  }

  private var shouldRedact: Bool {
    scenePhase != .active || monitor.isCaptured || monitor.redactsAfterScreenshot
  }

  private var reason: String {
    if scenePhase != .active {
      return "Locked"
    }

    if monitor.isCaptured {
      return "Screen capture blocked"
    }

    return "Screenshot detected"
  }

  var body: some View {
    ZStack {
      content
        .opacity(shouldRedact ? 0 : 1)
        .blur(radius: shouldRedact ? 20 : 0)

      if shouldRedact {
        ZStack {
          Color.black.ignoresSafeArea()

          VStack(spacing: 14) {
            Image(systemName: "eye.slash.fill")
              .font(.system(size: 30, weight: .semibold))
            Text(reason)
              .font(.system(size: 15, weight: .semibold, design: .rounded))
          }
          .foregroundStyle(Color.white.opacity(0.82))
        }
        .transition(.opacity)
      }
    }
    .privacySensitive()
    .animation(.easeOut(duration: 0.12), value: shouldRedact)
    .onChange(of: monitor.redactsAfterScreenshot) { _, isRedacting in
      if isRedacting {
        onScreenshotDetected()
      }
    }
  }
}
