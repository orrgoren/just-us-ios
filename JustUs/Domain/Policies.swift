import CryptoKit
import Foundation
import Security

enum RitualPrivacy {
  static func seal(_ view: RitualSnapshot) -> RitualSnapshot {
    guard !view.isPlanner, !view.revealed else { return view }
    var copy = view
    copy.plan = nil
    return copy
  }

  static func containsSecret(_ view: RitualSnapshot, secret: String) -> Bool {
    let data = (try? JSONEncoder().encode(view)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    return text.contains(secret)
  }
}

enum InviteRules {
  static let pattern = #"^[A-Za-z0-9_-]{40,128}\z"#

  static func isTokenShape(_ token: String) -> Bool {
    token.range(of: pattern, options: .regularExpression) != nil
  }

  static func token(from urlOrText: String) -> String? {
    let trimmed = urlOrText.trimmingCharacters(in: .whitespacesAndNewlines)
    if isTokenShape(trimmed) { return trimmed }
    guard let url = URL(string: trimmed) else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    if let index = parts.firstIndex(of: "invite"), parts.indices.contains(index + 1) {
      let token = parts[index + 1]
      return isTokenShape(token) ? token : nil
    }
    if url.scheme == "justus", url.host == "invite" {
      let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return isTokenShape(token) ? token : nil
    }
    return nil
  }

  static func hash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func makeToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func canLeaveSolo(memberCount: Int, nonDraftCount: Int, planCount: Int, noteCount: Int) -> Bool {
    memberCount == 1 && nonDraftCount == 0 && planCount == 0 && noteCount == 0
  }

  static func landing(token: String?, eligibility: MembershipKind) -> InviteLanding {
    guard let token, !token.isEmpty else {
      return InviteLanding(showConfirm: false, replaceEmpty: false, redeem: false)
    }
    switch eligibility {
    case .none:
      return InviteLanding(showConfirm: true, replaceEmpty: false, redeem: true)
    case .emptySolo:
      return InviteLanding(showConfirm: true, replaceEmpty: true, redeem: true)
    case .kept:
      return InviteLanding(showConfirm: true, replaceEmpty: false, redeem: false)
    }
  }
}

struct InviteLanding: Equatable, Sendable {
  var showConfirm: Bool
  var replaceEmpty: Bool
  var redeem: Bool
}

enum DeepLinks {
  static func route(from url: URL) -> AppRoute? {
    if url.scheme == "justus" {
      let host = url.host ?? ""
      switch host {
      case "home", "week": return .home
      case "reveal": return .reveal
      case "memories": return .memories
      case "settings": return .settings
      case "invite":
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard InviteRules.isTokenShape(token) else { return nil }
        return .invite(token)
      case "push":
        return pushRoute(url.lastPathComponent)
      default:
        return nil
      }
    }
    if let token = InviteRules.token(from: url.absoluteString), url.path.contains("/invite/") {
      return .invite(token)
    }
    return nil
  }

  static func pushRoute(_ type: String) -> AppRoute {
    switch type {
    case "plan_ready", "planReady", "reveal": return .reveal
    case "partner_mood", "partnerMood", "weekly", "weeklyReminder": return .home
    case "invite_accepted", "inviteAccepted", "invite_nudge", "inviteNudge": return .settings
    default: return .home
    }
  }

  static func route(userInfo: [AnyHashable: Any]) -> AppRoute {
    let type = (userInfo["type"] as? String) ?? (userInfo["screen"] as? String) ?? ""
    if type == "reveal" || type == "plan_ready" || type == "planReady" { return .reveal }
    if type == "memories" { return .memories }
    if type == "settings" || type == "invite_accepted" || type == "inviteAccepted" || type == "invite_nudge" || type == "inviteNudge" { return .settings }
    return pushRoute(type)
  }
}

enum PhotoSavePolicy {
  /// The database path is written only after the bytes are stored.
  /// A failed record rolls the object back and leaves the memory without a photo.
  static func shouldCommitPath(uploadSucceeded: Bool) -> Bool { uploadSucceeded }

  static func shouldDeleteObject(uploadSucceeded: Bool, recordSucceeded: Bool) -> Bool {
    uploadSucceeded && !recordSucceeded
  }
}

enum AccountDeletionPolicy {
  /// Either partner closing their account removes the shared space. The other person is left unpaired.
  static let closesTheSharedSpace = true
}
