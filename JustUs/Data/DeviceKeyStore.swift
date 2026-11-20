import Foundation
import Security

/// The bytes behind one device-key account. Live uses the Keychain. Tests pass an in-memory box,
/// because the CI simulator host has no usable Keychain and the ring would never run there.
protocol DeviceKeychain: Sendable {
  func load(account: String) throws -> Data?
  func save(account: String, data: Data) throws
  func remove(account: String)
}

enum DeviceKeyStore {
  private static let service = "com.orrgoren.justus.chat-key"
  /// The previous account was shared by every login on the phone, so two people got one key id.
  private static let legacyAccount = "device"
  /// A phone that rotated on every refresh used to fill the keychain. Keep the recent ones.
  private static let retiredLimit = 40

  struct LiveKeychain: DeviceKeychain {
    func load(account: String) throws -> Data? {
      var lookup = query(account)
      lookup[kSecReturnData as String] = true
      lookup[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(lookup as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data else { throw ChatCryptoError.unreadable }
      return data
    }

    func save(account: String, data: Data) throws {
      var add = query(account)
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(add as CFDictionary, nil)
      if status == errSecDuplicateItem {
        let update = SecItemUpdate(
          query(account) as CFDictionary,
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

    func remove(account: String) {
      SecItemDelete(query(account) as CFDictionary)
    }

    private func query(_ account: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: DeviceKeyStore.service,
        kSecAttrAccount as String: account
      ]
    }
  }

  static func loadOrCreate(userId: UUID, keychain: any DeviceKeychain = LiveKeychain()) throws -> ChatIdentity {
    if let existing = try load(userId: userId, keychain: keychain) {
      keychain.remove(account: legacyAccount)
      return existing
    }
    // One shared item used to serve every login. Keep it for this account, then drop it
    // so the next person on the phone does not publish the same key id.
    if let legacy = try loadLegacy(keychain: keychain) {
      try save(legacy, userId: userId, keychain: keychain)
      keychain.remove(account: legacyAccount)
      return legacy
    }
    let created = ChatIdentity.generate()
    try save(created, userId: userId, keychain: keychain)
    return created
  }

  /// Private keys this phone used before the current one, keyed by their public key.
  static func retired(userId: UUID, keychain: any DeviceKeychain = LiveKeychain()) -> [ChatIdentity] {
    guard let ring = try? readRing(account: userId.uuidString, keychain: keychain) else { return [] }
    return ring.retired.compactMap(identity)
  }

  /// Stores `current` and keeps `retiring` so older envelopes still open. Call this only after the server insert succeeds.
  static func commit(
    current: ChatIdentity,
    retiring: ChatIdentity?,
    userId: UUID,
    keychain: any DeviceKeychain = LiveKeychain()
  ) throws {
    var ring = (try readRing(account: userId.uuidString, keychain: keychain)) ?? KeyRing(current: stored(current), retired: [])
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
    try write(ring, userId: userId, keychain: keychain)
  }

  static func delete(userId: UUID, keychain: any DeviceKeychain = LiveKeychain()) {
    keychain.remove(account: userId.uuidString)
    keychain.remove(account: legacyAccount)
  }

  static func load(userId: UUID, keychain: any DeviceKeychain = LiveKeychain()) throws -> ChatIdentity? {
    guard let ring = try readRing(account: userId.uuidString, keychain: keychain) else { return nil }
    return identity(ring.current)
  }

  private static func loadLegacy(keychain: any DeviceKeychain) throws -> ChatIdentity? {
    guard let ring = try readRing(account: legacyAccount, keychain: keychain) else { return nil }
    return identity(ring.current)
  }

  private static func readRing(account: String, keychain: any DeviceKeychain) throws -> KeyRing? {
    guard let data = try keychain.load(account: account) else { return nil }
    if let ring = try? JSONDecoder().decode(KeyRing.self, from: data) { return ring }
    // A build that stored one key still opens. The next commit adds the retired list beside it.
    if let legacy = try? JSONDecoder().decode(StoredKey.self, from: data) {
      return KeyRing(current: legacy, retired: [])
    }
    return nil
  }

  private static func save(_ identity: ChatIdentity, userId: UUID, keychain: any DeviceKeychain) throws {
    try write(KeyRing(current: stored(identity), retired: []), userId: userId, keychain: keychain)
  }

  private static func write(_ ring: KeyRing, userId: UUID, keychain: any DeviceKeychain) throws {
    try keychain.save(account: userId.uuidString, data: JSONEncoder().encode(ring))
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
