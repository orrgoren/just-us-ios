import Foundation

extension SessionModel {
  /// Reloads after the app becomes active so a dropped Realtime socket rejoins
  /// and messages missed in the background show up.
  func becameActive() async {
    guard signedIn else { return }
    await refresh()
  }
}
