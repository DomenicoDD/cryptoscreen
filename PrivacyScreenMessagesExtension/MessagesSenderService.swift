import Foundation

struct MessagesSenderService {
  static let production = MessagesSenderService(baseURL: URL(string: "https://cryptoscreen.app")!)

  let baseURL: URL
  var session: URLSession = .shared

  func create(upload: SealedMessageUpload, imageAttachment: SealedImageAttachmentUpload? = nil) async throws -> CreatedSealedMessage {
    let body = MessagesCreateMessageRequest(
      ciphertext: upload.ciphertext.base64URLEncodedString(),
      nonce: upload.nonce.base64URLEncodedString(),
      tag: upload.tag.base64URLEncodedString(),
      salt: upload.salt.base64URLEncodedString(),
      pinProof: upload.pinProof.base64URLEncodedString(),
      revokeProof: upload.revokeProof.base64URLEncodedString(),
      ttlSeconds: Int(SealedMessageCrypto.defaultTimeToLive)
    )

    let response: MessagesCreateMessageResponse = try await send(
      path: "/api/messages",
      method: "POST",
      body: body
    )
    guard let messageID = UUID(uuidString: response.id) else {
      throw MessagesSenderServiceError.invalidResponse
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

  func submitFeedback(message: String) async throws {
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let body = MessagesSubmitFeedbackRequest(
      rating: 2,
      message: message,
      appVersion: appVersion,
      buildNumber: buildNumber,
      platform: "iMessage",
      device: nil,
      timestamp: timestamp
    )

    let _: MessagesSubmitFeedbackResponse = try await send(
      path: "/api/feedback",
      method: "POST",
      body: body
    )
  }

  private func uploadAttachment(messageID: UUID, attachment: SealedImageAttachmentUpload) async throws {
    guard let url = URL(string: "/api/messages/\(messageID.uuidString.lowercased())/attachment", relativeTo: baseURL)?.absoluteURL else {
      throw MessagesSenderServiceError.invalidResponse
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
      throw MessagesSenderServiceError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw MessagesSenderServiceError.httpStatus(httpResponse.statusCode)
    }
  }

  private func send<RequestBody: Encodable, ResponseBody: Decodable>(
    path: String,
    method: String,
    body: RequestBody
  ) async throws -> ResponseBody {
    guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
      throw MessagesSenderServiceError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw MessagesSenderServiceError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw MessagesSenderServiceError.httpStatus(httpResponse.statusCode)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(ResponseBody.self, from: data)
    } catch {
      throw MessagesSenderServiceError.invalidResponse
    }
  }
}

private struct MessagesCreateMessageRequest: Encodable {
  let ciphertext: String
  let nonce: String
  let tag: String
  let salt: String
  let pinProof: String
  let revokeProof: String
  let ttlSeconds: Int
}

private struct MessagesCreateMessageResponse: Decodable {
  let id: String
  let maxAttempts: Int
  let expiresAt: Date
}

private struct MessagesSubmitFeedbackRequest: Encodable {
  let rating: Int
  let message: String
  let appVersion: String?
  let buildNumber: String?
  let platform: String?
  let device: String?
  let timestamp: String
}

private struct MessagesSubmitFeedbackResponse: Decodable {
  let ok: Bool
}

private enum MessagesSenderServiceError: Error {
  case httpStatus(Int)
  case invalidResponse
}
