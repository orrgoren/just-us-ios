import Foundation
import Security

enum DeviceKeyStore {
  private static let service = "com.orrgoren.justus.chat-key"
  private static let account = "device"

  static func loadOrCreate() throws -> ChatIdentity {
    if let existing = try load() { return existing }
    let created = ChatIdentity.generate()
    try save(created)
    return created
  }

  static func load() throws -> ChatIdentity? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw ChatCryptoError.unreadable }
    guard let stored = try? JSONDecoder().decode(StoredKey.self, from: data),
          let raw = ChatCoding.data(stored.privateKey),
          let id = UUID(uuidString: stored.id) else { return nil }
    return try ChatIdentity.restored(id: id, privateKey: raw)
  }

  private static func save(_ identity: ChatIdentity) throws {
    let stored = StoredKey(id: identity.id.uuidString, privateKey: ChatCoding.text(identity.privateKey.rawRepresentation))
    let data = try JSONEncoder().encode(stored)
    let status = SecItemAdd(baseQuery().merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard update == errSecSuccess else { throw ChatCryptoError.unreadable }
      return
    }
    guard status == errSecSuccess else { throw ChatCryptoError.unreadable }
  }

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
}

private struct StoredKey: Codable {
  var id: String
  var privateKey: String
}
