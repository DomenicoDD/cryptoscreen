import UIKit

@MainActor
final class ProximitySensor: ObservableObject {
  @Published private(set) var isCovered = false
  @Published private(set) var isMonitoringAvailable = false
  @Published var isManualRevealEnabled = false

  var isRevealActive: Bool {
    isCovered || isManualRevealEnabled
  }

  func start() {
    // iOS blanks the display when hardware proximity monitoring is active and covered.
    // The reveal gesture uses touch coverage instead so the screen stays on.
    UIDevice.current.isProximityMonitoringEnabled = false
    isMonitoringAvailable = false
    isCovered = false
  }

  func setScreenCoverActive(_ isActive: Bool) {
    guard isCovered != isActive else {
      return
    }

    isCovered = isActive
  }

  func stop() {
    isCovered = false
    UIDevice.current.isProximityMonitoringEnabled = false
  }
}
