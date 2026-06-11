import SwiftUI
import UIKit

@MainActor
final class SealedMessageStore: ObservableObject {
  @Published private(set) var pendingCount = 0

  private let api: SealedMessageAPI

  init(api: SealedMessageAPI = .production) {
    self.api = api
  }

  func create(message: String, pin: String) async throws -> CreatedSealedMessage {
    let upload = try SealedMessageCrypto.sealForUpload(plaintext: message, pin: pin)
    let createdMessage = try await api.create(upload: upload)
    pendingCount += 1

    return createdMessage
  }

  func consume(link: String, pin: String) async -> MessageOpenResult {
    let result = await api.consume(link: link, pin: pin)

    switch result {
    case .opened, .destroyed, .expired:
      pendingCount = max(0, pendingCount - 1)
    default:
      break
    }

    return result
  }
}

struct SealedMessageRootView: View {
  @StateObject private var store = SealedMessageStore()
  @State private var mode: MessageMode = .create
  @State private var openedSession: ReaderSession?
  @State private var incomingLink = ""
  @State private var incomingPIN = ""

  var body: some View {
    CaptureShield {
      ZStack {
        Color(red: 0.045, green: 0.047, blue: 0.043)
          .ignoresSafeArea()

        VStack(spacing: 0) {
          HeaderView(pendingCount: store.pendingCount)

#if APPCLIP
          ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
              OpenSealedMessageView(
                store: store,
                initialLink: incomingLink,
                initialPIN: incomingPIN
              ) { plaintext in
                openedSession = ReaderSession(message: plaintext)
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
                  onCreatedLink: { link in
                    incomingLink = link.absoluteString
                  },
                  onTestMessage: { message in
                    incomingLink = message.link.absoluteString
                    incomingPIN = message.pin
                    mode = .open
                  }
                )
              case .open:
                OpenSealedMessageView(
                  store: store,
                  initialLink: incomingLink,
                  initialPIN: incomingPIN
                ) { plaintext in
                  openedSession = ReaderSession(message: plaintext)
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
      SecureReaderSessionView(message: session.message)
    }
    .onOpenURL { url in
      incomingLink = url.absoluteString
      incomingPIN = ""
      mode = .open
    }
  }
}

private struct HeaderView: View {
  let pendingCount: Int

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

      Label("\(pendingCount)", systemImage: "lock.doc")
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(Color(red: 0.84, green: 0.92, blue: 1.0))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityLabel("\(pendingCount) sealed messages")
    }
    .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 18)
  }
}

private struct ComposeSealedMessageView: View {
  @ObservedObject var store: SealedMessageStore
  let onCreatedLink: (URL) -> Void
  let onTestMessage: (CreatedSealedMessage) -> Void

  @State private var message = "Meet me by the north entrance after the second bell. Read this once, then let it burn."
  @State private var pin = "427913"
  @State private var createdMessage: CreatedSealedMessage?
  @State private var errorMessage: String?
  @State private var isCreating = false

  private var canCreate: Bool {
    !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && pin.count == SealedMessageCrypto.pinLength
      && !isCreating
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SectionTitle(title: "Create", systemImage: "square.and.pencil")

      VStack(alignment: .leading, spacing: 10) {
        Text("Message")
          .formLabelStyle()

        TextEditor(text: $message)
          .font(.system(size: 16, weight: .regular, design: .rounded))
          .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 146)
          .padding(12)
          .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("Six-digit PIN")
          .formLabelStyle()

        PinBoxEntry(pin: $pin)
      }

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

      if let errorMessage {
        StatusLine(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: Color(red: 1.0, green: 0.68, blue: 0.38))
      }

      if let createdMessage {
        CreatedMessagePanel(createdMessage: createdMessage) {
          onTestMessage(createdMessage)
        }
      }
    }
  }

  private func createMessage() async {
    guard !isCreating else {
      return
    }

    isCreating = true
    defer {
      isCreating = false
    }

    do {
      let sealed = try await store.create(message: message, pin: pin)
      createdMessage = sealed
      errorMessage = nil
      message = ""
      pin = ""
      onCreatedLink(sealed.link)
      softHaptic()
    } catch SealedMessageError.invalidPIN {
      errorMessage = "Use a message and a six-digit PIN."
    } catch {
      errorMessage = "Could not reach cryptoscreen.app."
    }
  }
}

private struct CreatedMessagePanel: View {
  let createdMessage: CreatedSealedMessage
  let onUseLink: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      StatusLine(
        text: "Sealed on cryptoscreen.app. The server stores ciphertext only.",
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
        ShareLink(item: createdMessage.link) {
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
  let onOpen: (String) -> Void

  @State private var link = ""
  @State private var pin = ""
  @State private var status = "Paste or receive a cryptoscreen link, enter the PIN, then open it once."
  @State private var statusIcon = "link.badge.plus"
  @State private var statusTint = Color(red: 0.84, green: 0.92, blue: 1.0)
  @State private var isOpening = false

  private var canOpen: Bool {
    SealedMessageCrypto.request(from: link) != nil && pin.count == SealedMessageCrypto.pinLength && !isOpening
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SectionTitle(title: "Open", systemImage: "lock.open")

      VStack(alignment: .leading, spacing: 10) {
        Text("Message link")
          .formLabelStyle()

        HStack(spacing: 8) {
          TextField("https://cryptoscreen.app/m/...", text: $link)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))

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

        PinBoxEntry(pin: $pin)
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
    let result = await store.consume(link: link, pin: pin)
    isOpening = false

    switch result {
    case .opened(let plaintext):
      pin = ""
      status = "Consumed. The encrypted row was deleted before rendering."
      statusIcon = "flame.fill"
      statusTint = Color(red: 0.50, green: 0.92, blue: 0.68)
      onOpen(plaintext)
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

private struct PinBoxEntry: View {
  @Binding var pin: String
  @FocusState private var focusedIndex: Int?

  private let boxCount = SealedMessageCrypto.pinLength

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0..<boxCount, id: \.self) { index in
        TextField("", text: digitBinding(for: index))
          .keyboardType(.numberPad)
          .textContentType(index == 0 ? .oneTimeCode : nil)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .multilineTextAlignment(.center)
          .font(.system(size: 22, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
          .frame(maxWidth: .infinity, minHeight: 52)
          .background(Color.white.opacity(focusedIndex == index ? 0.105 : 0.065), in: RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.white.opacity(focusedIndex == index ? 0.24 : 0.10), lineWidth: 1)
          )
          .focused($focusedIndex, equals: index)
          .privacySensitive()
          .accessibilityLabel("PIN digit \(index + 1)")
      }
    }
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

  private func digitBinding(for index: Int) -> Binding<String> {
    Binding {
      let digits = Array(pin)
      guard digits.indices.contains(index) else {
        return ""
      }

      return String(digits[index])
    } set: { newValue in
      let inputDigits = newValue.filter(\.isNumber)
      var digits = Array(pin).map(String.init)

      while digits.count < boxCount {
        digits.append("")
      }

      guard !inputDigits.isEmpty else {
        digits[index] = ""
        pin = SealedMessageCrypto.normalizePIN(digits.joined())

        if index > 0 {
          focusedIndex = index - 1
        }

        return
      }

      let input = Array(inputDigits.prefix(boxCount - index)).map(String.init)

      for offset in input.indices {
        digits[index + offset] = input[offset]
      }

      pin = SealedMessageCrypto.normalizePIN(digits.joined())

      let nextIndex = index + input.count
      focusedIndex = nextIndex < boxCount ? nextIndex : nil
    }
  }
}

private struct SecureReaderSessionView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var message: String

  init(message: String) {
    _message = State(initialValue: message)
  }

  var body: some View {
    CaptureShield {
      ZStack(alignment: .topTrailing) {
        PrivacyReaderView(message: message)

        Button {
          message = ""
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 15, weight: .bold))
            .frame(width: 40, height: 40)
            .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .padding(.top, 14)
        .padding(.trailing, 14)
        .accessibilityLabel("Close message")
      }
      .onDisappear {
        message = ""
      }
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
  let message: String
}

private struct PrimaryActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.035, green: 0.045, blue: 0.04))
      .padding(.vertical, 13)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(configuration.isPressed ? Color(red: 0.68, green: 0.86, blue: 0.78) : Color(red: 0.78, green: 0.96, blue: 0.86))
      )
      .opacity(configuration.isPressed ? 0.82 : 1)
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

private func softHaptic() {
  let generator = UIImpactFeedbackGenerator(style: .soft)
  generator.prepare()
  generator.impactOccurred(intensity: 0.35)
}

private func warningHaptic() {
  let generator = UINotificationFeedbackGenerator()
  generator.notificationOccurred(.warning)
}
