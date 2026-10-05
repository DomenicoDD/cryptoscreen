import Foundation

final class StatusProtocol: URLProtocol {
  static var responseBody = ""
  static var requests = 0
  static var httpStatus = 200
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requests += 1
    precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
    let response = HTTPURLResponse(url: request.url!, statusCode: Self.httpStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@main
struct SentMessageStatusChecks {
  @MainActor
  static func main() async throws {
    let suite = "cryptoscreen.status-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StatusProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let api = SealedMessageAPI(baseURL: URL(string: "https://synthetic.invalid")!, session: session)
    let record = SentMessageRecord(id: UUID(), link: URL(string: "https://synthetic.invalid/m/test")!, pin: "123456", createdAt: Date(), characterCount: 4, status: .active)
    func seed() throws {
      try defaults.set(JSONEncoder().encode([record]), forKey: "cryptoscreen.sentMessages")
    }
    try seed()
    StatusProtocol.responseBody = """
    {"status":"consumed","interactionStatusShared":false,"textConsumed":false,"imageAttachmentAttached":false,"imageAttachmentConsumed":false,"screenshotDetected":false}
    """
    let store = SealedMessageStore(api: api, defaults: defaults)
    await store.refreshSentMessageStatuses(allowsInteractionStatus: false)
    precondition(store.sentMessages[0].status == .consumed, "Web consumption must update with sender sharing off")
    precondition(store.pendingCount == 0)
    precondition(!store.sentMessages[0].interactionStatusShared)
    precondition(SealedMessageStore(api: api, defaults: defaults).sentMessages[0].status == .consumed, "Status must persist across launches")
    let calls = StatusProtocol.requests
    await store.refreshSentMessageStatuses(allowsInteractionStatus: false)
    precondition(StatusProtocol.requests == calls, "No detail polling for terminal messages when sharing is off")
    print("PASS: web-consumed status, active count, persistence, and terminal polling with sharing off")

    StatusProtocol.responseBody = """
    {"status":"consumed","interactionStatusShared":true,"textConsumed":true,"imageAttachmentAttached":true,"imageAttachmentConsumed":true,"screenshotDetected":true}
    """
    try seed()
    let privateStore = SealedMessageStore(api: api, defaults: defaults)
    await privateStore.refreshSentMessageStatuses(allowsInteractionStatus: false)
    precondition(privateStore.sentMessages[0].status == .consumed)
    precondition(!privateStore.sentMessages[0].textConsumed && !privateStore.sentMessages[0].screenshotDetected)
    await privateStore.refreshSentMessageStatuses(allowsInteractionStatus: true)
    precondition(privateStore.sentMessages[0].interactionStatusShared && privateStore.sentMessages[0].textConsumed && privateStore.sentMessages[0].imageConsumed)
    print("PASS: optional details require sender and recipient opt-in")

    for status in ["expired", "destroyed"] {
      try seed()
      StatusProtocol.responseBody = "{\"status\":\"\(status)\"}"
      let terminalStore = SealedMessageStore(api: api, defaults: defaults)
      await terminalStore.refreshSentMessageStatuses(allowsInteractionStatus: false)
      precondition(terminalStore.sentMessages[0].status.rawValue == status)
      precondition(terminalStore.pendingCount == 0)
    }
    try seed()
    StatusProtocol.httpStatus = 503
    let offlineStore = SealedMessageStore(api: api, defaults: defaults)
    await offlineStore.refreshSentMessageStatuses(allowsInteractionStatus: false)
    precondition(offlineStore.sentMessages[0].status == .active)
    print("PASS: expired/destroyed availability and preservation during network failure")
  }
}
