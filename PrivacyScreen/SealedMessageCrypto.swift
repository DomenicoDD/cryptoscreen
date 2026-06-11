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

struct OpenedSealedMessagePayload: Equatable {
  let ciphertext: Data
  let nonce: Data
  let tag: Data
  let salt: Data
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
}

enum MessageOpenResult: Equatable {
  case opened(String)
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

  static func request(from link: String) -> MessageOpenRequest? {
    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }

    return request(from: url)
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
}

struct MessageOpenRequest: Equatable {
  let messageID: UUID
  let linkSecret: Data
}

enum SealedMessageError: Error {
  case invalidPIN
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
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    let paddingLength = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: paddingLength)

    self.init(base64Encoded: base64)
  }
}
