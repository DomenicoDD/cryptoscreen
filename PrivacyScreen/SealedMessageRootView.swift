import PhotosUI
import SwiftUI
import StoreKit
import UIKit

private let defaultComposeMessage = "Meet me by the north entrance after the second bell. Read this once, then let it burn."
private let sealedMessageShareSubject = "cryptoscreen sealed note"
private let sealedMessageShareWarning = "There is an encrypted self-destroying note waiting for you. Beware: if you take a screenshot, the message will be destroyed."
private let maxMessageCharacterCount = 10_000
private let proImageAttachmentsEnabled = true
private let demoCardImageAssetName = "DemoCard"
private let sentMessagesStorageKey = "cryptoscreen.sentMessages"
private let interactionStatusSharingOptInKey = "cryptoscreen.reporting.screenshotEvents"
private let onboardingReaderMessage = """
This is a cryptoscreen message.

Everything starts as static. Cover the dotted target near the top of the display with your hand, then only the protected reading window becomes readable.

Move the page slowly when you need the next line. Each line resolves only when it reaches the reveal window, then falls back into noise outside that area.

The message can be opened once. After it is read, it is deleted from the server. The PIN is never inside the link, so the sender must give it to the reader separately.

Try covering the target, then scroll this guide until the last line reaches the reveal window.
"""

private func sealedMessageShareText(for link: URL) -> String {
  "\(sealedMessageShareWarning)\n\n\(link.absoluteString)"
}

private func demoCardImageData() -> Data? {
  UIImage(named: demoCardImageAssetName)?.pngData()
}

private func demoCardImage() -> UIImage {
  if let image = UIImage(named: demoCardImageAssetName) {
    return image
  }

  let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200))
  return renderer.image { context in
    UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
    UIColor(red: 0.72, green: 0.72, blue: 0.68, alpha: 1).setFill()
    let title = "Cryptoscreen" as NSString
    title.draw(
      at: CGPoint(x: 120, y: 360),
      withAttributes: [
        .font: UIFont.systemFont(ofSize: 72, weight: .semibold),
        .foregroundColor: UIColor(red: 0.72, green: 0.72, blue: 0.68, alpha: 1)
      ]
    )
  }
}

enum SentMessageStatus: String, Codable {
  case active
  case consumed
  case expired
  case destroyed

  var label: String {
    switch self {
    case .active:
      return "Active"
    case .consumed:
      return "Consumed"
    case .expired:
      return "Expired"
    case .destroyed:
      return "Destroyed"
    }
  }

  var tint: Color {
    switch self {
    case .active:
      return Color(red: 0.48, green: 1.0, blue: 0.70)
    case .consumed:
      return Color(red: 0.84, green: 0.92, blue: 1.0)
    case .expired:
      return Color(red: 1.0, green: 0.68, blue: 0.38)
    case .destroyed:
      return Color(red: 1.0, green: 0.42, blue: 0.42)
    }
  }
}

private extension SentMessageStatus {
  init(_ remoteStatus: SealedMessageRemoteStatus) {
    switch remoteStatus {
    case .active:
      self = .active
    case .consumed:
      self = .consumed
    case .expired:
      self = .expired
    case .destroyed:
      self = .destroyed
    }
  }
}

struct SentMessageRecord: Identifiable, Codable, Equatable {
  let id: UUID
  let link: URL
  let pin: String
  let createdAt: Date
  let characterCount: Int
  var hasImageAttachment: Bool
  var interactionStatusShared: Bool
  var textConsumed: Bool
  var imageConsumed: Bool
  var screenshotDetected: Bool
  var status: SentMessageStatus

  var isFullyConsumed: Bool {
    textConsumed && (!hasImageAttachment || imageConsumed)
  }

  init(
    id: UUID,
    link: URL,
    pin: String,
    createdAt: Date,
    characterCount: Int,
    hasImageAttachment: Bool = false,
    interactionStatusShared: Bool = false,
    textConsumed: Bool = false,
    imageConsumed: Bool = false,
    screenshotDetected: Bool = false,
    status: SentMessageStatus
  ) {
    self.id = id
    self.link = link
    self.pin = pin
    self.createdAt = createdAt
    self.characterCount = characterCount
    self.hasImageAttachment = hasImageAttachment
    self.interactionStatusShared = interactionStatusShared
    self.textConsumed = textConsumed
    self.imageConsumed = imageConsumed
    self.screenshotDetected = screenshotDetected
    self.status = status
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case link
    case pin
    case createdAt
    case characterCount
    case hasImageAttachment
    case interactionStatusShared
    case textConsumed
    case imageConsumed
    case screenshotDetected
    case status
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    link = try container.decode(URL.self, forKey: .link)
    pin = try container.decode(String.self, forKey: .pin)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    characterCount = try container.decode(Int.self, forKey: .characterCount)
    hasImageAttachment = try container.decodeIfPresent(Bool.self, forKey: .hasImageAttachment) ?? false
    interactionStatusShared = try container.decodeIfPresent(Bool.self, forKey: .interactionStatusShared) ?? false
    textConsumed = try container.decodeIfPresent(Bool.self, forKey: .textConsumed) ?? false
    imageConsumed = try container.decodeIfPresent(Bool.self, forKey: .imageConsumed) ?? false
    screenshotDetected = try container.decodeIfPresent(Bool.self, forKey: .screenshotDetected) ?? false
    status = try container.decode(SentMessageStatus.self, forKey: .status)
  }
}

@MainActor
final class SealedMessageStore: ObservableObject {
  @Published private(set) var sentMessages: [SentMessageRecord]

  private let api: SealedMessageAPI
  private let defaults: UserDefaults

  var pendingCount: Int {
    sentMessages.filter { $0.status == .active }.count
  }

  init(api: SealedMessageAPI = .production, defaults: UserDefaults = .standard) {
    self.api = api
    self.defaults = defaults
    sentMessages = Self.loadSentMessages(from: defaults)
  }

  func create(
    message: String,
    pin: String,
    imageAttachmentData: Data? = nil,
    imageContentType: String? = nil,
    readPolicy: SealedMessageReadPolicy = .appOnly
  ) async throws -> CreatedSealedMessage {
    let upload = try SealedMessageCrypto.sealForUpload(plaintext: message, pin: pin)
    let imageAttachment: SealedImageAttachmentUpload?
    if let imageAttachmentData {
      guard let imageContentType else {
        throw SealedMessageError.invalidAttachment
      }

      imageAttachment = try SealedMessageCrypto.sealImageAttachment(
        imageData: imageAttachmentData,
        contentType: imageContentType,
        upload: upload
      )
    } else {
      imageAttachment = nil
    }

    let createdMessage = try await api.create(upload: upload, imageAttachment: imageAttachment, readPolicy: readPolicy)
    upsertSentMessage(
      SentMessageRecord(
        id: createdMessage.id,
        link: createdMessage.link,
        pin: createdMessage.pin,
        createdAt: Date(),
        characterCount: message.count,
        hasImageAttachment: createdMessage.hasImageAttachment,
        status: .active
      )
    )

    return createdMessage
  }

  func consume(link: String, pin: String, sharesInteractionStatus: Bool) async -> MessageOpenResult {
    let result = await api.consume(link: link, pin: pin, sharesInteractionStatus: sharesInteractionStatus)

    switch result {
    case .opened(let openedMessage):
      if !openedMessage.retained {
        markLocalMessageConsumed(link: link, result: result, sharesInteractionStatus: sharesInteractionStatus)
      }
    case .destroyed, .expired:
      markLocalMessageConsumed(link: link, result: result, sharesInteractionStatus: sharesInteractionStatus)
    default:
      break
    }

    return result
  }

  func reportScreenshot(eventPath: String) async {
    await api.reportReadSessionEvent(eventPath: eventPath)
  }

  func expireSentMessage(_ message: SentMessageRecord) async throws {
    let remoteStatus = try await api.expire(message: message)
    updateSentMessageDeliveryStatus(id: message.id, remoteStatus: remoteStatus)
  }

  func deleteSentMessage(id: UUID) {
    sentMessages.removeAll { $0.id == id }
    persistSentMessages()
  }

  func refreshSentMessageStatuses(allowsInteractionStatus: Bool) async {
    guard allowsInteractionStatus else {
      return
    }

    for message in sentMessages where message.status == .active || message.status == .consumed {
      do {
        let remoteStatus = try await api.status(messageID: message.id)
        updateSentMessageDeliveryStatus(id: message.id, remoteStatus: remoteStatus)
      } catch {
        continue
      }
    }
  }

  func submitFeedback(rating: Int, message: String) async throws {
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    try await api.submitFeedback(
      rating: rating,
      message: message,
      appVersion: appVersion,
      buildNumber: buildNumber,
      platform: "iOS",
      device: nil,
      timestamp: Date()
    )
  }

  private func markLocalMessageConsumed(link: String, result: MessageOpenResult, sharesInteractionStatus: Bool) {
    guard let messageID = SealedMessageCrypto.request(from: link)?.messageID else {
      return
    }

    switch result {
    case .expired:
      updateSentMessageStatus(id: messageID, status: .expired, interactionStatusShared: sharesInteractionStatus, textConsumed: false, imageConsumed: false)
    case .opened(let openedMessage):
      updateSentMessageStatus(
        id: messageID,
        status: .consumed,
        interactionStatusShared: sharesInteractionStatus,
        textConsumed: true,
        imageConsumed: openedMessage.attachment != nil
      )
    case .destroyed:
      updateSentMessageStatus(id: messageID, status: .destroyed, interactionStatusShared: sharesInteractionStatus, textConsumed: false, imageConsumed: false)
    default:
      updateSentMessageStatus(id: messageID, status: .consumed, interactionStatusShared: sharesInteractionStatus, textConsumed: true, imageConsumed: false)
    }
  }

  private func upsertSentMessage(_ message: SentMessageRecord) {
    sentMessages.removeAll { $0.id == message.id }
    sentMessages.insert(message, at: 0)
    persistSentMessages()
  }

  private func updateSentMessageStatus(id: UUID, status: SentMessageStatus, interactionStatusShared: Bool? = nil, textConsumed: Bool? = nil, imageConsumed: Bool? = nil) {
    guard let index = sentMessages.firstIndex(where: { $0.id == id }) else {
      return
    }

    sentMessages[index].status = status
    if let interactionStatusShared {
      sentMessages[index].interactionStatusShared = interactionStatusShared
    }
    if let textConsumed {
      sentMessages[index].textConsumed = textConsumed
    }
    if let imageConsumed {
      sentMessages[index].imageConsumed = imageConsumed
    }
    persistSentMessages()
  }

  private func updateSentMessageDeliveryStatus(id: UUID, remoteStatus: SealedMessageRemoteDeliveryStatus) {
    guard let index = sentMessages.firstIndex(where: { $0.id == id }) else {
      return
    }

    sentMessages[index].status = SentMessageStatus(remoteStatus.status)
    sentMessages[index].interactionStatusShared = remoteStatus.interactionStatusShared
    sentMessages[index].hasImageAttachment = sentMessages[index].hasImageAttachment || remoteStatus.imageAttachmentAttached
    sentMessages[index].textConsumed = remoteStatus.textConsumed
    sentMessages[index].imageConsumed = remoteStatus.imageAttachmentConsumed
    sentMessages[index].screenshotDetected = remoteStatus.screenshotDetected
    persistSentMessages()
  }

  private func persistSentMessages() {
    guard let data = try? JSONEncoder().encode(sentMessages) else {
      return
    }

    defaults.set(data, forKey: sentMessagesStorageKey)
  }

  private static func loadSentMessages(from defaults: UserDefaults) -> [SentMessageRecord] {
    guard
      let data = defaults.data(forKey: sentMessagesStorageKey),
      let messages = try? JSONDecoder().decode([SentMessageRecord].self, from: data)
    else {
      return []
    }

    return messages.sorted { $0.createdAt > $1.createdAt }
  }
}

struct SealedMessageRootView: View {
  @StateObject private var store = SealedMessageStore()
  @StateObject private var proImageEntitlements = ProImageEntitlementStore()
  @AppStorage("cryptoscreen.hasCompletedOnboarding") private var hasCompletedOnboarding = false
  @State private var mode: MessageMode = .create
  @State private var openedSession: ReaderSession?
  @State private var senderPreviewSession: SenderPreviewSession?
  @State private var incomingLink = ""
  @State private var incomingPIN = ""
  @State private var isShowingOnboarding = false
  @State private var isShowingSentMessages = false
  @State private var isShowingPrivacySettings = false
  @State private var isShowingReviewPrompt = false

  var body: some View {
    mainInterface
  }

  private var mainInterface: some View {
    CaptureShield {
      ZStack {
        Color(red: 0.045, green: 0.047, blue: 0.043)
          .ignoresSafeArea()

        VStack(spacing: 0) {
          HeaderView(
            pendingCount: store.pendingCount,
            onShowSentMessages: {
              isShowingSentMessages = true
            },
            onShowOnboarding: {
              presentOnboarding()
            },
            onShowPrivacySettings: {
              isShowingPrivacySettings = true
            }
          )

#if APPCLIP
          ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
              OpenSealedMessageView(
                store: store,
                initialLink: incomingLink,
                initialPIN: incomingPIN
              ) { openedMessage in
                openedSession = ReaderSession(message: openedMessage)
              }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
          }
#else
          Picker("Mode", selection: $mode) {
            ForEach(MessageMode.allCases) { mode in
              Label(mode.title, systemImage: mode.systemImage)
                .tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 20)
          .padding(.bottom, 16)

          ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
              switch mode {
              case .create:
                ComposeSealedMessageView(
                  store: store,
                  proImageEntitlements: proImageEntitlements,
                  onCreatedLink: { link in
                    incomingLink = link.absoluteString
                    if ReviewPromptTracker.recordSuccessfulSend() {
                      isShowingReviewPrompt = true
                    }
                  },
                  onTestMessage: { message, plaintext, imageData in
                    senderPreviewSession = SenderPreviewSession(
                      message: plaintext,
                      imageData: imageData ?? demoCardImageData(),
                      link: message.link
                    )
                  }
                )
              case .open:
                OpenSealedMessageView(
                store: store,
                initialLink: incomingLink,
                initialPIN: incomingPIN
              ) { openedMessage in
                openedSession = ReaderSession(message: openedMessage)
              }
              }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
          }
#endif
        }
      }
      .textSelection(.disabled)
    }
    .fullScreenCover(item: $openedSession) { session in
      SecureReaderSessionView(openedMessage: session.message, store: store)
    }
    .fullScreenCover(item: $senderPreviewSession) { session in
      SenderPreviewSessionView(message: session.message, imageData: session.imageData, link: session.link)
    }
    .sheet(isPresented: $isShowingSentMessages) {
      SentMessagesView(store: store)
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $isShowingPrivacySettings) {
      PrivacySettingsView(store: store, proImageEntitlements: proImageEntitlements)
        .presentationDetents([.large])
    }
    .sheet(isPresented: $isShowingReviewPrompt) {
      CryptoscreenReviewPrompt(
        sendFeedback: { feedback in
          try await store.submitFeedback(rating: 2, message: feedback)
        },
        onDone: {
          isShowingReviewPrompt = false
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
#if !APPCLIP
    .sheet(isPresented: $isShowingOnboarding) {
      OnboardingView(store: store, proImageEntitlements: proImageEntitlements) {
        hasCompletedOnboarding = true
        isShowingOnboarding = false
      }
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
      .presentationBackground(Color(red: 0.045, green: 0.047, blue: 0.043))
    }
    .onAppear {
      if !hasCompletedOnboarding {
        hasCompletedOnboarding = true
        dismissKeyboard()
        isShowingOnboarding = true
      }
    }
#endif
    .onOpenURL { url in
      incomingLink = url.absoluteString
      incomingPIN = ""
      mode = .open
    }
  }

  private func presentOnboarding() {
    dismissKeyboard()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
      isShowingOnboarding = true
    }
  }
}

private struct HeaderView: View {
  let pendingCount: Int
  let onShowSentMessages: () -> Void
  let onShowOnboarding: () -> Void
  let onShowPrivacySettings: () -> Void

  var body: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 4) {
        Text("cryptoscreen")
          .font(.system(size: 24, weight: .semibold, design: .rounded))
        Text("sealed one-time messages")
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.56))
      }

      Spacer()

      HStack(spacing: 10) {
        Button {
          onShowSentMessages()
          softHaptic()
        } label: {
          Label("\(pendingCount)", systemImage: "lock.doc")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.84, green: 0.92, blue: 1.0))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pendingCount) active sent messages")

        Menu {
#if !APPCLIP
          Button {
            onShowOnboarding()
          } label: {
            Label("Onboarding", systemImage: "play.rectangle")
          }
#endif

          Button {
            onShowPrivacySettings()
          } label: {
            Label("Privacy settings", systemImage: "hand.raised.fill")
          }

          Link(destination: URL(string: "https://github.com/DomenicoDD/cryptoscreen")!) {
            Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
          }

          Link(destination: URL(string: "https://cryptoscreen.app")!) {
            Label("Website", systemImage: "safari")
          }
        } label: {
          Image(systemName: "info.circle")
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 36, height: 36)
            .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
            .background(Color.white.opacity(0.08), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .accessibilityLabel("Information")
      }
    }
    .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 18)
  }
}

private struct PrivacySettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: SealedMessageStore
  @ObservedObject var proImageEntitlements: ProImageEntitlementStore
  @AppStorage(interactionStatusSharingOptInKey) private var sharesInteractionStatus = false
  @State private var isShowingAnonymousFeedback = false
#if !APPCLIP
  @State private var isShowingProPaywall = false
  @State private var isOpeningSubscriptionManagement = false
  @State private var subscriptionManagementError: String?
#endif

  var body: some View {
    ZStack {
      Color(red: 0.045, green: 0.047, blue: 0.043)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Privacy settings")
              .font(.system(size: 24, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

            Text("Read receipts are reciprocal.")
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.56))
          }

          Spacer()

          Button {
            dismiss()
            softHaptic()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .bold))
              .frame(width: 40, height: 40)
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
              .background(Color.white.opacity(0.08), in: Circle())
              .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
          }
          .accessibilityLabel("Close privacy settings")
        }

        VStack(alignment: .leading, spacing: 12) {
          Toggle(isOn: $sharesInteractionStatus) {
            VStack(alignment: .leading, spacing: 5) {
              Text("Share interaction status")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

              Text("Off by default. When enabled, your app can share limited read and screenshot status while you read sealed messages. You can see detailed interaction status on messages you sent only when the reader also shared it.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .tint(Color(red: 0.48, green: 1.0, blue: 0.70))

          Text("One-time links still reveal basic availability: if a link no longer opens, someone with the link can infer it was opened, expired, destroyed, or manually expired. Interaction status is separate and works both ways only when you enable it.")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.48))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))

        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "paperplane.fill")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
              .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
              Text("Anonymous feedback")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

              Text("Write a private note to the developer. No account, sealed link, PIN, or message content is attached.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          Button {
            isShowingAnonymousFeedback = true
            softHaptic()
          } label: {
            Label("Send anonymous feedback", systemImage: "bubble.left.and.text.bubble.right.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(SettingsActionButtonStyle())
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))

#if !APPCLIP
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: proImageEntitlements.isImageAttachmentUnlocked ? "checkmark.seal.fill" : "photo.badge.plus")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
              .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
              Text("Pro Images")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

              Text(proImageEntitlements.isImageAttachmentUnlocked ? "Image attachments are active on this Apple ID." : "Open the paywall to enable encrypted image attachments.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          VStack(spacing: 10) {
            Button {
              isShowingProPaywall = true
              softHaptic()
            } label: {
              Label(proImageEntitlements.isImageAttachmentUnlocked ? "View Pro paywall" : "Open Pro paywall", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SettingsActionButtonStyle())

            Button {
              Task {
                await proImageEntitlements.restorePurchases()
              }
            } label: {
              Label("Restore purchase", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(proImageEntitlements.isLoading || proImageEntitlements.isPurchasing)

            Button {
              openSubscriptionManagement()
            } label: {
              Label(isOpeningSubscriptionManagement ? "Opening..." : "Manage or cancel subscription", systemImage: "creditcard")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(isOpeningSubscriptionManagement)
          }

          if let errorMessage = proImageEntitlements.errorMessage ?? subscriptionManagementError {
            Text(errorMessage)
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(Color(red: 1.0, green: 0.68, blue: 0.38))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
#endif

        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.top, 22)
    }
    .sheet(isPresented: $isShowingAnonymousFeedback) {
      CryptoscreenReviewPrompt(
        startsWithFeedback: true,
        sendFeedback: { feedback in
          try await store.submitFeedback(rating: 2, message: feedback)
        },
        onDone: {
          isShowingAnonymousFeedback = false
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
#if !APPCLIP
    .sheet(isPresented: $isShowingProPaywall) {
      ProImageAttachmentPaywallView(entitlementStore: proImageEntitlements)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    .task {
      await proImageEntitlements.refresh()
    }
#endif
  }

#if !APPCLIP
  private func openSubscriptionManagement() {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }) else {
      subscriptionManagementError = "Could not open subscription settings."
      return
    }

    subscriptionManagementError = nil
    isOpeningSubscriptionManagement = true

    Task {
      defer {
        isOpeningSubscriptionManagement = false
      }

      do {
        try await AppStore.showManageSubscriptions(in: scene)
        await proImageEntitlements.refresh()
      } catch {
        subscriptionManagementError = "Could not open subscription settings."
      }
    }
  }
#endif
}

private struct SettingsActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
      .padding(.vertical, 12)
      .padding(.horizontal, 12)
      .background(
        configuration.isPressed ? Color.white.opacity(0.14) : Color.white.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
  }
}

private struct SentMessagesView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: SealedMessageStore
  @AppStorage(interactionStatusSharingOptInKey) private var sharesInteractionStatus = false
  @State private var showsPins = false
  @State private var copiedMessageID: UUID?
  @State private var expiringMessageID: UUID?
  @State private var actionErrorMessage: String?

  var body: some View {
    ZStack {
      Color(red: 0.045, green: 0.047, blue: 0.043)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Sent messages")
              .font(.system(size: 24, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

            Text("\(store.pendingCount) active")
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.56))
          }

          Spacer()

          Button {
            showsPins.toggle()
            softHaptic()
          } label: {
            Image(systemName: showsPins ? "eye.slash.fill" : "eye.fill")
              .font(.system(size: 16, weight: .semibold))
              .frame(width: 40, height: 40)
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
              .background(Color.white.opacity(0.08), in: Circle())
              .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
          }
          .accessibilityLabel(showsPins ? "Hide PINs" : "Show PINs")

          Button {
            dismiss()
            softHaptic()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .bold))
              .frame(width: 40, height: 40)
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
              .background(Color.white.opacity(0.08), in: Circle())
              .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
          }
          .accessibilityLabel("Close sent messages")
        }

        if store.sentMessages.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("No sent messages yet.")
              .font(.system(size: 17, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

            Text("Sealed messages created on this device will appear here.")
              .font(.system(size: 14, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.58))
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
        } else {
          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
              ForEach(store.sentMessages) { message in
                SentMessageRow(
                  message: message,
                  showsPin: showsPins,
                  showsInteractionStatus: sharesInteractionStatus,
                  didCopy: copiedMessageID == message.id,
                  isExpiring: expiringMessageID == message.id,
                  onCopy: {
                    UIPasteboard.general.string = sealedMessageShareText(for: message.link)
                    copiedMessageID = message.id
                    softHaptic()
                  },
                  onExpire: {
                    expireMessage(message)
                  },
                  onDelete: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                      store.deleteSentMessage(id: message.id)
                    }
                    softHaptic()
                  }
                )
              }
            }
            .padding(.bottom, 20)
          }
        }

        if let actionErrorMessage {
          StatusLine(
            text: actionErrorMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: Color(red: 1.0, green: 0.68, blue: 0.38)
          )
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 22)
    }
    .task(id: sharesInteractionStatus) {
      await store.refreshSentMessageStatuses(allowsInteractionStatus: sharesInteractionStatus)
    }
  }

  private func expireMessage(_ message: SentMessageRecord) {
    guard expiringMessageID == nil else {
      return
    }

    expiringMessageID = message.id
    actionErrorMessage = nil
    Task {
      do {
        try await store.expireSentMessage(message)
        softHaptic()
      } catch {
        actionErrorMessage = "Could not expire this link. Older sent messages may not support remote expiration."
        warningHaptic()
      }
      expiringMessageID = nil
    }
  }
}

private struct SentMessageRow: View {
  let message: SentMessageRecord
  let showsPin: Bool
  let showsInteractionStatus: Bool
  let didCopy: Bool
  let isExpiring: Bool
  let onCopy: () -> Void
  let onExpire: () -> Void
  let onDelete: () -> Void

  private var isLinkAvailable: Bool {
    message.status == .active
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

        Spacer()

        Text(message.status.label)
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .foregroundStyle(message.status.tint)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Color.white.opacity(0.07), in: Capsule())
      }

      HStack(spacing: 14) {
        SentMessageMetric(title: "Characters", value: "\(message.characterCount)")
        SentMessageMetric(title: "PIN", value: showsPin ? message.pin : "••••••")
      }

      if showsInteractionStatus {
        if message.status == .active || message.interactionStatusShared {
          SentMessageDeliveryGrid(message: message)
        } else {
          InteractionStatusLockedView(
            title: "Receiver did not share interaction status",
            accessibilityLabel: "Interaction status hidden because the receiver has not shared it"
          )
        }
      } else {
        InteractionStatusLockedView()
      }

      Text(message.link.absoluteString)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.54))
        .lineLimit(2)
        .truncationMode(.middle)

      if isLinkAvailable {
        HStack(spacing: 10) {
          Button {
            onCopy()
          } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(SecondaryActionButtonStyle())

          Button {
            onExpire()
          } label: {
            Label(isExpiring ? "Expiring..." : "Expire", systemImage: isExpiring ? "hourglass" : "timer")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(SecondaryActionButtonStyle())
          .disabled(isExpiring)
        }
      }

      Button {
        onDelete()
      } label: {
        Label(isLinkAvailable ? "Remove from list" : "Remove", systemImage: "trash")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(SecondaryActionButtonStyle())
    }
    .padding(14)
    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
  }
}

private struct InteractionStatusLockedView: View {
  var title = "Interaction status hidden"
  var accessibilityLabel = "Interaction status hidden because sharing is off"

  var body: some View {
    Label {
      Text(title)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    } icon: {
      Image(systemName: "checkmark.message")
        .font(.system(size: 12, weight: .bold))
    }
    .foregroundStyle(Color.white.opacity(0.42))
    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    .padding(.horizontal, 12)
    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct SentMessageDeliveryGrid: View {
  let message: SentMessageRecord

  var body: some View {
    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
      ],
      alignment: .leading,
      spacing: 8
    ) {
      SentMessageSignal(
        title: "Text read",
        systemImage: "text.alignleft",
        isActive: message.textConsumed
      )

      SentMessageSignal(
        title: message.hasImageAttachment ? "Image read" : "No image",
        systemImage: message.hasImageAttachment ? "photo.fill" : "photo",
        isActive: message.hasImageAttachment && message.imageConsumed,
        isNeutral: !message.hasImageAttachment
      )

      SentMessageSignal(
        title: "Fully read",
        systemImage: "checkmark.seal.fill",
        isActive: message.isFullyConsumed
      )

      SentMessageSignal(
        title: "Screenshot",
        systemImage: message.screenshotDetected ? "camera.viewfinder" : "camera",
        isActive: message.screenshotDetected,
        activeTint: Color(red: 1.0, green: 0.42, blue: 0.42)
      )
    }
  }
}

private struct SentMessageSignal: View {
  let title: String
  let systemImage: String
  let isActive: Bool
  var isNeutral = false
  var activeTint = Color(red: 0.48, green: 1.0, blue: 0.70)

  private var tint: Color {
    if isNeutral {
      return Color.white.opacity(0.34)
    }

    return isActive ? activeTint : Color.white.opacity(0.34)
  }

  var body: some View {
    Label {
      Text(title)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    } icon: {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 16)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(isActive ? 0.085 : 0.045), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(isActive ? 0.34 : 0.16), lineWidth: 1))
  }
}

private struct SentMessageMetric: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .formLabelStyle()

      Text(value)
        .font(.system(size: 15, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ComposeSealedMessageView: View {
  private enum FocusedField: Hashable {
    case message
    case pin
  }

  @ObservedObject var store: SealedMessageStore
  @ObservedObject var proImageEntitlements: ProImageEntitlementStore
  let title: String
  let onCreatedLink: (URL) -> Void
  let onTestMessage: (CreatedSealedMessage, String, Data?) -> Void
  let completionActionTitle: String?
  let usesProgressiveOnboarding: Bool
  let onCompletion: () -> Void

  @AppStorage("cryptoscreen.defaultReadPolicy") private var readPolicyRawValue = SealedMessageReadPolicy.appOnly.rawValue
  @State private var message: String
  @State private var pin = ""
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var selectedImageData: Data?
  @State private var selectedImagePreview: UIImage?
  @State private var isPreparingImage = false
  @State private var createdMessage: CreatedSealedMessage?
  @State private var createdPlaintext: String?
  @State private var createdImageData: Data?
  @State private var errorMessage: String?
  @State private var isCreating = false
  @State private var sealingText: String?
  @State private var sealingProgress = 0.0
  @State private var hasEditedMessage = false
  @State private var showsOnboardingImageStep = false
  @State private var showsOnboardingPinStep = false
  @State private var isShowingImagePaywall = false
  @State private var onboardingRevealTask: Task<Void, Never>?
  @State private var isOnboardingPINRevealPending = false
  @FocusState private var focusedField: FocusedField?

  init(
    store: SealedMessageStore,
    proImageEntitlements: ProImageEntitlementStore,
    title: String = "Create",
    initialMessage: String = defaultComposeMessage,
    initialPIN: String = "",
    completionActionTitle: String? = nil,
    usesProgressiveOnboarding: Bool = false,
    onCreatedLink: @escaping (URL) -> Void,
    onTestMessage: @escaping (CreatedSealedMessage, String, Data?) -> Void,
    onCompletion: @escaping () -> Void = {}
  ) {
    self.store = store
    self.proImageEntitlements = proImageEntitlements
    self.title = title
    self.onCreatedLink = onCreatedLink
    self.onTestMessage = onTestMessage
    self.completionActionTitle = completionActionTitle
    self.usesProgressiveOnboarding = usesProgressiveOnboarding
    self.onCompletion = onCompletion
    _message = State(initialValue: initialMessage)
    _pin = State(initialValue: initialPIN)
  }

  private var canCreate: Bool {
    !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && pin.count == SealedMessageCrypto.pinLength
      && !isPreparingImage
      && !isCreating
      && (selectedImageData == nil || proImageEntitlements.isImageAttachmentUnlocked)
  }

  private var shouldShowImageSection: Bool {
    !usesProgressiveOnboarding || showsOnboardingImageStep
  }

  private var shouldShowPINSection: Bool {
    !usesProgressiveOnboarding || showsOnboardingPinStep
  }

  private var shouldShowCreateButton: Bool {
    !usesProgressiveOnboarding || showsOnboardingPinStep
  }

  private var readPolicy: SealedMessageReadPolicy {
    SealedMessageReadPolicy(rawValue: readPolicyRawValue) ?? .appOnly
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let createdMessage {
        CreatedMessagePanel(
          createdMessage: createdMessage,
          completionActionTitle: completionActionTitle,
          onCompletion: onCompletion,
          onCreateNewMessage: resetCreatedMessage
        ) {
          onTestMessage(createdMessage, createdPlaintext ?? "", createdImageData)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      } else if let sealingText {
        SealingTransitionView(text: sealingText, progress: sealingProgress)
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
      } else {
        VStack(alignment: .leading, spacing: 10) {
          if usesProgressiveOnboarding {
            ComposeStepTitle(number: 1, title: "Write your secret message")
          }

          FieldHeader(title: "Message", isClearEnabled: !message.isEmpty) {
            message = ""
            hasEditedMessage = false
            showsOnboardingImageStep = false
            showsOnboardingPinStep = false
            isOnboardingPINRevealPending = false
            onboardingRevealTask?.cancel()
            createdMessage = nil
            createdPlaintext = nil
            errorMessage = nil
            softHaptic()
          }

          ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $message)
              .font(.system(size: 16, weight: .regular, design: .rounded))
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
              .scrollContentBackground(.hidden)
              .focused($focusedField, equals: .message)
              .frame(minHeight: 146)
              .padding(.horizontal, 12)
              .padding(.top, 12)
              .padding(.bottom, 30)

            Text("\(message.count)/\(maxMessageCharacterCount)")
              .font(.system(size: 11, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.white.opacity(message.count > maxMessageCharacterCount - 500 ? 0.68 : 0.38))
              .monospacedDigit()
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(Color(red: 0.045, green: 0.047, blue: 0.043).opacity(0.82), in: Capsule())
              .padding(10)
          }
          .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
        }

#if !APPCLIP
        if proImageAttachmentsEnabled, shouldShowImageSection {
          VStack(alignment: .leading, spacing: 10) {
            if usesProgressiveOnboarding {
              ComposeStepTitle(
                number: 2,
                title: "Add an image",
                note: proImageEntitlements.isImageAttachmentUnlocked ? "Optional" : "Optional Pro feature"
              )
            }

            ImageAttachmentPicker(
              selectedImage: selectedImagePreview,
              isPreparing: isPreparingImage,
              isUnlocked: proImageEntitlements.isImageAttachmentUnlocked,
              onClear: {
                selectedPhotoItem = nil
                selectedImageData = nil
                selectedImagePreview = nil
                createdMessage = nil
                createdPlaintext = nil
                createdImageData = nil
                errorMessage = nil
                softHaptic()
              },
              onRequestUnlock: {
                focusedField = nil
                isShowingImagePaywall = true
                softHaptic()
              },
              selection: $selectedPhotoItem
            )
          }
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
#endif

        readPolicySection

        if shouldShowPINSection {
          VStack(alignment: .leading, spacing: 10) {
            if usesProgressiveOnboarding {
              ComposeStepTitle(number: 3, title: "Insert a PIN", note: "The receiver uses it to decrypt the message")
            }

            FieldHeader(title: "Six-digit PIN", isClearEnabled: !pin.isEmpty) {
              pin = ""
              createdMessage = nil
              createdPlaintext = nil
              errorMessage = nil
              softHaptic()
            }

            PinEntryField(pin: $pin, placeholder: "PIN", accessibilityLabel: "Create message PIN")
              .focused($focusedField, equals: .pin)
          }
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        if shouldShowCreateButton {
          Button {
            Task {
              await createMessage()
            }
          } label: {
            Label(isCreating ? "Sealing..." : "Seal message", systemImage: isCreating ? "hourglass" : "lock.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(PrimaryActionButtonStyle())
          .disabled(!canCreate)
          .background(ScrollIntoViewOnTrigger(trigger: focusedField == .pin))
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        if let errorMessage {
          StatusLine(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: Color(red: 1.0, green: 0.68, blue: 0.38))
        }
      }
    }
    .onChange(of: message) { _, newValue in
      if newValue.count > maxMessageCharacterCount {
        message = String(newValue.prefix(maxMessageCharacterCount))
      }

      if usesProgressiveOnboarding, !hasEditedMessage, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        hasEditedMessage = true
        revealOnboardingImageStep()
        scheduleOnboardingPINReveal()
      }
    }
    .onChange(of: focusedField) { oldValue, newValue in
      guard usesProgressiveOnboarding,
            oldValue == .message,
            newValue != .message,
            isOnboardingPINRevealPending else {
        return
      }

      scheduleOnboardingPINReveal()
    }
#if !APPCLIP
    .onChange(of: selectedPhotoItem) { _, newValue in
      Task {
        await prepareSelectedImage(newValue)
      }
    }
#endif
    .sheet(isPresented: $isShowingImagePaywall) {
      ProImageAttachmentPaywallView(entitlementStore: proImageEntitlements)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    .onDisappear {
      onboardingRevealTask?.cancel()
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()

        Button {
          focusedField = nil
        } label: {
          Text("Done")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
      }
    }
  }

  private var readPolicySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      FieldHeader(title: "Read availability", isClearEnabled: false) {}

      Picker("Read availability", selection: $readPolicyRawValue) {
        ForEach(SealedMessageReadPolicy.allCases, id: \.rawValue) { policy in
          Text(policy.title).tag(policy.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .tint(Color(red: 0.48, green: 0.96, blue: 0.54))
      .onChange(of: readPolicyRawValue) { _, _ in
        createdMessage = nil
        createdPlaintext = nil
        errorMessage = nil
      }

      Text(readPolicy.detail)
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.48))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

#if !APPCLIP
  private func prepareSelectedImage(_ item: PhotosPickerItem?) async {
    guard let item else {
      return
    }

    guard proImageEntitlements.isImageAttachmentUnlocked else {
      selectedPhotoItem = nil
      selectedImageData = nil
      selectedImagePreview = nil
      isShowingImagePaywall = true
      return
    }

    isPreparingImage = true
    errorMessage = nil
    defer {
      isPreparingImage = false
    }

    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        throw SealedMessageError.invalidAttachment
      }

      let normalized = try normalizeImageAttachment(data)
      selectedImageData = normalized.data
      selectedImagePreview = normalized.preview
      createdMessage = nil
      createdPlaintext = nil
      createdImageData = nil
    } catch {
      selectedPhotoItem = nil
      selectedImageData = nil
      selectedImagePreview = nil
      errorMessage = "Choose a JPEG, PNG, HEIC, or HEIF image under 10 MB."
      warningHaptic()
    }
  }
#endif

  private func createMessage() async {
    guard !isCreating else {
      return
    }

    let plaintext = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let pinToSeal = pin
    let imageDataToSeal = selectedImageData
    let animationDuration: TimeInterval = 0.64

    if imageDataToSeal != nil && !proImageEntitlements.isImageAttachmentUnlocked {
      isShowingImagePaywall = true
      warningHaptic()
      return
    }

    isCreating = true
    createdMessage = nil
    createdPlaintext = nil
    createdImageData = nil
    errorMessage = nil
    sealingText = plaintext
    sealingProgress = 0

    withAnimation(.linear(duration: animationDuration)) {
      sealingProgress = 1
    }

    defer {
      isCreating = false
    }

    do {
      let startedAt = Date()
      let sealed = try await store.create(
        message: plaintext,
        pin: pinToSeal,
        imageAttachmentData: imageDataToSeal,
        imageContentType: imageDataToSeal == nil ? nil : "image/jpeg",
        readPolicy: readPolicy
      )
      let remainingAnimation = animationDuration - Date().timeIntervalSince(startedAt)
      if remainingAnimation > 0 {
        try? await Task.sleep(nanoseconds: UInt64(remainingAnimation * 1_000_000_000))
      }

      withAnimation(.easeInOut(duration: 0.2)) {
        createdMessage = sealed
        createdPlaintext = plaintext
        createdImageData = imageDataToSeal
        errorMessage = nil
        message = ""
        pin = ""
        selectedPhotoItem = nil
        selectedImageData = nil
        selectedImagePreview = nil
        sealingText = plaintext
        sealingProgress = 1
      }

      onCreatedLink(sealed.link)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch SealedMessageError.invalidPIN {
      withAnimation(.easeInOut(duration: 0.18)) {
        sealingText = nil
        sealingProgress = 0
        errorMessage = "Use a message and a six-digit PIN."
      }
    } catch SealedMessageError.invalidAttachment {
      withAnimation(.easeInOut(duration: 0.18)) {
        sealingText = nil
        sealingProgress = 0
        errorMessage = "Choose a JPEG, PNG, HEIC, or HEIF image under 10 MB."
      }
    } catch {
      withAnimation(.easeInOut(duration: 0.18)) {
        sealingText = nil
        sealingProgress = 0
        errorMessage = "Could not reach cryptoscreen.app."
      }
    }
  }

  private func resetCreatedMessage() {
    withAnimation(.easeInOut(duration: 0.2)) {
      message = ""
      pin = ""
      selectedPhotoItem = nil
      selectedImageData = nil
      selectedImagePreview = nil
      createdMessage = nil
      createdPlaintext = nil
      createdImageData = nil
      errorMessage = nil
      sealingText = nil
      sealingProgress = 0
      hasEditedMessage = false
      showsOnboardingImageStep = false
      showsOnboardingPinStep = false
      isOnboardingPINRevealPending = false
      onboardingRevealTask?.cancel()
    }
  }

  private func revealOnboardingImageStep() {
    withAnimation(.easeOut(duration: 0.22)) {
      showsOnboardingImageStep = true
    }
  }

  private func scheduleOnboardingPINReveal() {
    onboardingRevealTask?.cancel()
    isOnboardingPINRevealPending = true
    onboardingRevealTask = Task {
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        guard focusedField != .message else {
          return
        }

        withAnimation(.easeOut(duration: 0.22)) {
          showsOnboardingPinStep = true
        }
        isOnboardingPINRevealPending = false
      }
    }
  }
}

private struct ScrollIntoViewOnTrigger: UIViewRepresentable {
  let trigger: Bool

  func makeUIView(context: Context) -> UIView {
    UIView(frame: .zero)
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    guard trigger else {
      context.coordinator.cancelPendingScroll()
      return
    }

    context.coordinator.scrollIntoView(uiView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    private var lastTriggerDate = Date.distantPast
    private var scrollGeneration = 0

    func scrollIntoView(_ view: UIView) {
      let now = Date()
      guard now.timeIntervalSince(lastTriggerDate) > 0.25 else {
        return
      }

      lastTriggerDate = now
      scrollGeneration += 1
      let generation = scrollGeneration

      for delay in [0.12, 0.34] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
          guard let view,
                view.window != nil,
                generation == self.scrollGeneration else {
            return
          }

          view.scrollNearestAncestorToVisible(extraBottomMargin: 18)
        }
      }
    }

    func cancelPendingScroll() {
      scrollGeneration += 1
    }
  }
}

private func dismissKeyboard() {
  UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private extension UIView {
  func scrollNearestAncestorToVisible(extraBottomMargin: CGFloat) {
    guard let scrollView = firstSuperview(of: UIScrollView.self) else {
      return
    }

    let targetRect = convert(bounds, to: scrollView).insetBy(dx: 0, dy: -extraBottomMargin)
    scrollView.scrollRectToVisible(targetRect, animated: true)
  }

  func firstSuperview<T: UIView>(of type: T.Type) -> T? {
    var candidate = superview

    while let current = candidate {
      if let typed = current as? T {
        return typed
      }

      candidate = current.superview
    }

    return nil
  }
}

private struct ImageAttachmentPicker: View {
  let selectedImage: UIImage?
  let isPreparing: Bool
  let isUnlocked: Bool
  let onClear: () -> Void
  let onRequestUnlock: () -> Void
  @Binding var selection: PhotosPickerItem?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Image")
          .formLabelStyle()

        Spacer()

        if selectedImage != nil {
          Button {
            onClear()
          } label: {
            Text("Remove")
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .textCase(.uppercase)
              .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove image")
        }
      }

      if let selectedImage {
        HStack(spacing: 12) {
          Image(uiImage: selectedImage)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 6) {
            Text("Image attached")
              .font(.system(size: 15, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

            Text("Ready to seal once.")
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.58))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(12)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
      } else if isUnlocked {
        PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
          Label(isPreparing ? "Preparing image..." : "Attach encrypted image", systemImage: isPreparing ? "hourglass" : "photo.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryActionButtonStyle())
        .disabled(isPreparing)
      } else {
        Button {
          onRequestUnlock()
        } label: {
          Label("Upgrade to Pro Images", systemImage: "lock.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryActionButtonStyle())
      }
    }
  }
}

private struct ComposeStepTitle: View {
  let number: Int
  let title: String
  var note: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("\(number). \(title)")
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

      if let note {
        Text(note)
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.52))
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct SealingTransitionView: View, Animatable {
  let text: String
  var progress: Double

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  private var displayText: String {
    let characters = Array(text)
    let encryptedCharacters = Array(CipherText.hiddenText(for: text, seed: 831))
    let encryptedCount = min(characters.count, Int((Double(characters.count) * progress).rounded(.up)))

    return String(characters.indices.map { index in
      index < encryptedCount ? encryptedCharacters[index] : characters[index]
    })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(displayText)
        .font(.system(size: 17, weight: .regular, design: .monospaced))
        .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, minHeight: 212, alignment: .topLeading)
  }
}

private struct CreatedMessagePanel: View {
  let createdMessage: CreatedSealedMessage
  let completionActionTitle: String?
  let onCompletion: () -> Void
  let onCreateNewMessage: () -> Void
  let onUseLink: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      StatusLine(
        text: createdMessage.hasImageAttachment
          ? "Sealed on cryptoscreen.app with encrypted image ciphertext."
          : "Sealed on cryptoscreen.app. The server stores ciphertext only.",
        systemImage: "checkmark.seal.fill",
        tint: Color(red: 0.50, green: 0.92, blue: 0.68)
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("Share link")
          .formLabelStyle()

        Text(createdMessage.link.absoluteString)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.64))
          .lineLimit(3)
          .truncationMode(.middle)
      }

      HStack(spacing: 10) {
        ShareLink(
          item: sealedMessageShareText(for: createdMessage.link),
          subject: Text(sealedMessageShareSubject)
        ) {
          Label("Share", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryActionButtonStyle())

        Button {
          onUseLink()
          softHaptic()
        } label: {
          Label("Test", systemImage: "play.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryActionButtonStyle())
      }

      if let completionActionTitle {
        Button {
          onCompletion()
          softHaptic()
        } label: {
          Label(completionActionTitle, systemImage: "checkmark.circle.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionButtonStyle())
      }

      if completionActionTitle == nil {
        Button {
          onCreateNewMessage()
          softHaptic()
        } label: {
          Label("Create new message", systemImage: "plus.message.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionButtonStyle())
      } else {
        Button {
          onCreateNewMessage()
          softHaptic()
        } label: {
          Label("Create new message", systemImage: "plus.message.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryActionButtonStyle())
      }
    }
    .padding(14)
    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
  }
}

private struct OpenSealedMessageView: View {
  @ObservedObject var store: SealedMessageStore
  let initialLink: String
  let initialPIN: String
  let onOpen: (OpenedSealedMessage) -> Void

  @AppStorage(interactionStatusSharingOptInKey) private var sharesInteractionStatus = false
  @State private var link = ""
  @State private var pin = ""
  @State private var status = "Paste or receive a cryptoscreen link, enter the PIN, then open it once."
  @State private var statusIcon = "link.badge.plus"
  @State private var statusTint = Color.white.opacity(0.58)
  @State private var isOpening = false

  private var canOpen: Bool {
    SealedMessageCrypto.request(from: link) != nil && pin.count == SealedMessageCrypto.pinLength && !isOpening
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Message link")
          .formLabelStyle()

        HStack(spacing: 8) {
          ZStack(alignment: .leading) {
            if link.isEmpty {
              Text(verbatim: "https://cryptoscreen.app/m/...")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.56, green: 0.56, blue: 0.56))
                .allowsHitTesting(false)
            }

            TextField("", text: $link)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .font(.system(size: 14, weight: .medium, design: .monospaced))
              .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
              .tint(Color.white.opacity(0.58))
              .accessibilityLabel("Message link")
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Button {
            link = ""
            softHaptic()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(Color.white.opacity(link.isEmpty ? 0.20 : 0.58))
              .frame(width: 30, height: 30)
          }
          .buttonStyle(.plain)
          .disabled(link.isEmpty)
          .accessibilityLabel("Clear message link")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("PIN")
          .formLabelStyle()

        PinEntryField(pin: $pin, placeholder: "PIN", accessibilityLabel: "Open message PIN")
      }

      Button {
        Task {
          await openMessage()
        }
      } label: {
        Label(isOpening ? "Opening..." : "Open once", systemImage: isOpening ? "hourglass" : "eye.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(PrimaryActionButtonStyle())
      .disabled(!canOpen)

      StatusLine(text: status, systemImage: statusIcon, tint: statusTint)
    }
    .onAppear {
      if !initialLink.isEmpty {
        link = initialLink
      }
      if !initialPIN.isEmpty {
        pin = initialPIN
      }
    }
    .onChange(of: initialLink) { _, newValue in
      guard !newValue.isEmpty else {
        return
      }

      link = newValue
    }
    .onChange(of: initialPIN) { _, newValue in
      guard !newValue.isEmpty else {
        return
      }

      pin = newValue
    }
  }

  private func openMessage() async {
    guard !isOpening else {
      return
    }

    isOpening = true
    let result = await store.consume(link: link, pin: pin, sharesInteractionStatus: sharesInteractionStatus)
    isOpening = false

    switch result {
    case .opened(let openedMessage):
      pin = ""
      status = openedMessage.retained
        ? "Review demo opened. This retained row stays available for retesting."
        : openedMessage.attachment == nil
          ? "Consumed. The encrypted row was deleted before rendering."
          : "Consumed. The encrypted row and image object are no longer reusable."
      statusIcon = openedMessage.retained ? "arrow.triangle.2.circlepath" : "flame.fill"
      statusTint = Color(red: 0.50, green: 0.92, blue: 0.68)
      onOpen(openedMessage)
      softHaptic()
    case .wrongPin(let remainingAttempts):
      pin = ""
      status = "\(remainingAttempts) PIN attempt\(remainingAttempts == 1 ? "" : "s") remaining."
      statusIcon = "key.slash.fill"
      statusTint = Color(red: 1.0, green: 0.68, blue: 0.38)
      warningHaptic()
    case .destroyed:
      pin = ""
      status = "Destroyed after the third wrong PIN."
      statusIcon = "trash.fill"
      statusTint = Color(red: 1.0, green: 0.42, blue: 0.42)
      warningHaptic()
    case .expired:
      status = "This message expired and was deleted."
      statusIcon = "clock.badge.xmark.fill"
      statusTint = Color(red: 1.0, green: 0.42, blue: 0.42)
    case .unavailable:
      status = "No sealed message exists for this link."
      statusIcon = "questionmark.folder.fill"
      statusTint = Color(red: 1.0, green: 0.68, blue: 0.38)
    case .invalidLink:
      status = "The link is missing a message id or secret."
      statusIcon = "link.badge.plus"
      statusTint = Color(red: 1.0, green: 0.68, blue: 0.38)
    case .invalidPin:
      status = "Enter exactly six digits."
      statusIcon = "number"
      statusTint = Color(red: 1.0, green: 0.68, blue: 0.38)
    case .corrupted:
      status = "Payload could not be decrypted and was deleted."
      statusIcon = "exclamationmark.lock.fill"
      statusTint = Color(red: 1.0, green: 0.42, blue: 0.42)
    case .networkFailed:
      status = "Could not reach cryptoscreen.app."
      statusIcon = "wifi.exclamationmark"
      statusTint = Color(red: 1.0, green: 0.68, blue: 0.38)
    }
  }
}

private struct PinEntryField: View {
  @Binding var pin: String
  let placeholder: String
  let accessibilityLabel: String

  var body: some View {
    TextField(placeholder, text: $pin)
      .keyboardType(.numberPad)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .font(.system(size: 22, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
      .lineLimit(1)
      .privacySensitive()
      .accessibilityLabel(accessibilityLabel)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
    .onAppear {
      pin = SealedMessageCrypto.normalizePIN(pin)
    }
    .onChange(of: pin) { _, newValue in
      let normalized = SealedMessageCrypto.normalizePIN(newValue)
      if normalized != newValue {
        pin = normalized
      }
    }
  }
}

private struct SecureReaderSessionView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: SealedMessageStore
  @AppStorage(interactionStatusSharingOptInKey) private var sharesInteractionStatus = false
  @State private var openedMessage: OpenedSealedMessage
  @State private var showsImage: Bool

  init(openedMessage: OpenedSealedMessage, store: SealedMessageStore) {
    self.store = store
    _openedMessage = State(initialValue: openedMessage)
    _showsImage = State(initialValue: openedMessage.attachment != nil)
  }

  var body: some View {
    CaptureShield(onScreenshotDetected: {
      handleScreenshotDetected()
    }) {
      ZStack(alignment: .bottom) {
        if showsImage, let attachment = openedMessage.attachment, let image = UIImage(data: attachment.data) {
          AttachmentImageReaderView(
            image: image,
            showsImage: $showsImage,
            onClose: close
          )
        } else {
          PrivacyReaderView(
            message: openedMessage.plaintext,
            bottomChromeBottomPadding: openedMessage.attachment == nil ? 16 : 88,
            onClose: close
          )

          if openedMessage.attachment != nil {
            ReaderModeSwitch(showsImage: $showsImage)
              .frame(maxWidth: .infinity)
              .padding(4)
              .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
              .padding(.horizontal, 20)
              .padding(.bottom, 18)
          }
        }
      }
      .onDisappear {
        clear()
      }
    }
  }

  private func handleScreenshotDetected() {
    let eventPath = openedMessage.eventPath ?? openedMessage.attachment?.eventPath
    clear()
    dismiss()
    warningHaptic()

    if sharesInteractionStatus, let eventPath {
      Task {
        await store.reportScreenshot(eventPath: eventPath)
      }
    }
  }

  private func close() {
    clear()
    dismiss()
  }

  private func clear() {
    openedMessage = OpenedSealedMessage(plaintext: "", attachment: nil, retained: false, eventPath: nil)
  }
}

private struct SenderPreviewSessionView: View {
  @Environment(\.dismiss) private var dismiss

  let message: String
  let imageData: Data?
  let link: URL
  @State private var showsImage: Bool

  init(message: String, imageData: Data?, link: URL) {
    self.message = message
    self.imageData = imageData
    self.link = link
    _showsImage = State(initialValue: imageData != nil)
  }

  var body: some View {
    CaptureShield {
      ZStack(alignment: .bottom) {
        if showsImage, let imageData, let image = UIImage(data: imageData) {
          AttachmentImageReaderView(
            image: image,
            showsImage: $showsImage,
            onClose: {
              dismiss()
              softHaptic()
            }
          )
        } else {
          PrivacyReaderView(
            message: message,
            bottomChromeBottomPadding: imageData == nil ? 88 : 146,
            onClose: {
              dismiss()
              softHaptic()
            }
          )
        }

        if !showsImage {
          VStack {
            Spacer()

            if imageData != nil {
              ReaderModeSwitch(showsImage: $showsImage)
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 20)
            }

            ShareLink(
              item: sealedMessageShareText(for: link),
              subject: Text(sealedMessageShareSubject)
            ) {
              Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .padding(.top, imageData != nil ? 10 : 0)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
          }
        }
      }
    }
  }
}

private struct ReaderModeSwitch: View {
  @Binding var showsImage: Bool

  var body: some View {
    Picker("Reader mode", selection: $showsImage) {
      Label("Text", systemImage: "text.alignleft")
        .tag(false)
      Label("Image", systemImage: "photo.fill")
        .tag(true)
    }
    .pickerStyle(.segmented)
    .tint(Color(red: 0.48, green: 1.0, blue: 0.70))
    .onChange(of: showsImage) { _, _ in
      softHaptic()
    }
  }
}

private struct AttachmentImageReaderView: View {
  let image: UIImage
  private let pixelatedImage: UIImage
  @Binding var showsImage: Bool
  let onClose: (() -> Void)?
  let showsModeSwitch: Bool
  let onRevealPerformed: () -> Void
  let onImageInteractionPerformed: () -> Void

  @StateObject private var proximitySensor = ProximitySensor()
  @State private var showsTouchHint = false
  @State private var hintDelayTask: Task<Void, Never>?
  @State private var scale: CGFloat = 1
  @State private var lastScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var lastOffset: CGSize = .zero
  @State private var didReportReveal = false
  @State private var didReportImageInteraction = false

  private var revealActive: Bool {
    proximitySensor.isRevealActive
  }

  init(
    image: UIImage,
    showsImage: Binding<Bool>,
    onClose: (() -> Void)?,
    showsModeSwitch: Bool = true,
    onRevealPerformed: @escaping () -> Void = {},
    onImageInteractionPerformed: @escaping () -> Void = {}
  ) {
    self.image = image
    self.pixelatedImage = image.pixelatedForPrivacy()
    _showsImage = showsImage
    self.onClose = onClose
    self.showsModeSwitch = showsModeSwitch
    self.onRevealPerformed = onRevealPerformed
    self.onImageInteractionPerformed = onImageInteractionPerformed
  }

  var body: some View {
    GeometryReader { proxy in
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
      let imageViewport = CGSize(
        width: max(proxy.size.width - 28, 1),
        height: max(proxy.size.height - proxy.safeAreaInsets.bottom - 176, 1)
      )
      let fittedImageSize = image.size.scaledToFit(in: imageViewport)

      ZStack(alignment: .bottom) {
        Color(red: 0.045, green: 0.047, blue: 0.043)
          .ignoresSafeArea()

        ZStack {
          TransformableAttachmentImage(
            image: pixelatedImage,
            displaySize: fittedImageSize,
            scale: scale,
            offset: offset,
            isPixelated: true
          )
          .accessibilityLabel("Pixelated attached image")

          if revealActive {
            TransformableAttachmentImage(
              image: image,
              displaySize: fittedImageSize,
              scale: scale,
              offset: offset,
              isPixelated: false
            )
            .mask(
              RevealWindowMask(revealZone: revealZone)
            )
            .accessibilityHidden(true)
            .transition(.opacity)
          }

          if revealActive {
            ActiveRevealWindowOverlay(revealZone: revealZone)
              .allowsHitTesting(false)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              markImageInteractionIfNeeded(value.translation)
              let proposedOffset = CGSize(
                width: lastOffset.width + value.translation.width,
                height: lastOffset.height + value.translation.height
              )
              offset = clampedOffset(proposedOffset, displaySize: fittedImageSize, viewportSize: proxy.size, revealZone: revealZone, scale: scale)
            }
            .onEnded { _ in
              offset = clampedOffset(offset, displaySize: fittedImageSize, viewportSize: proxy.size, revealZone: revealZone, scale: scale)
              lastOffset = offset
            }
        )
        .simultaneousGesture(
          MagnificationGesture()
            .onChanged { value in
              markImageInteractionIfNeeded(value)
              scale = min(max(lastScale * value, 1), 5)
              offset = clampedOffset(offset, displaySize: fittedImageSize, viewportSize: proxy.size, revealZone: revealZone, scale: scale)
            }
            .onEnded { _ in
              scale = min(max(scale, 1), 5)
              offset = clampedOffset(offset, displaySize: fittedImageSize, viewportSize: proxy.size, revealZone: revealZone, scale: scale)
              lastScale = scale
              lastOffset = offset
            }
        )
        .onTapGesture(count: 2) {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
          }
          softHaptic()
        }
        .privacySensitive()

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

        if onClose != nil || showsModeSwitch {
          HStack(spacing: 10) {
            if let onClose {
              Button {
                onClose()
              } label: {
                Image(systemName: "xmark")
                  .font(.system(size: 15, weight: .bold))
                  .frame(width: 44, height: 44)
              }
              .buttonStyle(SecondaryActionButtonStyle())
              .accessibilityLabel("Close message")
            }

            if showsModeSwitch {
              ReaderModeSwitch(showsImage: $showsImage)
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 18)
        }
      }
      .textSelection(.disabled)
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
        hintDelayTask?.cancel()
      }
      .onChange(of: revealActive) { _, isActive in
        if isActive {
          softHaptic()
          markRevealed()
        }
      }
    }
  }

  private func markRevealed() {
    guard !didReportReveal else {
      return
    }

    didReportReveal = true
    onRevealPerformed()
  }

  private func markImageInteractionIfNeeded(_ translation: CGSize) {
    guard abs(translation.width) > 24 || abs(translation.height) > 24 else {
      return
    }

    markImageInteraction()
  }

  private func markImageInteractionIfNeeded(_ magnification: CGFloat) {
    guard abs(magnification - 1) > 0.08 else {
      return
    }

    markImageInteraction()
  }

  private func markImageInteraction() {
    guard !didReportImageInteraction else {
      return
    }

    didReportImageInteraction = true
    onImageInteractionPerformed()
  }

  private func clampedOffset(_ proposedOffset: CGSize, displaySize: CGSize, viewportSize: CGSize, revealZone: CGRect, scale: CGFloat) -> CGSize {
    let scaledSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
    let viewportCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    let horizontalPadding: CGFloat = 44
    let verticalPadding = max(72, revealZone.height * 0.34)
    let minX = revealZone.midX - viewportCenter.x - scaledSize.width / 2 - horizontalPadding
    let maxX = revealZone.midX - viewportCenter.x + scaledSize.width / 2 + horizontalPadding
    let minY = revealZone.midY - viewportCenter.y - scaledSize.height / 2 - verticalPadding
    let maxY = revealZone.midY - viewportCenter.y + scaledSize.height / 2 + verticalPadding

    return CGSize(
      width: min(max(proposedOffset.width, minX), maxX),
      height: min(max(proposedOffset.height, minY), maxY)
    )
  }
}

private struct TransformableAttachmentImage: View {
  let image: UIImage
  let displaySize: CGSize
  let scale: CGFloat
  let offset: CGSize
  let isPixelated: Bool

  var body: some View {
    Image(uiImage: image)
      .resizable()
      .interpolation(isPixelated ? .none : .high)
      .scaledToFill()
      .frame(width: displaySize.width, height: displaySize.height)
      .scaleEffect(scale)
      .offset(offset)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
  }
}

private struct RevealWindowMask: View {
  let revealZone: CGRect

  var body: some View {
    GeometryReader { _ in
      Color.black
        .frame(width: revealZone.width, height: revealZone.height)
        .position(x: revealZone.midX, y: revealZone.midY)
    }
  }
}

private struct ActiveRevealWindowOverlay: View {
  let revealZone: CGRect

  @State private var scanProgress: CGFloat = 0

  var body: some View {
    GeometryReader { _ in
      ZStack {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.34), lineWidth: 1)
          .frame(width: revealZone.width - 28, height: revealZone.height)
          .position(x: revealZone.midX, y: revealZone.midY)

        Capsule()
          .fill(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.76))
          .frame(width: revealZone.width - 54, height: 2)
          .shadow(color: Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.54), radius: 10)
          .position(
            x: revealZone.midX,
            y: revealZone.minY + 18 + (revealZone.height - 36) * scanProgress
          )
      }
    }
    .onAppear {
      scanProgress = 0
      withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
        scanProgress = 1
      }
    }
  }
}

private struct ImageMoveTeachingPill: View {
  @State private var moves = false

  var body: some View {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
      .frame(width: 54, height: 54)
      .background(Color.white.opacity(0.08), in: Circle())
      .overlay(Circle().stroke(Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.42), lineWidth: 1))
      .offset(x: moves ? 10 : -10, y: moves ? 8 : -8)
      .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: moves)
      .onAppear {
        moves = true
      }
      .accessibilityHidden(true)
  }
}

private enum OnboardingStep {
  case reader
  case imageReader
  case create
}

private struct OnboardingView: View {
  @ObservedObject var store: SealedMessageStore
  @ObservedObject var proImageEntitlements: ProImageEntitlementStore
  let onComplete: () -> Void

  @State private var step: OnboardingStep = .reader
  @State private var didRevealMessage = false
  @State private var didScrollMessage = false
  @State private var didRevealImage = false
  @State private var didMoveImage = false
  @State private var showsOnboardingImage = true
  @State private var senderPreviewSession: SenderPreviewSession?

  private var canAdvanceFromReader: Bool {
    didRevealMessage && didScrollMessage
  }

  private var canAdvanceFromImageReader: Bool {
    didRevealImage && didMoveImage
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color(red: 0.045, green: 0.047, blue: 0.043)
        .ignoresSafeArea()

      switch step {
      case .reader:
        PrivacyReaderView(
          message: onboardingReaderMessage,
          showsFontControls: false,
          showsHandPlacementGuide: true,
          onRevealPerformed: {
            didRevealMessage = true
          },
          onScrollPerformed: {
            didScrollMessage = true
          }
        )

        if canAdvanceFromReader {
          Button {
            withAnimation(.easeInOut(duration: 0.22)) {
              step = .imageReader
            }
            softHaptic()
          } label: {
            Label("Next", systemImage: "arrow.right")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(PrimaryActionButtonStyle())
          .padding(.horizontal, 20)
          .padding(.bottom, 28)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      case .imageReader:
        AttachmentImageReaderView(
          image: demoCardImage(),
          showsImage: $showsOnboardingImage,
          onClose: nil,
          showsModeSwitch: false,
          onRevealPerformed: {
            didRevealImage = true
          },
          onImageInteractionPerformed: {
            didMoveImage = true
          }
        )

        if didRevealImage && !didMoveImage {
          ImageMoveTeachingPill()
            .padding(.bottom, 110)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        if canAdvanceFromImageReader {
          Button {
            withAnimation(.easeInOut(duration: 0.22)) {
              step = .create
            }
            softHaptic()
          } label: {
            Label("Next", systemImage: "arrow.right")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(PrimaryActionButtonStyle())
          .padding(.horizontal, 20)
          .padding(.bottom, 28)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      case .create:
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
              Text("And this is how you create a message.")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
                .fixedSize(horizontal: false, vertical: true)

              Text("Add the note, choose a six-digit PIN, then seal it before sharing.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)

            ComposeSealedMessageView(
              store: store,
              proImageEntitlements: proImageEntitlements,
              title: "Create",
              initialMessage: "",
              completionActionTitle: "Complete onboarding",
              usesProgressiveOnboarding: true,
              onCreatedLink: { _ in },
              onTestMessage: { message, plaintext, imageData in
                senderPreviewSession = SenderPreviewSession(
                  message: plaintext,
                  imageData: imageData ?? demoCardImageData(),
                  link: message.link
                )
              },
              onCompletion: {
                onComplete()
              }
            )
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 32)
        }
      }
    }
    .textSelection(.disabled)
    .fullScreenCover(item: $senderPreviewSession) { session in
      SenderPreviewSessionView(message: session.message, imageData: session.imageData, link: session.link)
    }
  }
}

private struct SectionTitle: View {
  let title: String
  let systemImage: String

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.system(size: 18, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
  }
}

private struct FieldHeader: View {
  let title: String
  let isClearEnabled: Bool
  let onClear: () -> Void

  var body: some View {
    HStack(alignment: .center) {
      Text(title)
        .formLabelStyle()

      Spacer()

      if isClearEnabled {
        Button {
          onClear()
        } label: {
          Text("Clear")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear \(title)")
      }
    }
  }
}

private struct StatusLine: View {
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

private enum MessageMode: String, CaseIterable, Identifiable {
  case create
  case open

  var id: String { rawValue }

  var title: String {
    switch self {
    case .create:
      return "Create"
    case .open:
      return "Open"
    }
  }

  var systemImage: String {
    switch self {
    case .create:
      return "square.and.pencil"
    case .open:
      return "lock.open"
    }
  }
}

private struct ReaderSession: Identifiable {
  let id = UUID()
  let message: OpenedSealedMessage
}

private struct SenderPreviewSession: Identifiable {
  let id = UUID()
  let message: String
  let imageData: Data?
  let link: URL
}

private struct PrimaryActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .semibold, design: .rounded))
      .foregroundStyle(isEnabled ? Color(red: 0.035, green: 0.045, blue: 0.04) : Color.white.opacity(0.34))
      .padding(.vertical, 13)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(primaryFill(isPressed: configuration.isPressed))
      )
      .opacity(isEnabled ? 1 : 0.72)
  }

  private func primaryFill(isPressed: Bool) -> Color {
    guard isEnabled else {
      return Color.white.opacity(0.10)
    }

    return isPressed ? Color(red: 0.68, green: 0.86, blue: 0.78) : Color(red: 0.78, green: 0.96, blue: 0.86)
  }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
      .padding(.vertical, 11)
      .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.075), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.11), lineWidth: 1))
  }
}

private extension Text {
  func formLabelStyle() -> some View {
    font(.system(size: 12, weight: .semibold, design: .rounded))
      .textCase(.uppercase)
      .foregroundStyle(Color.white.opacity(0.50))
  }
}

private extension CGSize {
  func scaledToFit(in bounds: CGSize) -> CGSize {
    guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else {
      return .zero
    }

    let scale = min(bounds.width / width, bounds.height / height)
    return CGSize(width: width * scale, height: height * scale)
  }
}

private extension UIImage {
  func pixelatedForPrivacy() -> UIImage {
    guard size.width > 0, size.height > 0 else {
      return self
    }

    let maxPixelDimension: CGFloat = 22
    let aspectRatio = size.width / size.height
    let pixelSize: CGSize

    if aspectRatio >= 1 {
      pixelSize = CGSize(
        width: maxPixelDimension,
        height: max(1, round(maxPixelDimension / aspectRatio))
      )
    } else {
      pixelSize = CGSize(
        width: max(1, round(maxPixelDimension * aspectRatio)),
        height: maxPixelDimension
      )
    }

    let rendererFormat = UIGraphicsImageRendererFormat()
    rendererFormat.scale = 1
    rendererFormat.opaque = true
    let renderer = UIGraphicsImageRenderer(size: pixelSize, format: rendererFormat)
    let sampledImage = renderer.image { context in
      UIColor(red: 0.045, green: 0.047, blue: 0.043, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: pixelSize))
      context.cgContext.interpolationQuality = .low
      draw(in: CGRect(origin: .zero, size: pixelSize))
    }

    return sampledImage.shuffledPixels(seed: privacyPixelShuffleSeed(pixelSize: pixelSize)) ?? sampledImage
  }

  private func privacyPixelShuffleSeed(pixelSize: CGSize) -> UInt64 {
    var seed = UInt64(max(1, Int(pixelSize.width))) << 32
    seed ^= UInt64(max(1, Int(pixelSize.height))) << 16
    seed ^= UInt64(max(1, Int(size.width.rounded()))) &* 1_099_511_628_211
    seed ^= UInt64(max(1, Int(size.height.rounded()))) &* 14_695_981_039_346_656_037
    return seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
  }

  private func shuffledPixels(seed: UInt64) -> UIImage? {
    guard let cgImage else {
      return nil
    }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else {
      return nil
    }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let inputContext = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
      return nil
    }

    inputContext.interpolationQuality = .none
    inputContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var shuffledPixels = pixels
    let pixelCount = width * height
    var generator = PrivacyPixelShuffleGenerator(seed: seed)
    guard pixelCount > 1 else {
      return self
    }

    for index in stride(from: pixelCount - 1, through: 1, by: -1) {
      let swapIndex = Int(generator.next() % UInt64(index + 1))
      guard swapIndex != index else {
        continue
      }

      let sourceOffset = index * bytesPerPixel
      let swapOffset = swapIndex * bytesPerPixel

      for component in 0..<bytesPerPixel {
        shuffledPixels.swapAt(sourceOffset + component, swapOffset + component)
      }
    }

    guard let outputContext = CGContext(
      data: &shuffledPixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ),
    let outputImage = outputContext.makeImage() else {
      return nil
    }

    return UIImage(cgImage: outputImage, scale: scale, orientation: imageOrientation)
  }
}

private struct PrivacyPixelShuffleGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

private func normalizeImageAttachment(_ data: Data) throws -> (data: Data, preview: UIImage) {
  guard let sourceImage = UIImage(data: data) else {
    throw SealedMessageError.invalidAttachment
  }

  let maxDimension: CGFloat = 2400
  let sourceSize = sourceImage.size
  guard sourceSize.width > 0 && sourceSize.height > 0 else {
    throw SealedMessageError.invalidAttachment
  }

  let scale = min(1, maxDimension / max(sourceSize.width, sourceSize.height))
  let targetSize = CGSize(
    width: max(1, floor(sourceSize.width * scale)),
    height: max(1, floor(sourceSize.height * scale))
  )
  let rendererFormat = UIGraphicsImageRendererFormat()
  rendererFormat.scale = 1
  rendererFormat.opaque = true
  let renderer = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat)
  let normalizedImage = renderer.image { context in
    UIColor(red: 0.045, green: 0.047, blue: 0.043, alpha: 1).setFill()
    context.fill(CGRect(origin: .zero, size: targetSize))
    sourceImage.draw(in: CGRect(origin: .zero, size: targetSize))
  }

  let qualitySteps: [CGFloat] = [0.86, 0.74, 0.62]
  for quality in qualitySteps {
    guard let encoded = normalizedImage.jpegData(compressionQuality: quality) else {
      continue
    }

    if encoded.count <= SealedMessageCrypto.maxImageAttachmentByteCount {
      return (encoded, normalizedImage)
    }
  }

  throw SealedMessageError.invalidAttachment
}

private func softHaptic() {
  let generator = UIImpactFeedbackGenerator(style: .soft)
  generator.prepare()
  generator.impactOccurred(intensity: 0.35)
}

private func warningHaptic() {
  let generator = UINotificationFeedbackGenerator()
  generator.notificationOccurred(.warning)
}
