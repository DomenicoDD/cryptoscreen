import Messages
import SwiftUI

final class MessagesViewController: MSMessagesAppViewController {
  private lazy var composeContext = MessagesComposeContext()
  private var hostingController: UIHostingController<MessagesComposeView>?

  override func viewDidLoad() {
    super.viewDidLoad()
    installComposeView()
  }

  override func didBecomeActive(with conversation: MSConversation) {
    composeContext.activeConversation = conversation
  }

  override func willResignActive(with conversation: MSConversation) {
    if composeContext.activeConversation === conversation {
      composeContext.activeConversation = nil
    }
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

  weak var activeConversation: MSConversation? {
    didSet {
      canInsertMessages = activeConversation != nil
    }
  }

  func insertSealedMessage(_ createdMessage: CreatedSealedMessage, includePINMessage: Bool) async throws {
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
  }

  func insertPIN(_ pin: String) async throws {
    guard let activeConversation else {
      throw MessagesComposeContextError.noActiveConversation
    }
    try await insertText("PIN: \(pin)", into: activeConversation)
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
