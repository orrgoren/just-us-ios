import Foundation
import os
import UserNotifications

enum PushRegistrationAction: Equatable {
  case register
  case offerPrompt
  case none
}

enum PushRegistration {
  /// Already granted, including provisional. The system prompt is not asked again.
  static func shouldRegister(_ status: UNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .provisional:
      return true
    case .notDetermined, .denied, .ephemeral:
      return false
    @unknown default:
      return false
    }
  }

  static func action(
    status: UNAuthorizationStatus,
    pushEnabled: Bool,
    alreadyAsked: Bool
  ) -> PushRegistrationAction {
    if shouldRegister(status) {
      return pushEnabled ? .register : .none
    }
    if status == .notDetermined, !alreadyAsked {
      return .offerPrompt
    }
    return .none
  }
}

struct DeviceTokenRecord: Equatable {
  var token: String?
  var awaitingSave: Bool
  /// The user whose upsert succeeded. A later launch sets `awaitingSave` again, so that flag
  /// cannot mean the server row is absent.
  var savedUserId: String? = nil

  mutating func received(_ token: String) {
    self.token = token
    awaitingSave = true
  }

  mutating func saved() {
    awaitingSave = false
  }

  mutating func saved(for userId: String) {
    saved()
    savedUserId = userId
  }

  func saveSucceeded(for userId: String) -> Bool {
    savedUserId == userId
  }

  /// Sign-out deletes the server row. The same device token has to be saved for the next account.
  mutating func removedFromAccount() {
    if token != nil {
      awaitingSave = true
    }
  }
}

enum DeviceTokenSaveStep: Equatable {
  case upsertPlain
  case giveUp
}

enum DeviceTokenSignOut {
  enum Failure: Error, Equatable {
    case removedNoRows
  }

  /// Deletes the row while the old session is still the caller, then signs out.
  /// A known token is always deleted. Zero returned rows block sign-out only when this
  /// user has already had a successful save, because that row can still be on the server
  /// while a later save is pending or failed. A token that was never saved has no row.
  static func perform(
    token: String?,
    saveSucceeded: Bool,
    delete: () async throws -> Int,
    authSignOut: () async -> Void
  ) async throws {
    if token?.isEmpty == false {
      let removed = try await delete()
      if removed < 1, saveSucceeded { throw Failure.removedNoRows }
    }
    await authSignOut()
  }
}

enum JoinLanding {
  static func screen(production: Bool = false, isUITest: Bool = Launch.isUITest) -> SessionModel.Screen {
    #if DEBUG
    if production || Launch.productionJoin { return .softPrompt }
    return isUITest ? .main : .softPrompt
    #else
    return .softPrompt
    #endif
  }
}

enum DeviceTokenSave {
  /// PostgREST and Postgres both say so when `environment` is not on the table.
  static func missingEnvironmentColumn(_ error: Error) -> Bool {
    let text = "\(String(describing: error)) \(error.localizedDescription)".lowercased()
    guard text.contains("environment") else { return false }
    let markers = ["column", "schema cache", "42703", "pgrst204", "does not exist", "could not find"]
    return markers.contains { text.contains($0) }
  }

  static func afterFailure(_ error: Error, attemptedPlain: Bool) -> DeviceTokenSaveStep {
    if !attemptedPlain, missingEnvironmentColumn(error) { return .upsertPlain }
    return .giveUp
  }
}

enum DeviceTokenStore {
  static let tokenKey = "justus.push.token"
  static let pendingKey = "justus.push.tokenPending"
  static let savedUserKey = "justus.push.savedUser"
  /// Leftover from a cross-user delete. It is wiped and never retried.
  static let deleteUserKey = "justus.push.deleteUser"
  static let deleteTokenKey = "justus.push.deleteToken"

  static func load() -> DeviceTokenRecord {
    DeviceTokenRecord(
      token: UserDefaults.standard.string(forKey: tokenKey),
      awaitingSave: UserDefaults.standard.bool(forKey: pendingKey),
      savedUserId: UserDefaults.standard.string(forKey: savedUserKey)
    )
  }

  static func save(_ record: DeviceTokenRecord) {
    if let token = record.token, !token.isEmpty {
      UserDefaults.standard.set(token, forKey: tokenKey)
    } else {
      UserDefaults.standard.removeObject(forKey: tokenKey)
    }
    UserDefaults.standard.set(record.awaitingSave, forKey: pendingKey)
    if let savedUserId = record.savedUserId, savedUserId.isEmpty == false {
      UserDefaults.standard.set(savedUserId, forKey: savedUserKey)
    } else {
      UserDefaults.standard.removeObject(forKey: savedUserKey)
    }
  }

  static func clearDelete() {
    UserDefaults.standard.removeObject(forKey: deleteUserKey)
    UserDefaults.standard.removeObject(forKey: deleteTokenKey)
  }

  static func reset() {
    UserDefaults.standard.removeObject(forKey: tokenKey)
    UserDefaults.standard.removeObject(forKey: pendingKey)
    UserDefaults.standard.removeObject(forKey: savedUserKey)
    clearDelete()
  }
}

enum PushLog {
  private static let logger = Logger(subsystem: "com.orrgoren.justus", category: "push")

  static func saveFailed(_ error: Error) {
    logger.error("device token save failed: \(String(describing: error), privacy: .private)")
  }

  static func saveFailed(_ message: String) {
    saveFailed(LoggedFailure(message))
  }

  static func deleteFailed(_ error: Error) {
    logger.error("device token delete failed: \(String(describing: error), privacy: .private)")
  }

  static func deleteFailed(_ message: String) {
    deleteFailed(LoggedFailure(message))
  }

  static func registrationFailed(_ error: Error) {
    logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
  }

  private struct LoggedFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
  }
}
