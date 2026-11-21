import CryptoKit
import Foundation

enum ChatRetention: String, Equatable, Sendable {
  case viewOnce = "view_once"
  case keep
}

enum ChatPhotoState: Equatable, Sendable {
  case viewOnce
  case opened
  case expired
  case kept
}

enum ChatPhoto {
  static let maxEdge: CGFloat = 2048
  static let byteLimit = 10 * 1024 * 1024
  /// An unopened view-once photo is removed the next time either phone opens the chat.
  static let lifetime: TimeInterval = 7 * 24 * 60 * 60

  static func fits(_ jpeg: Data) -> Bool {
    jpeg.isEmpty == false && jpeg.count <= byteLimit
  }

  static func objectPath(coupleId: UUID, messageId: UUID) -> String {
    let couple = coupleId.uuidString.lowercased()
    let message = messageId.uuidString.lowercased()
    return "\(couple)/\(message).bin"
  }

  static func expired(expiresAt: Date?, now: Date) -> Bool {
    guard let expiresAt else { return false }
    return expiresAt <= now
  }

  static func state(kind: String, retention: String?, hasObject: Bool, opened: Bool, expiresAt: Date?, now: Date) -> ChatPhotoState? {
    guard kind == "photo" else { return nil }
    if retention == ChatRetention.keep.rawValue {
      return hasObject ? .kept : nil
    }
    if opened { return .opened }
    if hasObject == false || expired(expiresAt: expiresAt, now: now) { return .expired }
    return .viewOnce
  }
}

enum ChatNotice {
  static func screenshot(_ name: String) -> String {
    "\(name) took a screenshot"
  }
}

enum ChatPushCopy {
  static let body = "New message"

  static func isQuiet(_ text: String) -> Bool {
    text == body && text.localizedCaseInsensitiveContains("photo") == false
  }
}

enum ChatPhotoCipher {
  private static let label = Data("justus-chat-photo-v1".utf8)

  static func package(
    jpeg: Data,
    messageId: UUID,
    senderUserId: UUID,
    from sender: ChatIdentity,
    to targets: [ChatTarget]
  ) throws -> (envelopes: [ChatEnvelope], object: Data) {
    guard ChatPhoto.fits(jpeg) else { throw AppError.chatPhotoTooBig }
    let content = SymmetricKey(size: .bits256)
    let raw = content.withUnsafeBytes { Data($0) }
    let envelopes = try ChatCrypto.sealData(
      raw, messageId: messageId, senderUserId: senderUserId, from: sender, to: targets
    )
    let sealed = try ChaChaPoly.seal(jpeg, using: content, authenticating: photoAAD(messageId))
    return (envelopes, sealed.combined)
  }

  static func jpeg(
    object: Data,
    envelopes: [ChatEnvelope],
    current: ChatIdentity,
    retired: [ChatIdentity],
    messageId: UUID,
    senderUserId: UUID,
    recipientUserId: UUID,
    senderPublic: Data
  ) throws -> Data {
    guard let raw = ChatHistory.openData(
      envelopes: envelopes, current: current, retired: retired, messageId: messageId,
      senderUserId: senderUserId, recipientUserId: recipientUserId, senderPublic: senderPublic
    ) else { throw ChatCryptoError.unreadable }
    let box = try ChaChaPoly.SealedBox(combined: object)
    return try ChaChaPoly.open(box, using: SymmetricKey(data: raw), authenticating: photoAAD(messageId))
  }

  private static func photoAAD(_ messageId: UUID) -> Data {
    var data = label
    data.append(Data(messageId.uuidString.lowercased().utf8))
    return data
  }
}

enum ChatTranscript {
  static func label(_ photo: ChatPhotoState) -> String {
    switch photo {
    case .viewOnce: return L10n.chatPhotoTap
    case .opened: return L10n.chatOpened
    case .expired: return L10n.chatExpired
    case .kept: return ""
    }
  }
}
