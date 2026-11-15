import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushRouter {
  static let shared = PushRouter()
  var handler: ((AppRoute) -> Void)? {
    didSet { flush() }
  }
  private var seen: Set<String> = []
  private var pending: [AppRoute] = []

  /// A tap is the only thing that navigates. A banner and a delivered-notification
  /// poll used to call this with no tap and move the screen on their own.
  func route(_ userInfo: [AnyHashable: Any], id: String) {
    guard seen.insert(id).inserted else { return }
    let destination = DeepLinks.route(userInfo: userInfo)
    write(destination)
    guard let handler else {
      pending.append(destination)
      return
    }
    handler(destination)
  }

  private func flush() {
    guard let handler else { return }
    let queued = pending
    pending.removeAll()
    for destination in queued {
      handler(destination)
    }
  }

  private func write(_ route: AppRoute) {
    let name: String
    switch route {
    case .home: name = "home"
    case .reveal: name = "reveal"
    case .memories: name = "memories"
    case .settings: name = "settings"
    case .invite: name = "invite"
    }
    guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("last-push-screen.txt") else { return }
    try? name.write(to: url, atomically: true, encoding: .utf8)
  }
}

final class JustUsDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    NotificationCenter.default.post(name: .justUsDeviceToken, object: token)
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    PushLog.registrationFailed(error)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    await PushRouter.shared.route(response.notification.request.content.userInfo, id: response.notification.request.identifier)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    return [.banner, .sound]
  }
}

extension Notification.Name {
  static let justUsDeviceToken = Notification.Name("justus.deviceToken")
}
