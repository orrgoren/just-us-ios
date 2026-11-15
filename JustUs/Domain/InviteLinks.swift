import Foundation

enum InviteLinks {
  static func appURL(token: String) -> URL? {
    guard InviteRules.isTokenShape(token) else { return nil }
    return URL(string: "justus://invite/\(token)")
  }

  static func webURL(token: String, base: String = AppConfig.webURL) -> URL? {
    guard InviteRules.isTokenShape(token) else { return nil }
    guard let httpBase = httpWebBase(base) else { return nil }
    return URL(string: httpBase + "/invite/" + token)
  }

  /// A non-empty base that is not http(s) is rewritten to https so the share text keeps the link.
  static func httpWebBase(_ base: String) -> String? {
    var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return trimmed }
    if let range = trimmed.range(of: "://") {
      let host = trimmed[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !host.isEmpty else { return nil }
      return "https://" + host
    }
    return "https://" + trimmed
  }

  /// The share sheet carries the app link first, then the website, then the code.
  static func shareText(token: String, webBase: String = AppConfig.webURL) -> String? {
    guard let app = appURL(token: token)?.absoluteString else { return nil }
    let web = webURL(token: token, base: webBase)?.absoluteString
    return L10n.inviteShareText(app: app, web: web, code: token)
  }
}

enum PendingInviteStore {
  static let tokenKey = "justus.pendingInvite"
  static let accountKey = "justus.pendingInvite.account"

  static func save(_ token: String, account: String?) {
    UserDefaults.standard.set(token, forKey: tokenKey)
    if let account, !account.isEmpty {
      UserDefaults.standard.set(account, forKey: accountKey)
    } else {
      UserDefaults.standard.removeObject(forKey: accountKey)
    }
  }

  static func current() -> String? {
    guard let raw = UserDefaults.standard.string(forKey: tokenKey) else { return nil }
    return InviteRules.token(from: raw)
  }

  /// Nil when the code was saved before sign-in. The next account may claim it.
  static var owner: String? {
    let raw = UserDefaults.standard.string(forKey: accountKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return nil }
    return raw
  }

  static func belongs(to account: String?) -> Bool {
    guard current() != nil else { return true }
    guard let owner else { return true }
    guard let account else { return false }
    return owner == account
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: tokenKey)
    UserDefaults.standard.removeObject(forKey: accountKey)
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
