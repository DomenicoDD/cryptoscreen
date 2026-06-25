import PhotosUI
import SwiftUI
import UIKit

struct MessagesComposeView: View {
  @ObservedObject var context: MessagesComposeContext

  @AppStorage("cryptoscreen.messages.sharePINSeparately") private var sharePINSeparately = false
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
  @State private var isShowingReviewPrompt = false
  @FocusState private var focusedField: Field?

  private let sender = MessagesSenderService.production

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

  var body: some View {
    NavigationStack {
      Group {
        if let selectedMessageLink = context.selectedMessageLink {
          MessagesOpenSelectedView(context: context, link: selectedMessageLink)
            .id(selectedMessageLink.absoluteString)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              messageSection
              imageSection
              pinSection
              sharePINSection
              actionSection
            }
            .padding(16)
          }
          .scrollDismissesKeyboard(.interactively)
        }
      }
      .background(Color.black)
      .navigationTitle("cryptoscreen")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if context.selectedMessageLink != nil {
            Button("Create") {
              context.createNewMessage()
            }
            .foregroundStyle(.green)
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
      .sheet(isPresented: $isShowingReviewPrompt) {
        CryptoscreenReviewPrompt(
          sendFeedback: { feedback in
            try await sender.submitFeedback(message: feedback)
          },
          onDone: {
            isShowingReviewPrompt = false
            context.dismiss()
          }
        )
        .presentationDetents([.medium, .large])
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
          .foregroundStyle(.green)
        }
      }

      TextEditor(text: $message)
        .focused($focusedField, equals: .message)
        .frame(minHeight: 108)
        .padding(10)
        .scrollContentBackground(.hidden)
        .background(Color.white.opacity(0.08))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: message) { _, _ in
          createdMessage = nil
        }

      HStack(spacing: 8) {
        if !isMessageWithinSizeLimit {
          Text("Message is too long")
            .foregroundStyle(.orange)
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
            .foregroundStyle(.green)
          }

          Spacer()
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        if proImageEntitlements.isImageAttachmentUnlocked {
          PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("Add encrypted image", systemImage: "photo.badge.plus")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(Color.white.opacity(0.08))
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(normalizedPIN.count == SealedMessageCrypto.pinLength ? Color.green.opacity(0.65) : Color.white.opacity(0.12), lineWidth: 1)
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

  private var sharePINSection: some View {
    Toggle(isOn: $sharePINSeparately) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Share PIN in separate message")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
        Text("Default is off. Turn on to insert the PIN after the sealed link.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.switch)
    .tint(.green)
    .padding(12)
    .background(Color.white.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

        if !sharePINSeparately {
          Button {
            Task {
              await insertPIN(createdMessage.pin)
            }
          } label: {
            Label("Insert PIN separately", systemImage: "number")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(MessagesSecondaryButtonStyle())
          .disabled(isInserting || !context.canInsertMessages)
        }
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

      let prepared = try prepareImageForUpload(data)
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

      let createdMessage = try await sender.create(upload: upload, imageAttachment: imageAttachment)

      do {
        try await context.insertSealedMessage(
          createdMessage,
          includePINMessage: sharePINSeparately,
          dismissAfterInsert: false
        )
        let shouldShowReviewPrompt = ReviewPromptTracker.recordSuccessfulSend()
        await MainActor.run {
          statusText = sharePINSeparately ? "Sealed message and PIN inserted." : "Sealed message inserted."
          isShowingReviewPrompt = shouldShowReviewPrompt
          isSealing = false
          if !shouldShowReviewPrompt {
            context.dismiss()
          }
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
      try await context.insertSealedMessage(
        createdMessage,
        includePINMessage: sharePINSeparately,
        dismissAfterInsert: false
      )
      let shouldShowReviewPrompt = ReviewPromptTracker.recordSuccessfulSend()
      await MainActor.run {
        statusText = sharePINSeparately ? "Sealed message and PIN inserted." : "Sealed message inserted."
        isShowingReviewPrompt = shouldShowReviewPrompt
        isInserting = false
        if !shouldShowReviewPrompt {
          context.dismiss()
        }
      }
    } catch {
      await MainActor.run {
        statusText = "Could not insert the message into this conversation."
        isInserting = false
      }
    }
  }

  private func insertPIN(_ pin: String) async {
    isInserting = true
    statusText = nil

    do {
      try await context.insertPIN(pin, dismissAfterInsert: true)
      await MainActor.run {
        statusText = "PIN inserted."
        isInserting = false
      }
    } catch {
      await MainActor.run {
        statusText = "Could not insert the PIN into this conversation."
        isInserting = false
      }
    }
  }

  private func prepareImageForUpload(_ data: Data) throws -> (data: Data, preview: UIImage) {
    guard let image = UIImage(data: data) else {
      throw MessagesComposeViewError.invalidImage
    }

    let maxDimension: CGFloat = 1800
    let longestSide = max(image.size.width, image.size.height)
    let uploadImage: UIImage
    if longestSide > maxDimension {
      let scale = maxDimension / longestSide
      let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      let renderer = UIGraphicsImageRenderer(size: targetSize)
      uploadImage = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: targetSize))
      }
    } else {
      uploadImage = image
    }

    guard let jpegData = uploadImage.jpegData(compressionQuality: 0.82),
          !jpegData.isEmpty,
          jpegData.count <= SealedMessageCrypto.maxImageAttachmentByteCount else {
      throw MessagesComposeViewError.invalidImage
    }

    return (jpegData, uploadImage)
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
        statusColor = .green
      } else {
        statusText = "Could not open cryptoscreen. You can still create your own message here."
        statusColor = .orange
      }
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
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
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
      .foregroundStyle(.black)
      .padding(.vertical, 13)
      .background(configuration.isPressed ? Color.green.opacity(0.78) : Color.green)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

private struct MessagesSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.vertical, 12)
      .background(configuration.isPressed ? Color.white.opacity(0.16) : Color.white.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
