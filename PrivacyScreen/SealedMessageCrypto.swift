import CryptoKit
import Foundation
import Security

struct SealedMessageEnvelope: Identifiable, Equatable {
  let id: UUID
  let sealedPayload: Data
  let salt: Data
  let pinVerifier: Data
  let createdAt: Date
  let expiresAt: Date
  var failedAttempts: Int
  let maxAttempts: Int
}

struct SealedMessageUpload: Equatable {
  let ciphertext: Data
  let nonce: Data
  let tag: Data
  let salt: Data
  let pinProof: Data
  let linkSecret: Data
  let normalizedPIN: String
}

struct SealedImageAttachmentUpload: Equatable {
  let ciphertext: Data
  let encryptedFileKey: Data
  let contentType: String
  let originalByteCount: Int
}

struct OpenedSealedMessagePayload: Equatable {
  let ciphertext: Data
  let nonce: Data
  let tag: Data
  let salt: Data
}

struct OpenedSealedAttachment: Equatable {
  let data: Data
  let contentType: String
  let eventPath: String?
}

struct OpenedSealedMessage: Equatable {
  let plaintext: String
  let attachment: OpenedSealedAttachment?
  let retained: Bool
}

struct SealedMessageLink: Equatable {
  let messageID: UUID
  let secret: Data

  var url: URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "cryptoscreen.app"
    components.path = "/m/\(messageID.uuidString.lowercased())"
    components.fragment = "s=\(secret.base64URLEncodedString())"

    return components.url ?? URL(string: "https://cryptoscreen.app")!
  }
}

struct CreatedSealedMessage: Identifiable, Equatable {
  let id: UUID
  let link: URL
  let pin: String
  let expiresAt: Date
  let hasImageAttachment: Bool
}

enum MessageOpenResult: Equatable {
  case opened(OpenedSealedMessage)
  case wrongPin(remainingAttempts: Int)
  case destroyed
  case expired
  case unavailable
  case invalidLink
  case invalidPin
  case corrupted
  case networkFailed
}

enum SealedMessageCrypto {
  static let pinLength = 6
  static let defaultMaxAttempts = 3
  static let defaultTimeToLive: TimeInterval = 60 * 60 * 24 * 30
  static let maxImageAttachmentByteCount = 10 * 1024 * 1024
  static let supportedImageContentTypes: Set<String> = ["image/jpeg", "image/png", "image/heic", "image/heif"]

  static func seal(
    plaintext: String,
    pin: String,
    maxAttempts: Int = defaultMaxAttempts,
    timeToLive: TimeInterval = defaultTimeToLive
  ) throws -> (envelope: SealedMessageEnvelope, link: SealedMessageLink) {
    let normalizedPIN = normalizePIN(pin)
    guard normalizedPIN.count == pinLength else {
      throw SealedMessageError.invalidPIN
    }

    let id = UUID()
    let linkSecret = try randomData(byteCount: 32)
    let salt = try randomData(byteCount: 16)
    let contentKey = deriveContentKey(linkSecret: linkSecret, pin: normalizedPIN, salt: salt)
    let sealedBox = try AES.GCM.seal(Data(plaintext.utf8), using: contentKey)

    guard let combinedPayload = sealedBox.combined else {
      throw SealedMessageError.missingCombinedPayload
    }

    let now = Date()
    let envelope = SealedMessageEnvelope(
      id: id,
      sealedPayload: combinedPayload,
      salt: salt,
      pinVerifier: makePINVerifier(linkSecret: linkSecret, pin: normalizedPIN),
      createdAt: now,
      expiresAt: now.addingTimeInterval(timeToLive),
      failedAttempts: 0,
      maxAttempts: maxAttempts
    )

    return (envelope, SealedMessageLink(messageID: id, secret: linkSecret))
  }

  static func sealForUpload(plaintext: String, pin: String) throws -> SealedMessageUpload {
    let normalizedPIN = normalizePIN(pin)
    guard normalizedPIN.count == pinLength else {
      throw SealedMessageError.invalidPIN
    }

    let linkSecret = try randomData(byteCount: 32)
    let salt = try randomData(byteCount: 16)
    let contentKey = deriveContentKey(linkSecret: linkSecret, pin: normalizedPIN, salt: salt)
    let sealedBox = try AES.GCM.seal(Data(plaintext.utf8), using: contentKey)

    return SealedMessageUpload(
      ciphertext: sealedBox.ciphertext,
      nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
      tag: sealedBox.tag,
      salt: salt,
      pinProof: makePINVerifier(linkSecret: linkSecret, pin: normalizedPIN),
      linkSecret: linkSecret,
      normalizedPIN: normalizedPIN
    )
  }

  static func sealImageAttachment(
    imageData: Data,
    contentType: String,
    upload: SealedMessageUpload
  ) throws -> SealedImageAttachmentUpload {
    guard supportedImageContentTypes.contains(contentType) else {
      throw SealedMessageError.invalidAttachment
    }
    guard !imageData.isEmpty && imageData.count <= maxImageAttachmentByteCount else {
      throw SealedMessageError.invalidAttachment
    }

    let imageKeyData = try randomData(byteCount: 32)
    let imageKey = SymmetricKey(data: imageKeyData)
    let imageBox = try AES.GCM.seal(imageData, using: imageKey)
    guard let imageCiphertext = imageBox.combined else {
      throw SealedMessageError.missingCombinedPayload
    }

    let messageKey = deriveContentKey(linkSecret: upload.linkSecret, pin: upload.normalizedPIN, salt: upload.salt)
    let encryptedKeyBox = try AES.GCM.seal(imageKeyData, using: messageKey)
    guard let encryptedFileKey = encryptedKeyBox.combined else {
      throw SealedMessageError.missingCombinedPayload
    }

    return SealedImageAttachmentUpload(
      ciphertext: imageCiphertext,
      encryptedFileKey: encryptedFileKey,
      contentType: contentType,
      originalByteCount: imageData.count
    )
  }

  static func request(from link: String) -> MessageOpenRequest? {
    let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmedLink), let request = request(from: url) {
      return request
    }

    guard let embeddedURL = firstMessageURL(in: trimmedLink) else {
      return nil
    }

    return request(from: embeddedURL)
  }

  static func request(from url: URL) -> MessageOpenRequest? {
    let messageIDString = url.lastPathComponent
    guard let messageID = UUID(uuidString: messageIDString) else {
      return nil
    }

    let secretValue = value(named: "s", inFragmentOrQueryOf: url)
    guard let secretValue, let secret = Data(base64URLEncoded: secretValue), secret.count >= 32 else {
      return nil
    }

    return MessageOpenRequest(messageID: messageID, linkSecret: secret)
  }

  static func matchesPIN(_ pin: String, request: MessageOpenRequest, envelope: SealedMessageEnvelope) -> Bool {
    let normalizedPIN = normalizePIN(pin)
    guard normalizedPIN.count == pinLength else {
      return false
    }

    let verifier = makePINVerifier(linkSecret: request.linkSecret, pin: normalizedPIN)
    return constantTimeEquals(verifier, envelope.pinVerifier)
  }

  static func pinProof(request: MessageOpenRequest, pin: String) throws -> Data {
    let normalizedPIN = normalizePIN(pin)
    guard normalizedPIN.count == pinLength else {
      throw SealedMessageError.invalidPIN
    }

    return makePINVerifier(linkSecret: request.linkSecret, pin: normalizedPIN)
  }

  static func open(_ envelope: SealedMessageEnvelope, request: MessageOpenRequest, pin: String) throws -> String {
    let normalizedPIN = normalizePIN(pin)
    guard normalizedPIN.count == pinLength else {
      throw SealedMessageError.invalidPIN
    }

    let contentKey = deriveContentKey(linkSecret: request.linkSecret, pin: normalizedPIN, salt: envelope.salt)
    let box = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
    let plaintext = try AES.GCM.open(box, using: contentKey)

    guard let message = String(data: plaintext, encoding: .utf8) else {
      throw SealedMessageError.invalidPlaintext
    }

    return message
  }

  static func open(_ payload: OpenedSealedMessagePayload, request: MessageOpenRequest, pin: String) throws -> String {
    let normalizedPIN = normalizePIN(pin)
    guard normalizedPIN.count == pinLength else {
      throw SealedMessageError.invalidPIN
    }

    let contentKey = deriveContentKey(linkSecret: request.linkSecret, pin: normalizedPIN, salt: payload.salt)
    let nonce = try AES.GCM.Nonce(data: payload.nonce)
    let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.ciphertext, tag: payload.tag)
    let plaintext = try AES.GCM.open(box, using: contentKey)

    guard let message = String(data: plaintext, encoding: .utf8) else {
      throw SealedMessageError.invalidPlaintext
    }

    return message
  }

  static func openImageAttachment(
    ciphertext: Data,
    encryptedFileKey: Data,
    contentType: String,
    request: MessageOpenRequest,
    pin: String,
    salt: Data,
    eventPath: String?
  ) throws -> OpenedSealedAttachment {
    guard supportedImageContentTypes.contains(contentType) else {
      throw SealedMessageError.invalidAttachment
    }

    let normalizedPIN = normalizePIN(pin)
    guard normalizedPIN.count == pinLength else {
      throw SealedMessageError.invalidPIN
    }

    let messageKey = deriveContentKey(linkSecret: request.linkSecret, pin: normalizedPIN, salt: salt)
    let encryptedKeyBox = try AES.GCM.SealedBox(combined: encryptedFileKey)
    let imageKeyData = try AES.GCM.open(encryptedKeyBox, using: messageKey)
    let imageKey = SymmetricKey(data: imageKeyData)
    let imageBox = try AES.GCM.SealedBox(combined: ciphertext)
    let imageData = try AES.GCM.open(imageBox, using: imageKey)

    guard !imageData.isEmpty && imageData.count <= maxImageAttachmentByteCount else {
      throw SealedMessageError.invalidAttachment
    }

    return OpenedSealedAttachment(data: imageData, contentType: contentType, eventPath: eventPath)
  }

  static func normalizePIN(_ pin: String) -> String {
    String(pin.filter(\.isNumber).prefix(pinLength))
  }

  private static func deriveContentKey(linkSecret: Data, pin: String, salt: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: linkSecret + Data(pin.utf8)),
      salt: salt,
      info: Data("cryptoscreen content key v1".utf8),
      outputByteCount: 32
    )
  }

  private static func makePINVerifier(linkSecret: Data, pin: String) -> Data {
    let verifierKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: linkSecret + Data(pin.utf8)),
      salt: Data("cryptoscreen pin proof salt v1".utf8),
      info: Data("cryptoscreen pin verifier v1".utf8),
      outputByteCount: 32
    )
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data("cryptoscreen pin proof".utf8),
      using: verifierKey
    )

    return Data(mac)
  }

  private static func value(named name: String, inFragmentOrQueryOf url: URL) -> String? {
    for source in [url.fragment, url.query].compactMap({ $0 }) {
      let pairs = source.split(separator: "&")

      for pair in pairs {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == name else {
          continue
        }

        return parts[1].removingPercentEncoding ?? parts[1]
      }
    }

    return nil
  }

  private static func randomData(byteCount: Int) throws -> Data {
    var data = Data(count: byteCount)
    let status = data.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.baseAddress!)
    }

    guard status == errSecSuccess else {
      throw SealedMessageError.randomFailure
    }

    return data
  }

  private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else {
      return false
    }

    var difference: UInt8 = 0

    for index in 0..<lhs.count {
      difference |= lhs[index] ^ rhs[index]
    }

    return difference == 0
  }

  private static func firstMessageURL(in text: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
      return nil
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return detector
      .matches(in: text, options: [], range: range)
      .compactMap(\.url)
      .first { url in
        guard url.scheme == "https", url.host == "cryptoscreen.app" || url.host == "www.cryptoscreen.app" else {
          return false
        }

        return url.pathComponents.contains("m")
      }
  }
}

struct MessageOpenRequest: Equatable {
  let messageID: UUID
  let linkSecret: Data
}

enum SealedMessageError: Error {
  case invalidPIN
  case invalidAttachment
  case invalidPlaintext
  case missingCombinedPayload
  case randomFailure
}

extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URLEncoded value: String) {
    var base64 = String(value.filter { !$0.isWhitespace })
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    let paddingLength = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: paddingLength)

    self.init(base64Encoded: base64)
  }
}
