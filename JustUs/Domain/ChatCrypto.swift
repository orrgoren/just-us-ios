import CryptoKit
import Foundation

struct ChatIdentity {
  var id: UUID
  var privateKey: Curve25519.KeyAgreement.PrivateKey

  var publicKey: Data { privateKey.publicKey.rawRepresentation }

  static func generate() -> ChatIdentity {
    ChatIdentity(id: UUID(), privateKey: Curve25519.KeyAgreement.PrivateKey())
  }

  static func restored(id: UUID, privateKey: Data) throws -> ChatIdentity {
    ChatIdentity(id: id, privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))
  }
}

struct ChatEnvelope: Equatable, Sendable {
  var keyId: UUID
  var box: Data
}

struct ChatTarget: Equatable, Sendable {
  var keyId: UUID
  var userId: UUID
  var publicKey: Data
}

enum ChatCryptoError: Error {
  case unreadable
}

enum ChatText {
  /// Swift characters, so one emoji counts as one.
  static let maxCharacters = 1000
  /// Plaintext UTF-8 that still fits eight sealed boxes inside the 64 KiB envelope cap.
  static let maxBytes = 6000

  static func normalized(_ raw: String) throws -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { throw AppError.invalid(.note) }
    if text.count > maxCharacters || text.utf8.count > maxBytes { throw AppError.chatTooLong }
    return text
  }
}

enum OwnKeyPublish {
  enum Action: Equatable {
    case keep
    case insert
    case replace
  }

  /// `hasRow` is this phone's current public key. A retired row cannot be revived.
  static func action(hasRow: Bool, retired: Bool) -> Action {
    if hasRow == false { return .insert }
    if retired { return .replace }
    return .keep
  }
}

enum ChatSignOut {
  /// The token delete runs first. A failure there leaves the key active and the session signed in.
  static func perform(
    deleteToken: () async throws -> Void,
    retire: () async throws -> Void,
    authSignOut: () async -> Void
  ) async throws {
    try await deleteToken()
    do {
      try await retire()
    } catch {
      if continues(after: error) == false { throw error }
    }
    await authSignOut()
  }

  /// An expired session or a missing account should still finish signing out.
  static func continues(after error: Error) -> Bool {
    let mapped = error as? AppError ?? ErrorMap.app(error)
    switch mapped {
    case .sessionExpired, .notAuthenticated, .linkExpired:
      return true
    case .server(let code):
      return missing(code) || missing(String(describing: error))
    default:
      return missing(String(describing: error))
    }
  }

  private static func missing(_ text: String) -> Bool {
    let blob = text.lowercased()
    return blob.contains("not found") || blob.contains("pgrst116") || blob.contains("404")
  }
}

enum SenderKey {
  /// Active and retired keys both count. A rotated key still opens old messages.
  static func trusted(sender: Data, senderUserId: UUID, keys: [(userId: UUID, publicKey: Data)]) -> Bool {
    sender.count == 32 && keys.contains { $0.userId == senderUserId && $0.publicKey == sender }
  }
}

enum ChatRecipients {
  /// One person's phones. The envelope list allows two extra on top of both people.
  static let perUser = 3

  static func choose(
    senderUserId: UUID,
    senderKeyId: UUID,
    keys: [(id: UUID, userId: UUID, publicKey: Data, createdAt: Date, retired: Bool)]
  ) -> [ChatTarget] {
    let keys = keys.filter { $0.retired == false }
    let own = keys.filter { $0.userId == senderUserId }
    var kept: [ChatTarget] = []
    if let current = own.first(where: { $0.id == senderKeyId }) {
      kept.append(ChatTarget(keyId: current.id, userId: current.userId, publicKey: current.publicKey))
    }
    for key in newest(own) where key.id != senderKeyId && kept.count < perUser {
      kept.append(ChatTarget(keyId: key.id, userId: key.userId, publicKey: key.publicKey))
    }
    let partners = Set(keys.map(\.userId)).subtracting([senderUserId])
    let theirs = partners.flatMap { partner in
      newest(keys.filter { $0.userId == partner }).prefix(perUser).map {
        ChatTarget(keyId: $0.id, userId: $0.userId, publicKey: $0.publicKey)
      }
    }
    return kept + theirs
  }

  private static func newest(
    _ keys: [(id: UUID, userId: UUID, publicKey: Data, createdAt: Date, retired: Bool)]
  ) -> [(id: UUID, userId: UUID, publicKey: Data, createdAt: Date, retired: Bool)] {
    keys.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id.uuidString > rhs.id.uuidString
    }
  }
}

enum ChatWindow {
  static let limit = 100
  /// Retired rows loaded with the visible page. Active keys are always included.
  static let retiredKeys = 100

  /// Newest `limit` rows, oldest of that window first, so the screen reads downward to the latest.
  static func chronological(_ lines: [ChatLine]) -> [ChatLine] {
    Array(lines.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id.uuidString > rhs.id.uuidString
    }.prefix(limit).reversed())
  }
}

enum PartnerKeyMemory {
  static func changed<T: Hashable>(previous: some Sequence<T>, current: some Sequence<T>) -> Bool {
    let prior = Set(previous)
    guard prior.isEmpty == false else { return false }
    return Set(current).subtracting(prior).isEmpty == false
  }

  static func remember(userId: UUID, current: [String]) -> Bool {
    let key = storageKey(userId)
    let previous = UserDefaults.standard.stringArray(forKey: key) ?? []
    let didChange = changed(previous: previous, current: current)
    UserDefaults.standard.set(current, forKey: key)
    return didChange
  }

  static func clear(userId: UUID) {
    UserDefaults.standard.removeObject(forKey: storageKey(userId))
  }

  private static func storageKey(_ userId: UUID) -> String {
    "partner-keys-\(userId.uuidString)"
  }
}

enum ChatCrypto {
  /// The shared secret stays stable. Context is authenticated, so a v1 box fails closed.
  private static let info = Data("justus-chat-v1".utf8)
  static let version = "justus-chat-v2"

  static func seal(
    text: String,
    messageId: UUID,
    senderUserId: UUID,
    from sender: ChatIdentity,
    to targets: [ChatTarget]
  ) throws -> [ChatEnvelope] {
    try targets.map { target in
      let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: target.publicKey)
      let secret = try sender.privateKey.sharedSecretFromKeyAgreement(with: publicKey)
      let key = secret.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32
      )
      let aad = associatedData(
        messageId: messageId, senderUserId: senderUserId, recipientUserId: target.userId,
        senderKey: sender.publicKey, recipientKey: target.publicKey
      )
      let sealed = try ChaChaPoly.seal(Data(text.utf8), using: key, authenticating: aad)
      return ChatEnvelope(keyId: target.keyId, box: sealed.combined)
    }
  }

  /// `messageId` is the row id. A copied box under any other id fails the authenticated context.
  static func open(
    envelopes: [ChatEnvelope],
    identity: ChatIdentity,
    messageId: UUID,
    senderUserId: UUID,
    recipientUserId: UUID,
    senderPublic: Data
  ) throws -> String {
    guard let mine = envelopes.first(where: { $0.keyId == identity.id }) else { throw ChatCryptoError.unreadable }
    let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPublic)
    let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: sender)
    let key = secret.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32
    )
    let aad = associatedData(
      messageId: messageId, senderUserId: senderUserId, recipientUserId: recipientUserId,
      senderKey: senderPublic, recipientKey: identity.publicKey
    )
    let box = try ChaChaPoly.SealedBox(combined: mine.box)
    let clear = try ChaChaPoly.open(box, using: key, authenticating: aad)
    guard let text = String(data: clear, encoding: .utf8) else { throw ChatCryptoError.unreadable }
    return text
  }

  static func associatedData(
    messageId: UUID,
    senderUserId: UUID,
    recipientUserId: UUID,
    senderKey: Data,
    recipientKey: Data
  ) -> Data {
    var data = Data()
    func append(_ bytes: Data) {
      var count = UInt32(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
      data.append(bytes)
    }
    append(Data(version.utf8))
    append(Data(messageId.uuidString.lowercased().utf8))
    append(Data(senderUserId.uuidString.lowercased().utf8))
    append(Data(recipientUserId.uuidString.lowercased().utf8))
    append(senderKey)
    append(recipientKey)
    return data
  }
}

enum ChatCoding {
  static func text(_ data: Data) -> String {
    data.base64EncodedString()
  }

  static func data(_ text: String) -> Data? {
    Data(base64Encoded: text)
  }
}
