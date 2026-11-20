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
  static let maxBytes = 5600

  static func normalized(_ raw: String) throws -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { throw AppError.invalid(.note) }
    if text.count > maxCharacters || text.utf8.count > maxBytes { throw AppError.chatTooLong }
    return text
  }
}

enum KeyRotation {
  static let activeCap = 3
  /// A key the cap just retired does not take someone else's slot until this passes.
  static let backoff: TimeInterval = 15 * 60

  enum Reason: Equatable {
    case refresh
    case send
  }

  enum Step: Equatable {
    case keep
    case publish
    case hold
  }

  /// Opening the chat never publishes into a full set. A send may, after the backoff
  /// measured from when this phone's key was retired.
  static func step(
    hasRow: Bool,
    retired: Bool,
    activeCount: Int,
    retiredAt: Date?,
    now: Date,
    reason: Reason
  ) -> Step {
    if hasRow, retired == false { return .keep }
    if hasRow == false || activeCount < activeCap { return .publish }
    if reason == .refresh { return .hold }
    let since = retiredAt.map { now.timeIntervalSince($0) } ?? 0
    if since < backoff { return .hold }
    return .publish
  }

  /// A held send tells the person to wait. A held refresh keeps the key the phone already has.
  static func enforce(_ step: Step, reason: Reason) throws -> Step {
    if step == .hold, reason == .send { throw AppError.rateLimited }
    return step
  }
}

enum KeyCap {
  /// Same order as the database cap: newest `KeyRotation.activeCap` stay active.
  static func excessIds(_ active: [(id: UUID, createdAt: Date)]) -> [UUID] {
    let sorted = active.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id.uuidString > rhs.id.uuidString
    }
    return Array(sorted.dropFirst(KeyRotation.activeCap).map(\.id))
  }
}

enum ChatHistory {
  /// The current key goes first. Retired private keys still open what they sealed.
  static func open(
    envelopes: [ChatEnvelope],
    current: ChatIdentity,
    retired: [ChatIdentity],
    messageId: UUID,
    senderUserId: UUID,
    recipientUserId: UUID,
    senderPublic: Data
  ) -> String? {
    var seen: Set<UUID> = []
    for identity in [current] + retired where seen.insert(identity.id).inserted {
      guard envelopes.contains(where: { $0.keyId == identity.id }) else { continue }
      if let text = try? ChatCrypto.open(
        envelopes: envelopes, identity: identity, messageId: messageId,
        senderUserId: senderUserId, recipientUserId: recipientUserId, senderPublic: senderPublic
      ) {
        return text
      }
    }
    return nil
  }
}

/// The server insert finishes before the keychain changes. A failed insert keeps the old key.
enum KeyPublish {
  static func stage(
    insert: () async throws -> Void,
    commit: () throws -> Void
  ) async throws {
    try await insert()
    try commit()
  }
}

/// One publish at a time. The body stays on the caller's actor, so a second call sees the key the first one stored.
final class KeyPublishGate: @unchecked Sendable {
  private let lock = NSLock()
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func run<T>(_ body: () async throws -> T) async throws -> T {
    await acquire()
    do {
      let value = try await body()
      release()
      return value
    } catch {
      release()
      throw error
    }
  }

  private func acquire() async {
    if take() { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if busy == false {
        busy = true
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  private func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if busy { return false }
    busy = true
    return true
  }

  private func release() {
    lock.lock()
    let next: CheckedContinuation<Void, Never>? = waiters.isEmpty ? nil : waiters.removeFirst()
    if next == nil { busy = false }
    lock.unlock()
    next?.resume()
  }
}

enum ChatSignOut {
  /// A dead session at the token delete still signs out on this phone.
  /// A network failure while retiring puts the token back, then keeps the session.
  static func perform(
    deleteToken: () async throws -> Void,
    retire: () async throws -> Void,
    authSignOut: () async -> Void,
    recoverToken: () async -> Void = {}
  ) async throws {
    do {
      try await deleteToken()
    } catch {
      if continues(after: error) {
        await authSignOut()
        return
      }
      throw error
    }
    do {
      try await retire()
    } catch {
      if continues(after: error) == false {
        await recoverToken()
        throw error
      }
    }
    await authSignOut()
  }

  /// Status and error code only. A message that happens to contain "404" does not count.
  static func continues(after error: Error) -> Bool {
    if let app = error as? AppError {
      switch app {
      case .sessionExpired, .notAuthenticated, .linkExpired:
        return true
      case .server(let code):
        return isGone(code: code, status: nil)
      default:
        return false
      }
    }
    let failure = ErrorMap.httpFailure(error)
    return isGone(code: failure.code, status: failure.status)
  }

  static func isGone(code: String?, status: Int?) -> Bool {
    if status == 401 || status == 404 { return true }
    guard let code else { return false }
    let allowed = [
      "pgrst116", "pgrst301", "401", "404", "user_not_found", "session_not_found",
      "session_expired", "not_authenticated", "bad_jwt", "invalid_jwt",
      "refresh_token_not_found", "refresh_token_already_used"
    ]
    return allowed.contains(code.lowercased())
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
