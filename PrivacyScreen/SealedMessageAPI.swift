import Foundation

struct SealedMessageAPI {
  static let production = SealedMessageAPI(baseURL: URL(string: "https://cryptoscreen.app")!)

  let baseURL: URL
  var session: URLSession = .shared

  func create(upload: SealedMessageUpload) async throws -> CreatedSealedMessage {
    let body = CreateMessageRequest(
      ciphertext: upload.ciphertext.base64URLEncodedString(),
      nonce: upload.nonce.base64URLEncodedString(),
      tag: upload.tag.base64URLEncodedString(),
      salt: upload.salt.base64URLEncodedString(),
      pinProof: upload.pinProof.base64URLEncodedString(),
      ttlSeconds: Int(SealedMessageCrypto.defaultTimeToLive)
    )
    let response: CreateMessageResponse = try await send(
      path: "/api/messages",
      method: "POST",
      body: body
    )
    guard let messageID = UUID(uuidString: response.id) else {
      throw SealedMessageAPIError.invalidResponse
    }

    let link = SealedMessageLink(messageID: messageID, secret: upload.linkSecret)

    return CreatedSealedMessage(
      id: messageID,
      link: link.url,
      pin: upload.normalizedPIN,
      expiresAt: response.expiresAt
    )
  }

  func consume(link: String, pin: String) async -> MessageOpenResult {
    guard SealedMessageCrypto.normalizePIN(pin).count == SealedMessageCrypto.pinLength else {
      return .invalidPin
    }

    guard let request = SealedMessageCrypto.request(from: link) else {
      return .invalidLink
    }

    let pinProof: Data
    do {
      pinProof = try SealedMessageCrypto.pinProof(request: request, pin: pin)
    } catch {
      return .invalidPin
    }

    do {
      let body = ConsumeMessageRequest(pinProof: pinProof.base64URLEncodedString())
      let response: ConsumeMessageResponse = try await send(
        path: "/api/messages/\(request.messageID.uuidString.lowercased())/consume",
        method: "POST",
        body: body
      )

      switch response.status {
      case "opened":
        guard
          let ciphertext = response.ciphertext.flatMap(Data.init(base64URLEncoded:)),
          let nonce = response.nonce.flatMap(Data.init(base64URLEncoded:)),
          let tag = response.tag.flatMap(Data.init(base64URLEncoded:)),
          let salt = response.salt.flatMap(Data.init(base64URLEncoded:))
        else {
          return .corrupted
        }

        let payload = OpenedSealedMessagePayload(
          ciphertext: ciphertext,
          nonce: nonce,
          tag: tag,
          salt: salt
        )
        let plaintext = try SealedMessageCrypto.open(payload, request: request, pin: pin)
        return .opened(plaintext)
      case "wrong_pin":
        return .wrongPin(remainingAttempts: response.remainingAttempts)
      case "destroyed":
        return .destroyed
      case "expired":
        return .expired
      case "unavailable":
        return .unavailable
      default:
        return .networkFailed
      }
    } catch {
      return .networkFailed
    }
  }

  private func send<RequestBody: Encodable, ResponseBody: Decodable>(
    path: String,
    method: String,
    body: RequestBody
  ) async throws -> ResponseBody {
    guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
      throw SealedMessageAPIError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SealedMessageAPIError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw SealedMessageAPIError.httpStatus(httpResponse.statusCode)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
      return try decoder.decode(ResponseBody.self, from: data)
    } catch {
      throw SealedMessageAPIError.invalidResponse
    }
  }
}

private struct CreateMessageRequest: Encodable {
  let ciphertext: String
  let nonce: String
  let tag: String
  let salt: String
  let pinProof: String
  let ttlSeconds: Int
}

private struct CreateMessageResponse: Decodable {
  let id: String
  let maxAttempts: Int
  let expiresAt: Date
}

private struct ConsumeMessageRequest: Encodable {
  let pinProof: String
}

private struct ConsumeMessageResponse: Decodable {
  let status: String
  let remainingAttempts: Int
  let ciphertext: String?
  let nonce: String?
  let tag: String?
  let salt: String?
}

private enum SealedMessageAPIError: Error {
  case httpStatus(Int)
  case invalidResponse
}
