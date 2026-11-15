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

  mutating func received(_ token: String) {
    self.token = token
    awaitingSave = true
  }

  mutating func saved() {
    awaitingSave = false
  }

  /// Sign-out deletes the server row. The same device token has to be saved for the next account.
  mutating func removedFromAccount() {
    if token != nil {
      awaitingSave = true
    }
  }
}

struct PendingTokenDelete: Equatable {
  var userId: UUID
  var token: String
}

enum DeviceTokenSaveStep: Equatable {
  case upsertPlain
  case giveUp
}

enum PendingDelete {
  /// A failed retry of an older row stays. A new failure is stored only after that retry succeeds.
  static func replacement(
    existing: PendingTokenDelete?,
    retryCleared: Bool,
    failed: PendingTokenDelete
  ) -> PendingTokenDelete {
    if let existing, !retryCleared, existing != failed { return existing }
    return failed
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
  static let deleteUserKey = "justus.push.deleteUser"
  static let deleteTokenKey = "justus.push.deleteToken"

  static func load() -> DeviceTokenRecord {
    DeviceTokenRecord(
      token: UserDefaults.standard.string(forKey: tokenKey),
      awaitingSave: UserDefaults.standard.bool(forKey: pendingKey)
    )
  }

  static func save(_ record: DeviceTokenRecord) {
    if let token = record.token, !token.isEmpty {
      UserDefaults.standard.set(token, forKey: tokenKey)
    } else {
      UserDefaults.standard.removeObject(forKey: tokenKey)
    }
    UserDefaults.standard.set(record.awaitingSave, forKey: pendingKey)
  }

  static func loadDelete() -> PendingTokenDelete? {
    guard
      let user = UserDefaults.standard.string(forKey: deleteUserKey),
      let userId = UUID(uuidString: user),
      let token = UserDefaults.standard.string(forKey: deleteTokenKey),
      !token.isEmpty
    else { return nil }
    return PendingTokenDelete(userId: userId, token: token)
  }

  static func saveDelete(_ pending: PendingTokenDelete) {
    UserDefaults.standard.set(pending.userId.uuidString, forKey: deleteUserKey)
    UserDefaults.standard.set(pending.token, forKey: deleteTokenKey)
  }

  static func clearDelete() {
    UserDefaults.standard.removeObject(forKey: deleteUserKey)
    UserDefaults.standard.removeObject(forKey: deleteTokenKey)
  }

  static func reset() {
    UserDefaults.standard.removeObject(forKey: tokenKey)
    UserDefaults.standard.removeObject(forKey: pendingKey)
    clearDelete()
  }
}

enum PushLog {
  private static let logger = Logger(subsystem: "com.orrgoren.justus", category: "push")

  static func saveFailed(_ error: Error) {
    logger.error("device token save failed: \(String(describing: error), privacy: .public)")
  }

  static func saveFailed(_ message: String) {
    saveFailed(LoggedFailure(message))
  }

  static func deleteFailed(_ error: Error) {
    logger.error("device token delete failed: \(String(describing: error), privacy: .public)")
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
