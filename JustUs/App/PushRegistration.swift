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
  /// The user and token of the last upsert that succeeded. A later launch sets `awaitingSave`
  /// again, and a newer token can fail to save, so neither flag means the server row is absent.
  var savedUserId: String?
  var savedToken: String?

  init(token: String? = nil, awaitingSave: Bool, savedUserId: String? = nil, savedToken: String? = nil) {
    self.token = token
    self.awaitingSave = awaitingSave
    self.savedUserId = savedUserId
    self.savedToken = savedToken
  }

  mutating func received(_ token: String) {
    self.token = token
    awaitingSave = true
  }

  mutating func saved() {
    awaitingSave = false
  }

  /// Records the user the upsert was sent for, and the token that upsert used.
  mutating func saved(for userId: String, token saved: String) {
    savedUserId = userId
    savedToken = saved
    if token == saved {
      awaitingSave = false
    }
  }

  func saveSucceeded(for userId: String) -> Bool {
    savedUserId == userId && savedToken?.isEmpty == false
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

  /// Deletes while the old session is still the caller, then signs out.
  /// The saved token is the one that must come back. A newer token whose save failed may
  /// delete zero rows. A token with no recorded save may still have committed, so that
  /// delete is best-effort and never blocks sign-out.
  static func perform(
    current: String?,
    saved: String?,
    saveSucceeded: Bool,
    delete: (String) async throws -> Int,
    authSignOut: () async -> Void
  ) async throws {
    let savedToken = saved.flatMap { $0.isEmpty ? nil : $0 }
    let currentToken = current.flatMap { $0.isEmpty ? nil : $0 }
    if saveSucceeded, let savedToken {
      let removed = try await delete(savedToken)
      guard removed > 0 else { throw Failure.removedNoRows }
      if let currentToken, currentToken != savedToken {
        _ = try await delete(currentToken)
      }
    } else if let currentToken {
      _ = try? await delete(currentToken)
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
  static let savedTokenKey = "justus.push.savedToken"
  /// Leftover from a cross-user delete. It is wiped and never retried.
  static let deleteUserKey = "justus.push.deleteUser"
  static let deleteTokenKey = "justus.push.deleteToken"

  static func load() -> DeviceTokenRecord {
    DeviceTokenRecord(
      token: UserDefaults.standard.string(forKey: tokenKey),
      awaitingSave: UserDefaults.standard.bool(forKey: pendingKey),
      savedUserId: UserDefaults.standard.string(forKey: savedUserKey),
      savedToken: UserDefaults.standard.string(forKey: savedTokenKey)
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
    if let savedToken = record.savedToken, savedToken.isEmpty == false {
      UserDefaults.standard.set(savedToken, forKey: savedTokenKey)
    } else {
      UserDefaults.standard.removeObject(forKey: savedTokenKey)
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
    UserDefaults.standard.removeObject(forKey: savedTokenKey)
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
