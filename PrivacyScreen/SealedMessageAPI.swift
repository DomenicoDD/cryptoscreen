import Foundation

struct SealedMessageAPI {
  static let production = SealedMessageAPI(baseURL: URL(string: "https://cryptoscreen.app")!)

  let baseURL: URL
  var session: URLSession = .shared

  func create(upload: SealedMessageUpload, imageAttachment: SealedImageAttachmentUpload? = nil) async throws -> CreatedSealedMessage {
    let body = CreateMessageRequest(
      ciphertext: upload.ciphertext.base64URLEncodedString(),
      nonce: upload.nonce.base64URLEncodedString(),
      tag: upload.tag.base64URLEncodedString(),
      salt: upload.salt.base64URLEncodedString(),
      pinProof: upload.pinProof.base64URLEncodedString(),
      revokeProof: upload.revokeProof.base64URLEncodedString(),
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

    if let imageAttachment {
      try await uploadAttachment(messageID: messageID, attachment: imageAttachment)
    }

    let link = SealedMessageLink(messageID: messageID, secret: upload.linkSecret)

    return CreatedSealedMessage(
      id: messageID,
      link: link.url,
      pin: upload.normalizedPIN,
      expiresAt: response.expiresAt,
      hasImageAttachment: imageAttachment != nil
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
        let attachment = try await openAttachmentIfPresent(response.attachment, request: request, pin: pin, salt: salt)
        return .opened(
          OpenedSealedMessage(
            plaintext: plaintext,
            attachment: attachment,
            retained: response.retained ?? false,
            eventPath: response.eventPath
          )
        )
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

  func reportReadSessionEvent(eventPath: String, type: String = "screenshot", timestamp: Date = Date()) async {
    let timestampString = ISO8601DateFormatter().string(from: timestamp)
    let body = ReadSessionEventRequest(type: type, timestamp: timestampString)
    let _: ReadSessionEventResponse? = try? await send(
      path: eventPath,
      method: "POST",
      body: body
    )
  }

  func status(messageID: UUID) async throws -> SealedMessageRemoteDeliveryStatus {
    let response: MessageStatusResponse = try await send(
      path: "/api/messages/\(messageID.uuidString.lowercased())/status",
      method: "GET"
    )

    return SealedMessageRemoteDeliveryStatus(
      status: SealedMessageRemoteStatus(rawValue: response.status) ?? .consumed,
      textConsumed: response.textConsumed ?? false,
      imageAttachmentAttached: response.imageAttachmentAttached ?? false,
      imageAttachmentConsumed: response.imageAttachmentConsumed ?? false,
      screenshotDetected: response.screenshotDetected ?? false
    )
  }

  func expire(message: SentMessageRecord) async throws -> SealedMessageRemoteDeliveryStatus {
    guard let request = SealedMessageCrypto.request(from: message.link) else {
      throw SealedMessageAPIError.invalidResponse
    }

    let body = ExpireMessageRequest(revokeProof: SealedMessageCrypto.revokeProof(request: request).base64URLEncodedString())
    let response: MessageStatusResponse = try await send(
      path: "/api/messages/\(message.id.uuidString.lowercased())/expire",
      method: "POST",
      body: body
    )

    return SealedMessageRemoteDeliveryStatus(
      status: SealedMessageRemoteStatus(rawValue: response.status) ?? .expired,
      textConsumed: response.textConsumed ?? false,
      imageAttachmentAttached: response.imageAttachmentAttached ?? false,
      imageAttachmentConsumed: response.imageAttachmentConsumed ?? false,
      screenshotDetected: response.screenshotDetected ?? false
    )
  }

  func submitFeedback(
    rating: Int,
    message: String,
    appVersion: String?,
    buildNumber: String?,
    platform: String?,
    device: String?,
    timestamp: Date
  ) async throws {
    let timestampString = ISO8601DateFormatter().string(from: timestamp)
    let body = SubmitFeedbackRequest(
      rating: rating,
      message: message,
      appVersion: appVersion,
      buildNumber: buildNumber,
      platform: platform,
      device: device,
      timestamp: timestampString
    )
    let _: SubmitFeedbackResponse = try await send(
      path: "/api/feedback",
      method: "POST",
      body: body
    )
  }

  private func uploadAttachment(messageID: UUID, attachment: SealedImageAttachmentUpload) async throws {
    guard let url = URL(string: "/api/messages/\(messageID.uuidString.lowercased())/attachment", relativeTo: baseURL)?.absoluteURL else {
      throw SealedMessageAPIError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("image", forHTTPHeaderField: "X-Cryptoscreen-Attachment-Type")
    request.setValue(attachment.contentType, forHTTPHeaderField: "X-Cryptoscreen-Attachment-Content-Type")
    request.setValue(attachment.encryptedFileKey.base64URLEncodedString(), forHTTPHeaderField: "X-Cryptoscreen-Encrypted-File-Key")
    request.httpBody = attachment.ciphertext

    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SealedMessageAPIError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw SealedMessageAPIError.httpStatus(httpResponse.statusCode)
    }
  }

  private func openAttachmentIfPresent(
    _ attachment: ConsumeAttachmentResponse?,
    request: MessageOpenRequest,
    pin: String,
    salt: Data
  ) async throws -> OpenedSealedAttachment? {
    guard let attachment else {
      return nil
    }

    guard
      attachment.type == "image",
      let encryptedFileKey = Data(base64URLEncoded: attachment.encryptedFileKey)
    else {
      throw SealedMessageAPIError.invalidResponse
    }

    guard let url = URL(string: attachment.downloadPath, relativeTo: baseURL)?.absoluteURL else {
      throw SealedMessageAPIError.invalidResponse
    }

    var downloadRequest = URLRequest(url: url)
    downloadRequest.httpMethod = "GET"
    downloadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

    let (ciphertext, response) = try await session.data(for: downloadRequest)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SealedMessageAPIError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw SealedMessageAPIError.httpStatus(httpResponse.statusCode)
    }

    return try SealedMessageCrypto.openImageAttachment(
      ciphertext: ciphertext,
      encryptedFileKey: encryptedFileKey,
      contentType: attachment.contentType,
      request: request,
      pin: pin,
      salt: salt,
      eventPath: attachment.eventPath
    )
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

  private func send<ResponseBody: Decodable>(
    path: String,
    method: String
  ) async throws -> ResponseBody {
    guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
      throw SealedMessageAPIError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")

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

enum SealedMessageRemoteStatus: String, Codable {
  case active
  case consumed
  case expired
  case destroyed
}

struct SealedMessageRemoteDeliveryStatus: Equatable {
  let status: SealedMessageRemoteStatus
  let textConsumed: Bool
  let imageAttachmentAttached: Bool
  let imageAttachmentConsumed: Bool
  let screenshotDetected: Bool
}

private struct CreateMessageRequest: Encodable {
  let ciphertext: String
  let nonce: String
  let tag: String
  let salt: String
  let pinProof: String
  let revokeProof: String
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

private struct ExpireMessageRequest: Encodable {
  let revokeProof: String
}

private struct ConsumeMessageResponse: Decodable {
  let status: String
  let remainingAttempts: Int
  let retained: Bool?
  let ciphertext: String?
  let nonce: String?
  let tag: String?
  let salt: String?
  let eventPath: String?
  let attachment: ConsumeAttachmentResponse?
}

private struct ConsumeAttachmentResponse: Decodable {
  let id: String
  let type: String
  let contentType: String
  let byteLength: Int
  let encryptedFileKey: String
  let downloadPath: String
  let eventPath: String
  let expiresAt: Date
}

private struct MessageStatusResponse: Decodable {
  let status: String
  let textConsumed: Bool?
  let imageAttachmentAttached: Bool?
  let imageAttachmentConsumed: Bool?
  let screenshotDetected: Bool?
}

private struct SubmitFeedbackRequest: Encodable {
  let rating: Int
  let message: String
  let appVersion: String?
  let buildNumber: String?
  let platform: String?
  let device: String?
  let timestamp: String
}

private struct SubmitFeedbackResponse: Decodable {
  let ok: Bool
}

private struct ReadSessionEventRequest: Encodable {
  let type: String
  let timestamp: String
  let clientOptIn = true
}

private struct ReadSessionEventResponse: Decodable {
  let ok: Bool
}

private enum SealedMessageAPIError: Error {
  case httpStatus(Int)
  case invalidResponse
}
