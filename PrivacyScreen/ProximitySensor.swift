import Combine
import UIKit

@MainActor
final class ProximitySensor: ObservableObject {
  @Published private(set) var isCovered = false
  @Published private(set) var isMonitoringAvailable = false
  @Published var isManualRevealEnabled = false

  private var proximityCancellable: AnyCancellable?

  var isRevealActive: Bool {
    isCovered || isManualRevealEnabled
  }

  func start() {
    UIDevice.current.isProximityMonitoringEnabled = true
    isMonitoringAvailable = UIDevice.current.isProximityMonitoringEnabled
    isCovered = UIDevice.current.proximityState

    proximityCancellable = NotificationCenter.default
      .publisher(for: UIDevice.proximityStateDidChangeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.isCovered = UIDevice.current.proximityState
      }
  }

  func stop() {
    proximityCancellable = nil
    isCovered = false
    UIDevice.current.isProximityMonitoringEnabled = false
  }
}
