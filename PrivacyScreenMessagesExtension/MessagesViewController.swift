import Messages
import SwiftUI

final class MessagesViewController: MSMessagesAppViewController {
  private lazy var composeContext = MessagesComposeContext()
  private var hostingController: UIHostingController<MessagesComposeView>?

  override func viewDidLoad() {
    super.viewDidLoad()
    composeContext.messagesViewController = self
    installComposeView()
  }

  override func willBecomeActive(with conversation: MSConversation) {
    composeContext.activeConversation = conversation
    composeContext.select(message: conversation.selectedMessage)
  }

  override func didBecomeActive(with conversation: MSConversation) {
    composeContext.activeConversation = conversation
    composeContext.select(message: conversation.selectedMessage)
  }

  override func willResignActive(with conversation: MSConversation) {
    if composeContext.activeConversation === conversation {
      composeContext.activeConversation = nil
    }
  }

  override func didSelect(_ message: MSMessage, conversation: MSConversation) {
    composeContext.activeConversation = conversation
    composeContext.select(message: message)
    requestPresentationStyle(.expanded)
  }

  private func installComposeView() {
    let hostingController = UIHostingController(rootView: MessagesComposeView(context: composeContext))
    hostingController.view.backgroundColor = .clear
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    hostingController.didMove(toParent: self)
    self.hostingController = hostingController
  }
}

@MainActor
final class MessagesComposeContext: ObservableObject {
  @Published private(set) var canInsertMessages = false
  @Published private(set) var selectedMessageLink: URL?
  weak var messagesViewController: MSMessagesAppViewController?

  weak var activeConversation: MSConversation? {
    didSet {
      canInsertMessages = activeConversation != nil
    }
  }

  func select(message: MSMessage?) {
    guard let url = message?.url, SealedMessageCrypto.request(from: url) != nil else {
      selectedMessageLink = nil
      return
    }

    selectedMessageLink = url
  }

  func createNewMessage() {
    selectedMessageLink = nil
  }

  func dismiss() {
    messagesViewController?.dismiss()
  }

  func openInCryptoscreen(_ url: URL) async -> Bool {
    await withCheckedContinuation { continuation in
      messagesViewController?.extensionContext?.open(url) { [weak self] success in
        if success {
          Task { @MainActor in
            self?.messagesViewController?.dismiss()
          }
        }

        continuation.resume(returning: success)
      }
    }
  }

  func insertSealedMessage(
    _ createdMessage: CreatedSealedMessage,
    includePINMessage: Bool,
    dismissAfterInsert: Bool = false
  ) async throws {
    guard let activeConversation else {
      throw MessagesComposeContextError.noActiveConversation
    }

    let message = MSMessage()
    let layout = MSMessageTemplateLayout()
    layout.caption = "cryptoscreen"
    layout.subcaption = createdMessage.hasImageAttachment ? "Sealed message with image" : "Sealed message"
    layout.trailingSubcaption = includePINMessage ? "PIN follows" : "Send PIN separately"
    message.layout = layout
    message.summaryText = "cryptoscreen sealed message"
    message.url = createdMessage.link

    try await insert(message, into: activeConversation)

    if includePINMessage {
      try await insertText("PIN: \(createdMessage.pin)", into: activeConversation)
    }

    if dismissAfterInsert {
      dismiss()
    }
  }

  func insertPIN(_ pin: String, dismissAfterInsert: Bool = false) async throws {
    guard let activeConversation else {
      throw MessagesComposeContextError.noActiveConversation
    }
    try await insertText("PIN: \(pin)", into: activeConversation)

    if dismissAfterInsert {
      dismiss()
    }
  }

  private func insert(_ message: MSMessage, into conversation: MSConversation) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conversation.insert(message) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func insertText(_ text: String, into conversation: MSConversation) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conversation.insertText(text) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

private enum MessagesComposeContextError: Error {
  case noActiveConversation
}
