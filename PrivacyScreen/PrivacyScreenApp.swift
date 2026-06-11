import SwiftUI

#if !APPCLIP
@main
struct PrivacyScreenApp: App {
  var body: some Scene {
    WindowGroup {
      SealedMessageRootView()
    }
  }
}
#endif
