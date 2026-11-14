import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushRouter {
  static let shared = PushRouter()
  var handler: ((AppRoute) -> Void)?
  private var seen: Set<String> = []

  func route(_ userInfo: [AnyHashable: Any], id: String) {
    guard seen.insert(id).inserted else { return }
    let route = DeepLinks.route(userInfo: userInfo)
    write(route)
    handler?(route)
  }

  func delivered() async {
    let notes = await UNUserNotificationCenter.current().deliveredNotifications()
    for note in notes {
      route(note.request.content.userInfo, id: note.request.identifier)
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
    await PushRouter.shared.route(notification.request.content.userInfo, id: notification.request.identifier)
    return [.banner, .sound]
  }
}

extension Notification.Name {
  static let justUsDeviceToken = Notification.Name("justus.deviceToken")
}
