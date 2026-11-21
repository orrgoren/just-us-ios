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

/// Closing a view-once photo is local first. The server catch-up must not bring the tile back.
enum ChatOpen {
  static func seal(_ line: ChatLine) -> ChatLine {
    guard line.photo == .viewOnce || line.photo == .opened else { return line }
    var next = line
    next.photo = .opened
    next.text = L10n.chatOpened
    next.photoPath = nil
    next.previewJPEG = nil
    return next
  }
}

/// Closed view-once ids stay closed across a relaunch until the server agrees.
enum SealedOpens {
  static func load(_ userId: UUID, defaults: UserDefaults = .standard) -> Set<UUID> {
    let raw = defaults.stringArray(forKey: key(userId)) ?? []
    return Set(raw.compactMap { UUID(uuidString: $0) })
  }

  static func store(_ ids: Set<UUID>, userId: UUID, defaults: UserDefaults = .standard) {
    let values = ids.map(\.uuidString)
    defaults.set(values, forKey: key(userId))
  }

  private static func key(_ userId: UUID) -> String {
    "justus.sealed.\(userId.uuidString.lowercased())"
  }
}

/// One screenshot notice per photo inside a short window, on send and on screen.
enum ScreenshotDedup {
  static let window: TimeInterval = 3

  static func allow(messageId: UUID, now: Date, previous: (UUID, Date)?) -> Bool {
    guard let previous, previous.0 == messageId else { return true }
    return now.timeIntervalSince(previous.1) >= window
  }

  static func collapse(_ lines: [ChatLine], window: TimeInterval = ScreenshotDedup.window) -> [ChatLine] {
    var kept: [ChatLine] = []
    for line in lines {
      if line.notice, let prior = kept.last(where: { $0.notice && $0.text == line.text }) {
        if abs(line.createdAt.timeIntervalSince(prior.createdAt)) < window { continue }
      }
      kept.append(line)
    }
    return kept
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
    coupleId: UUID,
    retention: ChatRetention,
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
    let aad = photoAAD(messageId: messageId, coupleId: coupleId, retention: retention)
    let sealed = try ChaChaPoly.seal(jpeg, using: content, authenticating: aad)
    return (envelopes, sealed.combined)
  }

  static func jpeg(
    object: Data,
    envelopes: [ChatEnvelope],
    current: ChatIdentity,
    retired: [ChatIdentity],
    messageId: UUID,
    coupleId: UUID,
    retention: ChatRetention,
    senderUserId: UUID,
    recipientUserId: UUID,
    senderPublic: Data
  ) throws -> Data {
    guard let raw = ChatHistory.openData(
      envelopes: envelopes, current: current, retired: retired, messageId: messageId,
      senderUserId: senderUserId, recipientUserId: recipientUserId, senderPublic: senderPublic
    ) else { throw ChatCryptoError.unreadable }
    let box = try ChaChaPoly.SealedBox(combined: object)
    let aad = photoAAD(messageId: messageId, coupleId: coupleId, retention: retention)
    return try ChaChaPoly.open(box, using: SymmetricKey(data: raw), authenticating: aad)
  }

  /// The ciphertext is bound to this couple, this photo, and view-once or keep.
  static func photoAAD(messageId: UUID, coupleId: UUID, retention: ChatRetention) -> Data {
    var data = label
    data.append(Data(messageId.uuidString.lowercased().utf8))
    data.append(Data(coupleId.uuidString.lowercased().utf8))
    data.append(Data("photo".utf8))
    data.append(Data(retention.rawValue.utf8))
    return data
  }
}

/// A missing object is already gone. Any other failure keeps the path for the next try.
enum ChatStorageRemoval {
  static func clearsPath(_ error: Error?) -> Bool {
    guard let error else { return true }
    let text = String(describing: error).lowercased()
    return text.contains("not found") || text.contains("notfound") || text.contains("404")
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
