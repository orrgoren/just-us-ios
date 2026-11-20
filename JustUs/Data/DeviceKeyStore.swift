import Foundation
import Security

enum DeviceKeyStore {
  private static let service = "com.orrgoren.justus.chat-key"
  /// The previous account was shared by every login on the phone, so two people got one key id.
  private static let legacyAccount = "device"
  /// A phone that rotated on every refresh used to fill the keychain. Keep the recent ones.
  private static let retiredLimit = 40

  static func loadOrCreate(userId: UUID) throws -> ChatIdentity {
    if let existing = try load(userId: userId) {
      SecItemDelete(legacyQuery() as CFDictionary)
      return existing
    }
    // One shared item used to serve every login. Keep it for this account, then drop it
    // so the next person on the phone does not publish the same key id.
    if let legacy = try loadLegacy() {
      try save(legacy, userId: userId)
      SecItemDelete(legacyQuery() as CFDictionary)
      return legacy
    }
    let created = ChatIdentity.generate()
    try save(created, userId: userId)
    return created
  }

  /// Private keys this phone used before the current one, keyed by their public key.
  static func retired(userId: UUID) -> [ChatIdentity] {
    guard let ring = try? readRing(baseQuery(userId: userId)) else { return [] }
    return ring.retired.compactMap(identity)
  }

  /// Stores `current` and keeps `retiring` so older envelopes still open. Call this only after the server insert succeeds.
  static func commit(current: ChatIdentity, retiring: ChatIdentity?, userId: UUID) throws {
    var ring = (try readRing(baseQuery(userId: userId))) ?? KeyRing(current: stored(current), retired: [])
    if let retiring {
      let item = stored(retiring)
      if ring.retired.contains(where: { key($0) == key(item) }) == false {
        ring.retired.append(item)
      }
    }
    ring.current = stored(current)
    let currentKey = key(ring.current)
    ring.retired.removeAll { key($0) == currentKey }
    if ring.retired.count > retiredLimit {
      ring.retired.removeFirst(ring.retired.count - retiredLimit)
    }
    try write(ring, userId: userId)
  }

  static func delete(userId: UUID) {
    SecItemDelete(baseQuery(userId: userId) as CFDictionary)
    SecItemDelete(legacyQuery() as CFDictionary)
  }

  static func load(userId: UUID) throws -> ChatIdentity? {
    guard let ring = try readRing(baseQuery(userId: userId)) else { return nil }
    return identity(ring.current)
  }

  private static func loadLegacy() throws -> ChatIdentity? {
    guard let ring = try readRing(legacyQuery()) else { return nil }
    return identity(ring.current)
  }

  private static func readRing(_ query: [String: Any]) throws -> KeyRing? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw ChatCryptoError.unreadable }
    if let ring = try? JSONDecoder().decode(KeyRing.self, from: data) { return ring }
    // A build that stored one key still opens. The next commit adds the retired list beside it.
    if let legacy = try? JSONDecoder().decode(StoredKey.self, from: data) {
      return KeyRing(current: legacy, retired: [])
    }
    return nil
  }

  private static func save(_ identity: ChatIdentity, userId: UUID) throws {
    try write(KeyRing(current: stored(identity), retired: []), userId: userId)
  }

  private static func write(_ ring: KeyRing, userId: UUID) throws {
    let data = try JSONEncoder().encode(ring)
    var add = baseQuery(userId: userId)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = SecItemUpdate(
        baseQuery(userId: userId) as CFDictionary,
        [
          kSecValueData as String: data,
          kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary
      )
      guard update == errSecSuccess else { throw ChatCryptoError.unreadable }
      return
    }
    guard status == errSecSuccess else { throw ChatCryptoError.unreadable }
  }

  private static func stored(_ identity: ChatIdentity) -> StoredKey {
    StoredKey(
      id: identity.id.uuidString,
      privateKey: ChatCoding.text(identity.privateKey.rawRepresentation),
      publicKey: ChatCoding.text(identity.publicKey)
    )
  }

  private static func identity(_ stored: StoredKey) -> ChatIdentity? {
    guard let raw = ChatCoding.data(stored.privateKey), let id = UUID(uuidString: stored.id) else { return nil }
    return try? ChatIdentity.restored(id: id, privateKey: raw)
  }

  private static func key(_ stored: StoredKey) -> String {
    if let publicKey = stored.publicKey, publicKey.isEmpty == false { return publicKey }
    return stored.id
  }

  private static func baseQuery(userId: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: userId.uuidString
    ]
  }

  private static func legacyQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: legacyAccount
    ]
  }
}

private struct StoredKey: Codable {
  var id: String
  var privateKey: String
  var publicKey: String?
}

private struct KeyRing: Codable {
  var current: StoredKey
  var retired: [StoredKey]
}
