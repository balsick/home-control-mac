import Foundation
import HomeCore
import UserNotifications

/// Notifications: a washer or dryer cycle ended, and the SmartThings personal
/// token is about to expire or has expired. Permission is asked once
/// SmartThings works, not at launch.
@MainActor
enum Notifier {
  /// What a notification is about, so a click can lead to the right place.
  enum Kind: String {
    case cycle, token
  }

  /// Called when the user clicks one of the app's notifications.
  static var onOpen: ((Kind) -> Void)?

  private static let presenter = ForegroundPresenter()
  private static let tokenReminderID = "token-reminder"

  /// UNUserNotificationCenter aborts outside an app bundle (`swift run`).
  static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

  static func setUp() {
    guard available else { return }
    UNUserNotificationCenter.current().delegate = presenter
  }

  static func requestPermission() {
    guard available else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
      Log.info("notification permission: \(granted)" + (error.map { " (\($0.localizedDescription))" } ?? ""))
    }
  }

  static func cycleFinished(_ name: String, kind: ApplianceKind) {
    post(.cycle, title: name, body: kind == .washer ? "Il lavaggio è finito." : "L'asciugatura è finita.")
  }

  /// The token expired: without it the app can't tell when a cycle ends.
  static func smartThingsNeedsAttention(_ text: String) {
    guard available else { return }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [tokenReminderID])
    post(.token, title: "SmartThings", body: text, sound: false)
  }

  /// One reminder an hour before the personal token expires. A new token
  /// moves it; nil (no token, or OAuth) removes it.
  static func remindTokenExpiry(at expiry: Date?) {
    guard available else { return }
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [tokenReminderID])
    guard let expiry else { return }
    let delay = expiry.addingTimeInterval(-3600).timeIntervalSinceNow
    guard delay > 0 else { return }
    let content = UNMutableNotificationContent()
    content.title = "SmartThings"
    content.body = "Il token scade alle \(Format.time(expiry)): fai clic per rinnovarlo."
    content.userInfo = ["kind": Kind.token.rawValue]
    center.add(UNNotificationRequest(identifier: tokenReminderID, content: content,
                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
    Log.info("token reminder at \(Format.time(expiry.addingTimeInterval(-3600)))")
  }

  private static func post(_ kind: Kind, title: String, body: String, sound: Bool = true) {
    guard available else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.userInfo = ["kind": kind.rawValue]
    if sound { content.sound = .default }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                 trigger: nil))
  }
}

/// Shows banners even while the panel is open and the app is active, and
/// routes clicks on them.
final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let raw = response.notification.request.content.userInfo["kind"] as? String
    let kind = raw.flatMap { Notifier.Kind(rawValue: $0) } ?? .cycle
    Task { @MainActor in Notifier.onOpen?(kind) }
    completionHandler()
  }
}
