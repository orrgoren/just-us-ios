import SwiftUI

enum Launch {
  static let uitestKey = "justus.uitest"

  static func prepare() {
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-uitest") {
      UserDefaults.standard.set(true, forKey: uitestKey)
      if !arguments.contains("-uitestKeep") {
        FakeStore.resetFiles()
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
