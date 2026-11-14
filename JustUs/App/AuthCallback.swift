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
}
