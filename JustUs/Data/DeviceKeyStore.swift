import Foundation
import Security

enum DeviceKeyStore {
  private static let service = "com.orrgoren.justus.chat-key"
  /// The previous account was shared by every login on the phone, so two people got one key id.
  private static let legacyAccount = "device"

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

  static func delete(userId: UUID) {
    SecItemDelete(baseQuery(userId: userId) as CFDictionary)
    SecItemDelete(legacyQuery() as CFDictionary)
  }

  static func load(userId: UUID) throws -> ChatIdentity? {
    try read(baseQuery(userId: userId))
  }

  private static func loadLegacy() throws -> ChatIdentity? {
    try read(legacyQuery())
  }

  private static func read(_ query: [String: Any]) throws -> ChatIdentity? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw ChatCryptoError.unreadable }
    guard let stored = try? JSONDecoder().decode(StoredKey.self, from: data),
          let raw = ChatCoding.data(stored.privateKey),
          let id = UUID(uuidString: stored.id) else { return nil }
    return try ChatIdentity.restored(id: id, privateKey: raw)
  }

  private static func save(_ identity: ChatIdentity, userId: UUID) throws {
    let stored = StoredKey(id: identity.id.uuidString, privateKey: ChatCoding.text(identity.privateKey.rawRepresentation))
    let data = try JSONEncoder().encode(stored)
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
}
