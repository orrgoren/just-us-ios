import Foundation

enum InviteLinks {
  static func appURL(token: String) -> URL? {
    guard InviteRules.isTokenShape(token) else { return nil }
    return URL(string: "justus://invite/\(token)")
  }

  static func webURL(token: String, base: String = AppConfig.webURL) -> URL? {
    guard InviteRules.isTokenShape(token) else { return nil }
    let trimmed = base
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") else { return nil }
    return URL(string: trimmed + "/invite/" + token)
  }

  /// The share sheet carries the app link first, then the website, then the code.
  static func shareText(token: String, webBase: String = AppConfig.webURL) -> String? {
    guard let app = appURL(token: token)?.absoluteString else { return nil }
    let web = webURL(token: token, base: webBase)?.absoluteString
    return L10n.inviteShareText(app: app, web: web, code: token)
  }
}

enum PendingInviteStore {
  static let key = "justus.pendingInvite"

  static func save(_ token: String) {
    UserDefaults.standard.set(token, forKey: key)
  }

  static func current() -> String? {
    guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
    return InviteRules.token(from: raw)
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: key)
  }
}

enum InviteOutcome {
  /// The code cannot be used. A network failure is not a rejection.
  static func rejects(_ error: AppError) -> Bool {
    switch error {
    case .invalidInvite, .revokedInvite, .usedInvite, .expiredInvite, .selfRedeem, .coupleFull, .soloNotEmpty:
      return true
    default:
      return false
    }
  }
}
