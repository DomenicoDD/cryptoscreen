import PhotosUI
import SwiftUI
import UIKit

struct MessagesComposeView: View {
  @ObservedObject var context: MessagesComposeContext

  @AppStorage("cryptoscreen.messages.readPolicy") private var readPolicyRawValue = SealedMessageReadPolicy.appOnly.rawValue
  @StateObject private var proImageEntitlements = ProImageEntitlementStore()
  @State private var message = ""
  @State private var pin = ""
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var selectedImageData: Data?
  @State private var selectedImagePreview: UIImage?
  @State private var isSealing = false
  @State private var isInserting = false
  @State private var createdMessage: CreatedSealedMessage?
  @State private var statusText: String?
  @State private var isShowingImagePaywall = false
  @State private var insertedMessage: CreatedSealedMessage?
  @State private var didCopyPIN = false
  @FocusState private var focusedField: Field?

  private let sender = SealedMessageAPI.production

  private var normalizedPIN: String {
    SealedMessageCrypto.normalizePIN(pin)
  }

  private var messageByteCount: Int {
    message.utf8.count
  }

  private var isMessageWithinSizeLimit: Bool {
    messageByteCount <= SealedMessageCrypto.maxMessagePlaintextByteCount
  }

  private var canSeal: Bool {
    !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    isMessageWithinSizeLimit &&
    normalizedPIN.count == SealedMessageCrypto.pinLength &&
    context.canInsertMessages &&
    (selectedImageData == nil || proImageEntitlements.isImageAttachmentUnlocked) &&
    !isSealing
  }

  private var readPolicy: SealedMessageReadPolicy {
    SealedMessageReadPolicy(rawValue: readPolicyRawValue) ?? .appOnly
  }

  var body: some View {
    NavigationStack {
      Group {
        if let selectedMessageLink = context.selectedMessageLink {
          MessagesOpenSelectedView(context: context, link: selectedMessageLink)
            .id(selectedMessageLink.absoluteString)
        } else if let insertedMessage {
          PINHandoffView(
            pin: insertedMessage.pin,
            didCopy: didCopyPIN,
            onCopy: {
              // Local-only and short-lived so the PIN doesn't sync via Universal Clipboard or linger.
              UIPasteboard.general.setItems(
                [[UIPasteboard.typeAutomatic: insertedMessage.pin]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
              )
              didCopyPIN = true
            },
            onDone: {
              context.dismiss()
            }
          )
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              messageSection
              imageSection
              readPolicySection
              pinSection
              actionSection
            }
            .padding(16)
          }
          .scrollDismissesKeyboard(.interactively)
        }
      }
      .background(CSBackground())
      .navigationTitle("cryptoscreen")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if context.selectedMessageLink != nil {
            Button("Create") {
              context.createNewMessage()
            }
            .foregroundStyle(CSTheme.accent)
          } else {
            EmptyView()
          }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .task(id: selectedPhotoItem) {
        await loadSelectedImage()
      }
      .sheet(isPresented: $isShowingImagePaywall) {
        ProImageAttachmentPaywallView(entitlementStore: proImageEntitlements)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
      }
    }
  }

  private var messageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Message")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)

        Spacer()

        if !message.isEmpty {
          Button("Clear") {
            message = ""
            createdMessage = nil
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(CSTheme.accent)
        }
      }

      TextEditor(text: $message)
        .focused($focusedField, equals: .message)
        .frame(minHeight: 108)
        .padding(10)
        .scrollContentBackground(.hidden)
        .background(Color.white.opacity(0.08))
        .foregroundStyle(.white)
        .clipShape(CSTheme.card())
        .overlay(
          CSTheme.card()
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: message) { _, _ in
          createdMessage = nil
        }

      HStack(spacing: 8) {
        if !isMessageWithinSizeLimit {
          Text("Message is too long")
            .foregroundStyle(CSTheme.warning)
            .lineLimit(1)
        }

        Spacer()

        Text("\(message.count) characters | \(messageByteCount.formatted())/\(SealedMessageCrypto.maxMessagePlaintextByteCount.formatted()) bytes")
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var imageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Image")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      if let selectedImagePreview {
        HStack(spacing: 12) {
          Image(uiImage: selectedImagePreview)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

          VStack(alignment: .leading, spacing: 6) {
            Text("Encrypted image ready")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)

            Button("Remove image") {
              selectedPhotoItem = nil
              selectedImageData = nil
              self.selectedImagePreview = nil
              createdMessage = nil
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CSTheme.accent)
          }

          Spacer()
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(CSTheme.card())
      } else {
        if proImageEntitlements.isImageAttachmentUnlocked {
          PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("Add encrypted image", systemImage: "photo.badge.plus")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(Color.white.opacity(0.08))
              .clipShape(CSTheme.card())
          }
        } else {
          Button {
            focusedField = nil
            isShowingImagePaywall = true
          } label: {
            Label("Upgrade to Pro Images", systemImage: "lock.fill")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(Color.white.opacity(0.08))
              .clipShape(CSTheme.card())
          }
          .buttonStyle(.plain)

        }
      }
    }
  }

  private var pinSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Six-digit PIN")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      TextField("PIN", text: $pin)
        .focused($focusedField, equals: .pin)
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .font(.system(size: 26, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(Color.white.opacity(0.08))
        .clipShape(CSTheme.card())
        .overlay(
          CSTheme.card()
            .stroke(normalizedPIN.count == SealedMessageCrypto.pinLength ? CSTheme.accent.opacity(0.65) : Color.white.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: pin) { _, newValue in
          let normalized = SealedMessageCrypto.normalizePIN(newValue)
          if normalized != newValue || normalized.count > SealedMessageCrypto.pinLength {
            pin = String(normalized.prefix(SealedMessageCrypto.pinLength))
          }
          createdMessage = nil
        }
    }
  }

  private var readPolicySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Read availability")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      Picker("Read availability", selection: $readPolicyRawValue) {
        ForEach(SealedMessageReadPolicy.allCases, id: \.rawValue) { policy in
          Text(policy.title).tag(policy.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: readPolicyRawValue) { _, _ in
        createdMessage = nil
        statusText = nil
      }

      Text(readPolicy.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(Color.white.opacity(0.08))
    .clipShape(CSTheme.card())
  }

  @ViewBuilder
  private var actionSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let statusText {
        Text(statusText)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if let createdMessage {
        Button {
          Task {
            await insert(createdMessage)
          }
        } label: {
          Label(isInserting ? "Inserting..." : "Insert sealed message", systemImage: "lock.message")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MessagesPrimaryButtonStyle())
        .disabled(isInserting || !context.canInsertMessages)
      } else {
        Button {
          Task {
            await seal()
          }
        } label: {
          Label(isSealing ? "Sealing..." : "Seal message", systemImage: "lock.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MessagesPrimaryButtonStyle())
        .disabled(!canSeal)
      }
    }
  }

  private func loadSelectedImage() async {
    guard let selectedPhotoItem else {
      return
    }

    guard proImageEntitlements.isImageAttachmentUnlocked else {
      await MainActor.run {
        self.selectedPhotoItem = nil
        selectedImageData = nil
        selectedImagePreview = nil
        isShowingImagePaywall = true
      }
      return
    }

    do {
      guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else {
        throw MessagesComposeViewError.invalidImage
      }

      let prepared = try await ImageAttachmentPreparer.prepare(data, maxPixelDimension: 1800)
      await MainActor.run {
        selectedImageData = prepared.data
        selectedImagePreview = prepared.preview
        createdMessage = nil
        statusText = nil
      }
    } catch {
      await MainActor.run {
        selectedImageData = nil
        selectedImagePreview = nil
        statusText = "That image could not be prepared."
      }
    }
  }

  private func seal() async {
    guard canSeal else {
      if selectedImageData != nil && !proImageEntitlements.isImageAttachmentUnlocked {
        isShowingImagePaywall = true
      }
      return
    }

    focusedField = nil
    isSealing = true
    statusText = nil

    do {
      let upload = try SealedMessageCrypto.sealForUpload(plaintext: message, pin: normalizedPIN)
      let imageAttachment: SealedImageAttachmentUpload?
      if let selectedImageData {
        imageAttachment = try SealedMessageCrypto.sealImageAttachment(
          imageData: selectedImageData,
          contentType: "image/jpeg",
          upload: upload
        )
      } else {
        imageAttachment = nil
      }

      let createdMessage = try await sender.create(upload: upload, imageAttachment: imageAttachment, readPolicy: readPolicy)

      do {
        try await context.insertSealedMessage(createdMessage)
        await MainActor.run {
          isSealing = false
          showPINHandoff(for: createdMessage)
        }
      } catch {
        await MainActor.run {
          self.createdMessage = createdMessage
          statusText = "Message sealed, but it could not be inserted automatically."
          isSealing = false
        }
      }
    } catch {
      await MainActor.run {
        statusText = "Could not seal this message. Check your connection and try again."
        isSealing = false
      }
    }
  }

  private func insert(_ createdMessage: CreatedSealedMessage) async {
    isInserting = true
    statusText = nil

    do {
      try await context.insertSealedMessage(createdMessage)
      await MainActor.run {
        isInserting = false
        showPINHandoff(for: createdMessage)
      }
    } catch {
      await MainActor.run {
        statusText = "Could not insert the message into this conversation."
        isInserting = false
      }
    }
  }

  private func showPINHandoff(for createdMessage: CreatedSealedMessage) {
    self.createdMessage = nil
    message = ""
    pin = ""
    didCopyPIN = false
    withAnimation(.easeOut(duration: 0.2)) {
      insertedMessage = createdMessage
    }
  }


  private enum Field {
    case message
    case pin
  }
}

private struct MessagesOpenSelectedView: View {
  @ObservedObject var context: MessagesComposeContext
  let link: URL

  @State private var isOpening = false
  @State private var statusText = "Open in cryptoscreen for the hand-cover reveal reader."
  @State private var statusColor = Color.secondary

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Open securely")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)

          Text("Use the cryptoscreen app or App Clip to reveal this message. The iMessage drawer will not decrypt or consume it.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        LinkSummary(link: link)

        Button {
          Task {
            await openInCryptoscreen()
          }
        } label: {
          Label(isOpening ? "Opening..." : "Open in cryptoscreen", systemImage: isOpening ? "hourglass" : "arrow.up.forward.app")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MessagesPrimaryButtonStyle())
        .disabled(isOpening)

        Text(statusText)
          .font(.footnote)
          .foregroundStyle(statusColor)

        Button {
          context.createNewMessage()
        } label: {
          Label("Create message", systemImage: "square.and.pencil")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MessagesSecondaryButtonStyle())
      }
      .padding(16)
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle("cryptoscreen")
  }

  private func openInCryptoscreen() async {
    guard !isOpening else {
      return
    }

    isOpening = true
    statusText = "Opening cryptoscreen..."
    statusColor = .secondary

    let didOpen = await context.openInCryptoscreen(link)

    await MainActor.run {
      isOpening = false

      if didOpen {
        statusText = "Opened in cryptoscreen."
        statusColor = CSTheme.accent
      } else {
        statusText = "Could not open cryptoscreen. You can still create your own message here."
        statusColor = CSTheme.warning
      }
    }
  }
}

/// Shown after the link is inserted. The PIN deliberately never goes into the
/// same thread as the link: anyone who sees the conversation would hold both factors.
private struct PINHandoffView: View {
  let pin: String
  let didCopy: Bool
  let onCopy: () -> Void
  let onDone: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Label("Sealed link inserted", systemImage: "checkmark.seal.fill")
          .font(.headline)
          .foregroundStyle(CSTheme.accent)

        Text("Now share the PIN another way: say it out loud, or send it in a different app. Keeping the link and PIN apart is what protects the message.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Text(pin)
          .font(CSTheme.mono(30, .semibold))
          .tracking(6)
          .foregroundStyle(CSTheme.ink)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.white.opacity(0.08), in: CSTheme.card())
          .privacySensitive()
          .accessibilityLabel("PIN")
          .accessibilityValue(pin.map(String.init).joined(separator: " "))

        Button(action: onCopy) {
          Label(didCopy ? "Copied for 2 minutes" : "Copy PIN", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MessagesSecondaryButtonStyle())

        Button(action: onDone) {
          Text("Done")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MessagesPrimaryButtonStyle())
      }
      .padding(16)
    }
  }
}

private struct LinkSummary: View {
  let link: URL

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Selected message")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      Text(link.host ?? "cryptoscreen.app")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)

      Text(link.path)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(12)
    .background(Color.white.opacity(0.08))
    .clipShape(CSTheme.card())
    .overlay(
      CSTheme.card()
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
  }
}

private enum MessagesComposeViewError: Error {
  case invalidImage
}

private struct MessagesPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(CSTheme.accentInk)
      .padding(.vertical, 13)
      .background(LinearGradient(colors: [CSTheme.accent, CSTheme.accentDeep], startPoint: .top, endPoint: .bottom))
      .clipShape(CSTheme.card())
      .shadow(color: CSTheme.accent.opacity(configuration.isPressed ? 0.1 : 0.25), radius: 10, y: 4)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

private struct MessagesSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.vertical, 12)
      .background(configuration.isPressed ? Color.white.opacity(0.16) : Color.white.opacity(0.1))
      .clipShape(CSTheme.card())
  }
}
