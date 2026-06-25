import Foundation
import StoreKit
import SwiftUI
import UIKit

private let reviewPromptSentMessageCountKey = "cryptoscreen.reviewPrompt.sentMessageCount"
private let reviewPromptDidShowKey = "cryptoscreen.reviewPrompt.didShow"
private let reviewPromptFeedbackCharacterLimit = 2_000

enum ReviewPromptTracker {
  static func recordSuccessfulSend(defaults: UserDefaults = .standard) -> Bool {
    guard !defaults.bool(forKey: reviewPromptDidShowKey) else {
      return false
    }

    let sentMessageCount = defaults.integer(forKey: reviewPromptSentMessageCountKey) + 1
    defaults.set(sentMessageCount, forKey: reviewPromptSentMessageCountKey)

    guard sentMessageCount >= 2 else {
      return false
    }

    defaults.set(true, forKey: reviewPromptDidShowKey)
    return true
  }
}

struct CryptoscreenReviewPrompt: View {
  @Environment(\.requestReview) private var requestReview

  let sendFeedback: (String) async throws -> Void
  let onDone: () -> Void

  @State private var step: ReviewPromptStep = .question
  @State private var feedback = ""
  @State private var statusText: String?
  @State private var didFailSending = false
  @State private var isSendingFeedback = false

  private var trimmedFeedback: String {
    feedback.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  init(
    startsWithFeedback: Bool = false,
    sendFeedback: @escaping (String) async throws -> Void,
    onDone: @escaping () -> Void
  ) {
    self.sendFeedback = sendFeedback
    self.onDone = onDone
    _step = State(initialValue: startsWithFeedback ? .feedback : .question)
  }

  var body: some View {
    ZStack {
      Color(red: 0.045, green: 0.047, blue: 0.043)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Text(step.title)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
            .fixedSize(horizontal: false, vertical: true)

          Text(step.subtitle)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
        }

        switch step {
        case .question:
          questionActions
        case .review:
          reviewActions
        case .feedback:
          feedbackForm
        }
      }
      .padding(24)
    }
    .onChange(of: feedback) { _, newValue in
      if newValue.count > reviewPromptFeedbackCharacterLimit {
        feedback = String(newValue.prefix(reviewPromptFeedbackCharacterLimit))
      }
    }
  }

  private var questionActions: some View {
    HStack(spacing: 10) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          step = .feedback
          statusText = nil
          didFailSending = false
        }
        softHaptic()
      } label: {
        Text("Not yet")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(ReviewPromptSecondaryButtonStyle())

      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          step = .review
        }
        softHaptic()
      } label: {
        Text("Yes")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(ReviewPromptPrimaryButtonStyle())
    }
  }

  private var reviewActions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        requestReview()
        softHaptic()
        onDone()
      } label: {
        Label("Review cryptoscreen", systemImage: "star.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(ReviewPromptPrimaryButtonStyle())

      Button {
        onDone()
        softHaptic()
      } label: {
        Text("Maybe later")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(ReviewPromptSecondaryButtonStyle())
    }
  }

  private var feedbackForm: some View {
    VStack(alignment: .leading, spacing: 14) {
      TextEditor(text: $feedback)
        .font(.system(size: 15, weight: .regular, design: .rounded))
        .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
        .scrollContentBackground(.hidden)
        .frame(minHeight: 132)
        .padding(12)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))

      if let statusText {
        ReviewPromptStatusLine(
          text: statusText,
          systemImage: didFailSending ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
          tint: didFailSending ? Color(red: 1.0, green: 0.68, blue: 0.38) : Color(red: 0.50, green: 0.92, blue: 0.68)
        )
      }

      HStack(spacing: 10) {
        Button {
          onDone()
          softHaptic()
        } label: {
          Text("Skip")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ReviewPromptSecondaryButtonStyle())

        if didFailSending {
          Button {
            onDone()
            softHaptic()
          } label: {
            Label("Continue", systemImage: "arrow.right")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ReviewPromptPrimaryButtonStyle())
        } else {
          Button {
            Task {
              await submitFeedback()
            }
          } label: {
            Label(isSendingFeedback ? "Sending..." : "Send feedback", systemImage: isSendingFeedback ? "hourglass" : "paperplane.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ReviewPromptPrimaryButtonStyle())
          .disabled(trimmedFeedback.isEmpty || isSendingFeedback)
        }
      }
    }
  }

  private func submitFeedback() async {
    guard !trimmedFeedback.isEmpty, !isSendingFeedback else {
      return
    }

    isSendingFeedback = true
    defer {
      isSendingFeedback = false
    }

    do {
      try await sendFeedback(trimmedFeedback)
      statusText = "Thanks. That helps."
      didFailSending = false
      softHaptic()
      try? await Task.sleep(nanoseconds: 900_000_000)
      onDone()
    } catch {
      statusText = "Couldn't send feedback right now."
      didFailSending = true
      warningHaptic()
    }
  }
}

private struct ReviewPromptStatusLine: View {
  let text: String
  let systemImage: String
  let tint: Color

  var body: some View {
    Label {
      Text(text)
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.68))
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
    }
  }
}

private struct ReviewPromptPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.035, green: 0.055, blue: 0.040))
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .background(configuration.isPressed ? Color(red: 0.36, green: 0.86, blue: 0.58) : Color(red: 0.48, green: 1.0, blue: 0.70), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct ReviewPromptSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .background(configuration.isPressed ? Color.white.opacity(0.16) : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
  }
}

private func softHaptic() {
  UIImpactFeedbackGenerator(style: .soft).impactOccurred()
}

private func warningHaptic() {
  UINotificationFeedbackGenerator().notificationOccurred(.warning)
}

private enum ReviewPromptStep {
  case question
  case review
  case feedback

  var title: String {
    switch self {
    case .question:
      return "Are you liking cryptoscreen?"
    case .review:
      return "Review cryptoscreen"
    case .feedback:
      return "How can we improve it?"
    }
  }

  var subtitle: String {
    switch self {
    case .question:
      return "A quick answer helps us understand how the app is doing."
    case .review:
      return "An App Store review would mean a lot for us."
    case .feedback:
      return "Sent anonymously from the app. No account, sealed link, PIN, or message content is attached."
    }
  }
}
