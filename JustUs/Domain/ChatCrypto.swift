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

enum ChatCryptoError: Error {
  case unreadable
}

enum ChatText {
  static func normalized(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...2000).contains(text.count) else { return nil }
    return text
  }
}

enum ChatCrypto {
  private static let info = Data("justus-chat-v1".utf8)

  static func seal(text: String, from sender: ChatIdentity, to recipients: [(id: UUID, publicKey: Data)]) throws -> [ChatEnvelope] {
    try recipients.map { recipient in
      let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.publicKey)
      let secret = try sender.privateKey.sharedSecretFromKeyAgreement(with: publicKey)
      let key = secret.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32
      )
      let sealed = try ChaChaPoly.seal(Data(text.utf8), using: key)
      return ChatEnvelope(keyId: recipient.id, box: sealed.combined)
    }
  }

  static func open(envelopes: [ChatEnvelope], identity: ChatIdentity, senderPublic: Data) throws -> String {
    guard let mine = envelopes.first(where: { $0.keyId == identity.id }) else { throw ChatCryptoError.unreadable }
    let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPublic)
    let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: sender)
    let key = secret.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32
    )
    let box = try ChaChaPoly.SealedBox(combined: mine.box)
    let clear = try ChaChaPoly.open(box, using: key)
    guard let text = String(data: clear, encoding: .utf8) else { throw ChatCryptoError.unreadable }
    return text
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
