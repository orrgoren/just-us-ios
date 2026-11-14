import SwiftUI

enum Launch {
  static let uitestKey = "justus.uitest"

  static func prepare() {
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-uitest") {
      UserDefaults.standard.set(true, forKey: uitestKey)
      if !arguments.contains("-uitestKeep") {
        resetFakeStoreIfNeeded(arguments)
      }
    }
    if arguments.contains("-uitest") {
      UIView.setAnimationsEnabled(false)
    }
  }

  static var isUITest: Bool {
    ProcessInfo.processInfo.arguments.contains("-uitest") || UserDefaults.standard.bool(forKey: uitestKey)
  }

  static var screenshot: String? {
    argument(after: "-JustUsScreen")
  }

  static var useFake: Bool {
    isUITest || screenshot != nil
  }

  static var preferredScheme: ColorScheme? {
    switch argument(after: "-JustUsAppearance") {
    case "dark": return .dark
    case "light": return .light
    default: return nil
    }
  }

  /// A UI-test relaunch, such as opening a deep link, repeats the same reset token.
  /// A new test passes a new token and starts from an empty store.
  private static func resetFakeStoreIfNeeded(_ arguments: [String]) {
    let openingLink = arguments.contains { $0.contains("://") }
    guard let flag = arguments.firstIndex(of: "-uitestReset") else {
      let repeatedLaunch = UserDefaults.standard.string(forKey: "justus.uitest.reset") != nil
      if openingLink || (repeatedLaunch && !arguments.contains("-JustUsScreen")) {
        return
      }
      FakeStore.resetFiles()
      return
    }
    let next = arguments.index(after: flag)
    guard arguments.indices.contains(next) else {
      FakeStore.resetFiles()
      return
    }
    let token = arguments[next]
    let key = "justus.uitest.reset"
    if UserDefaults.standard.string(forKey: key) == token { return }
    FakeStore.resetFiles()
    UserDefaults.standard.set(token, forKey: key)
  }

  static func argument(after flag: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    let next = arguments.index(after: index)
    guard arguments.indices.contains(next) else { return nil }
    return arguments[next]
  }
}

enum AppConfig {
  static var supabaseURL: String {
    value("SUPABASE_URL").replacingOccurrences(of: "/$()/", with: "//")
  }

  static var anonKey: String { value("SUPABASE_ANON_KEY") }
  static var webURL: String { value("APP_WEB_URL").replacingOccurrences(of: "/$()/", with: "//") }
  static var privacyURL: String { value("PRIVACY_POLICY_URL").replacingOccurrences(of: "/$()/", with: "//") }
  static var supportURL: String { value("SUPPORT_URL").replacingOccurrences(of: "/$()/", with: "//") }
  static var pushEnabled: Bool { value("APNS_ENABLED") == "YES" }

  static var refusesProductionLiveTests: Bool {
    supabaseURL.contains("vowmukhhnfhtnjlswkun.supabase.co")
  }

  private static func value(_ key: String) -> String {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
  }
}
