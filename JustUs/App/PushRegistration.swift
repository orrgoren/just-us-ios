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

enum DeviceTokenStore {
  static let tokenKey = "justus.push.token"
  static let pendingKey = "justus.push.tokenPending"

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

  static func reset() {
    UserDefaults.standard.removeObject(forKey: tokenKey)
    UserDefaults.standard.removeObject(forKey: pendingKey)
  }
}

enum PushLog {
  private static let logger = Logger(subsystem: "com.orrgoren.justus", category: "push")

  static func saveFailed(_ error: Error) {
    logger.error("device token save failed: \(String(describing: error), privacy: .public)")
  }

  static func deleteFailed(_ error: Error) {
    logger.error("device token delete failed: \(String(describing: error), privacy: .public)")
  }

  static func registrationFailed(_ error: Error) {
    logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
  }
}

struct PushFailure: Error, CustomStringConvertible {
  var description: String
}
