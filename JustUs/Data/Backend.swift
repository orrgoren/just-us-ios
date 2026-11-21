import Foundation
import os
import Supabase

@MainActor
protocol DateBackend: AnyObject {
  var onRemoteChange: (@MainActor () -> Void)? { get set }
  var onChatInsert: (@MainActor (ChatMessageRow) -> Void)? { get set }
  var onChatOpened: (@MainActor (UUID) -> Void)? { get set }
  var onChatReload: (@MainActor () -> Void)? { get set }
  func sendCode(email: String) async throws
  func verify(email: String, code: String) async throws -> SessionUser
  func session(from url: URL) async throws -> SessionUser
  func signInWithApple(idToken: String, nonce: String) async throws -> SessionUser
  func restore() async throws -> SessionUser?
  func signOut() async throws
  func dropExpiredSession() async
  func membership() async throws -> MembershipKind
  func createCouple(_ draft: CoupleDraft) async throws
  func ritual() async throws -> RitualSnapshot?
  func setMood(_ mood: MoodKey) async throws
  func setPlace(_ choice: PlaceChoice) async throws
  func surprise(excluding: [String]) async throws
  func saveHint(teaser: String, outfit: String, notes: String) async throws
  func saveDate(day: String, time: String, teaser: String, outfit: String, notes: String) async throws
  func reveal() async throws
  func skipWeek() async throws
  func swapPlanner() async throws
  func reopen() async throws
  func move(day: String, time: String) async throws
  func complete(note: String) async throws
  func ensureDraft() async throws
  func memories() async throws -> [MemoryItem]
  func saveNote(dateId: UUID, noteId: UUID?, text: String) async throws
  func deleteNote(id: UUID) async throws
  func savePhoto(dateId: UUID, jpeg: Data) async throws
  func settings() async throws -> SettingsSnapshot?
  func saveSettings(_ settings: SettingsSnapshot) async throws
  func createInvite() async throws -> String
  func redeem(token: String, replaceEmpty: Bool) async throws
  func unlink() async throws
  func deleteAccount() async throws
  func retryClosedPhotos() async
  func takeSpaceClosed() async -> Bool
  func registerDevice(token: String) async
  func setOffline(_ offline: Bool)
  func injectPartnerMood() async
  func preferences() -> PushPreferences
  func savePreferences(_ preferences: PushPreferences) async
  func messages() async throws -> [ChatLine]
  func sendMessage(_ text: String, id: UUID) async throws -> ChatLine
  func sendPhoto(_ jpeg: Data, retention: ChatRetention) async throws -> ChatLine
  func incomingLine(_ row: ChatMessageRow) async -> ChatLine?
  func invalidateChatCache()
  func chatPhoto(_ id: UUID) async throws -> Data
  func consumeViewOnce(_ id: UUID) async throws
  func deleteChatPhoto(_ id: UUID) async throws
  func sendScreenshotNotice(for photoId: UUID) async throws -> ChatLine?
  func partnerKeyNotice() -> String?
}

enum ErrorMap {
  static func app(_ error: Error) -> AppError {
    if let appError = error as? AppError { return appError }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
        return .offline
      case .timedOut:
        return .timeout
      default:
        break
      }
    }
    if let postgrest = error as? PostgrestError {
      return fromPostgrest(postgrest)
    }
    if let auth = error as? AuthError {
      return fromAuth(auth)
    }
    let text = String(describing: error).lowercased()
    if text.contains("jwt") || text.contains("401") || text.contains("sessionmissing") {
      return .sessionExpired
    }
    if text.contains("timed out") { return .timeout }
    if text.contains("offline") || text.contains("network") { return .offline }
    return .server(code: "unknown")
  }

  private static func fromAuth(_ error: AuthError) -> AppError {
    switch error {
    case .sessionMissing:
      return .sessionExpired
    case .pkceGrantCodeExchange(_, _, _), .implicitGrantRedirect(_):
      return .linkExpired
    case .api(let message, let code, _, let response):
      if isStaleLink(code.rawValue, message) { return .linkExpired }
      if isDeadSession(code.rawValue, message, status: response.statusCode) { return .sessionExpired }
      return .server(code: code.rawValue)
    default:
      let text = error.message.lowercased()
      if text.contains("session") || text.contains("jwt") { return .sessionExpired }
      return .server(code: "auth")
    }
  }

  private static func isStaleLink(_ code: String, _ message: String) -> Bool {
    let blob = "\(code) \(message)".lowercased()
    let markers = ["otp_expired", "flow_state_expired", "flow_state_not_found", "bad_code_verifier", "expired", "already used", "already been used"]
    return markers.contains { blob.contains($0) }
  }

  private static func isDeadSession(_ code: String, _ message: String, status: Int) -> Bool {
    let normalized = code.lowercased()
    let sessionCodes = [
      "session_expired", "session_not_found", "refresh_token_not_found",
      "refresh_token_already_used", "bad_jwt", "invalid_jwt"
    ]
    if sessionCodes.contains(normalized) { return true }
    let blob = "\(normalized) \(message.lowercased())"
    if blob.contains("jwt") || blob.contains("session") { return true }
    return status == 401
  }

  private static func fromPostgrest(_ error: PostgrestError) -> AppError {
    let blob = "\(error.code ?? "") \(error.message) \(error.details ?? "")".lowercased()
    if blob.contains("pgrst301") || blob.contains("jwt") { return .sessionExpired }
    if blob.contains("pgrst202") || blob.contains("42883") || blob.contains("could not find the function") {
      return .unavailable
    }
    if blob.contains("unknown_sender_key") { return .server(code: "unknown_sender_key") }
    let codes: [(String, AppError)] = [
      ("already_in_couple", .alreadyInCouple),
      ("solo_not_empty", .soloNotEmpty),
      ("invalid_invite", .invalidInvite),
      ("revoked_invite", .revokedInvite),
      ("used_invite", .usedInvite),
      ("expired_invite", .expiredInvite),
      ("couple_full", .coupleFull),
      ("not_planner", .notPlanner),
      ("missing_plan", .missingPlan),
      ("not_authenticated", .notAuthenticated),
      ("confirmation_required", .confirmationRequired),
      ("over_email_send_rate_limit", .rateLimited),
      ("chat_rate", .rateLimited)
    ]
    for item in codes where blob.contains(item.0) {
      return item.1
    }
    return .server(code: error.code ?? "postgrest")
  }

  /// The code and status a sign-out can trust. Message text is ignored, including a "404" inside it.
  static func httpFailure(_ error: Error) -> (code: String?, status: Int?) {
    if let postgrest = error as? PostgrestError {
      return (postgrest.code, nil)
    }
    if let http = error as? HTTPError {
      return (nil, http.response.statusCode)
    }
    if let auth = error as? AuthError {
      return authFailure(auth)
    }
    return (nil, nil)
  }

  private static func authFailure(_ error: AuthError) -> (code: String?, status: Int?) {
    switch error {
    case .api(_, _, _, let response):
      return (error.errorCode.rawValue, response.statusCode)
    case .sessionMissing, .jwtVerificationFailed:
      return (error.errorCode.rawValue, nil)
    default:
      return (nil, nil)
    }
  }

  /// A mood replay that the database rejects is not editable. 42501 is the
  /// privilege error PostgREST returns when the row no longer matches the
  /// policy, which happens after reveal. Other calls keep that code.
  static func moodReplay(_ error: Error) -> AppError {
    let mapped = app(error)
    if case .server(let code) = mapped, code == "42501" { return .notEditable }
    return mapped
  }
}

enum Telemetry {
  static let analytics: any AnalyticsRecording = LoggerAnalytics()
  static let crashes: any CrashReporting = LoggerCrash()
}

protocol AnalyticsRecording: Sendable {
  func record(_ event: AnalyticsEvent)
}

protocol CrashReporting: Sendable {
  func record(_ error: Error)
}

struct LoggerAnalytics: AnalyticsRecording {
  func record(_ event: AnalyticsEvent) {
    os.Logger(subsystem: "com.orrgoren.justus", category: "product")
      .info("\(String(describing: event), privacy: .public)")
  }
}

struct LoggerCrash: CrashReporting {
  func record(_ error: Error) {
    os.Logger(subsystem: "com.orrgoren.justus", category: "crash")
      .error("\(String(describing: error), privacy: .public)")
  }
}
