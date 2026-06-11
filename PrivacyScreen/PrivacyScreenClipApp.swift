import SwiftUI

#if APPCLIP
@main
struct PrivacyScreenClipApp: App {
  var body: some Scene {
    WindowGroup {
      SealedMessageRootView()
    }
  }
}
#endif
