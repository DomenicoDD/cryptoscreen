import Foundation

// Synthetic content only. Exercise the same CryptoKit implementation as the app.
@main
struct SealedMessageFixture {
  static func main() throws {
    let text = "Browser interoperability test — one-time note 🔐"
    let upload = try SealedMessageCrypto.sealForUpload(plaintext: text, pin: "123456")
    let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let attachment = try SealedMessageCrypto.sealImageAttachment(imageData: image, contentType: "image/png", upload: upload)
    let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let link = SealedMessageLink(messageID: id, secret: upload.linkSecret).url
    for candidate in [link.absoluteString, link.absoluteString.replacingOccurrences(of: "#", with: "?clip=1#"), link.absoluteString.replacingOccurrences(of: "https://cryptoscreen.app", with: "https://www.cryptoscreen.app")] {
      guard let request = SealedMessageCrypto.request(from: candidate), request.messageID == id, request.linkSecret == upload.linkSecret else {
        fatalError("Invocation URL did not preserve the message id and fragment")
      }
    }
    let fixture: [String: Any] = [
      "id": id.uuidString.lowercased(), "text": text, "pin": upload.normalizedPIN,
      "secret": upload.linkSecret.base64URLEncodedString(),
      "ciphertext": upload.ciphertext.base64URLEncodedString(),
      "nonce": upload.nonce.base64URLEncodedString(), "tag": upload.tag.base64URLEncodedString(),
      "salt": upload.salt.base64URLEncodedString(), "pinProof": upload.pinProof.base64URLEncodedString(),
      "revokeProof": upload.revokeProof.base64URLEncodedString(),
      "image": image.base64EncodedString(), "imageCiphertext": attachment.ciphertext.base64EncodedString(),
      "encryptedFileKey": attachment.encryptedFileKey.base64URLEncodedString()
    ]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]))
  }
}
