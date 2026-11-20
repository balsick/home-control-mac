import Foundation
import HomeCore

/// Whether this Mac is on the network where the devices were found, judged
/// by the router's MAC address (re-read at most every 30 s). Before any
/// device was found, and when the router can't be read, it counts as home.
@MainActor
final class HomeNetwork {
  private static let key = "homeGateway"
  private var cached: String?
  private var readAt = Date.distantPast

  var isHome: Bool {
    guard let home = UserDefaults.standard.string(forKey: Self.key) else { return true }
    if Date().timeIntervalSince(readAt) > 30 {
      cached = NetworkFingerprint.current()
      readAt = Date()
    }
    return cached.map { $0 == home } ?? true
  }

  /// Called when devices answered: this network is home.
  func remember() {
    guard let current = NetworkFingerprint.current() else { return }
    cached = current
    readAt = Date()
    if UserDefaults.standard.string(forKey: Self.key) != current {
      UserDefaults.standard.set(current, forKey: Self.key)
      Log.info("home network: router \(current)")
    }
  }
}
