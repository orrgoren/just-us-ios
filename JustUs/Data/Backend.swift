import Foundation
import os
import Supabase

@MainActor
protocol DateBackend: AnyObject {
  var onRemoteChange: (@MainActor () -> Void)? { get set }
  func sendCode(email: String) async throws
  func verify(email: String, code: String) async throws -> SessionUser
  func signInWithApple(idToken: String, nonce: String) async throws -> SessionUser
  func restore() async throws -> SessionUser?
  func signOut() async
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
  func registerDevice(token: String) async
  func setOffline(_ offline: Bool)
  func injectPartnerMood() async
  func preferences() -> PushPreferences
  func savePreferences(_ preferences: PushPreferences) async
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
    let text = String(describing: error).lowercased()
    if text.contains("jwt") || text.contains("401") || text.contains("sessionmissing") {
      return .sessionExpired
    }
    if text.contains("timed out") { return .timeout }
    if text.contains("offline") || text.contains("network") { return .offline }
    return .server(code: "unknown")
  }

  private static func fromPostgrest(_ error: PostgrestError) -> AppError {
    let blob = "\(error.code ?? "") \(error.message) \(error.details ?? "")".lowercased()
    if blob.contains("pgrst301") || blob.contains("jwt") { return .sessionExpired }
    if blob.contains("pgrst202") || blob.contains("42883") || blob.contains("could not find the function") {
      return .unavailable
    }
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
      ("over_email_send_rate_limit", .rateLimited)
    ]
    for item in codes where blob.contains(item.0) {
      return item.1
    }
    return .server(code: error.code ?? "postgrest")
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
