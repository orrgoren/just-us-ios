import Foundation

enum AuthCallback {
  static let scheme = "justus"
  static let host = "auth-callback"

  static var redirect: URL? {
    var parts = URLComponents()
    parts.scheme = scheme
    parts.host = host
    return parts.url
  }

  static func isCallback(_ url: URL) -> Bool {
    url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
  }

  static func params(_ url: URL) -> [String: String] {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
    var items: [String: String] = [:]
    for item in components.queryItems ?? [] {
      items[item.name] = item.value ?? ""
    }
    let fragment = components.percentEncodedFragment ?? components.fragment ?? ""
    for pair in fragment.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      let name = parts[0].removingPercentEncoding ?? parts[0]
      let value = parts[1].removingPercentEncoding ?? parts[1]
      items[name] = value
    }
    return items
  }

  /// Supabase puts `error_code=otp_expired` (and the used-link equivalents) on the callback itself.
  static func isStale(_ url: URL) -> Bool {
    let items = params(url)
    return items["error"] != nil || items["error_code"] != nil || items["error_description"] != nil
  }
}
