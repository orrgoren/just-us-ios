import Foundation
import Supabase

extension LiveBackend {
  func chatLine(
    _ row: ChatMessageRow, identity: ChatIdentity, retired: [ChatIdentity], userId: UUID, keys: [DeviceKeyRow]
  ) -> ChatLine {
    let expires = APIDate.parse(row.expiresAt)
    let photo = ChatPhoto.state(
      kind: row.kind, retention: row.retention, hasObject: row.photoPath != nil,
      opened: row.openedAt != nil, expiresAt: expires, now: Date()
    )
    let text = photo == nil ? decrypted(row, identity: identity, retired: retired, userId: userId, keys: keys) : nil
    let shown = photo.map(ChatTranscript.label) ?? text ?? L10n.chatUnreadable
    return ChatLine(
      id: row.id, senderUserId: row.senderUserId, text: shown,
      createdAt: APIDate.parse(row.createdAt) ?? Date(), mine: row.senderUserId == userId,
      unreadable: photo == nil && text == nil, photo: photo, previewJPEG: nil, photoPath: row.photoPath,
      notice: row.kind == "notice"
    )
  }

  func sweepChatPhotos() async {
    guard let context = try? await loadContext() else { return }
    let rows = (try? await chatRows(coupleId: context.couple.id)) ?? []
    let now = Date()
    let paths = rows.compactMap { row -> String? in
      guard row.kind == "photo", row.retention == ChatRetention.viewOnce.rawValue, row.openedAt == nil else { return nil }
      guard ChatPhoto.expired(expiresAt: APIDate.parse(row.expiresAt), now: now) else { return nil }
      return row.photoPath
    }
    guard paths.isEmpty == false, await removedChatObjects(paths) else { return }
    _ = try? await run { client in
      try await client.rpc("expire_chat_photos").execute()
    }
  }

  func sendPhoto(_ jpeg: Data, retention: ChatRetention) async throws {
    guard ChatPhoto.fits(jpeg) else { throw AppError.chatPhotoTooBig }
    let prepared = try await preparedSend()
    let messageId = UUID()
    let path = ChatPhoto.objectPath(coupleId: prepared.context.couple.id, messageId: messageId)
    let packed = try ChatPhotoCipher.package(
      jpeg: jpeg, messageId: messageId, coupleId: prepared.context.couple.id, retention: retention,
      senderUserId: prepared.context.userId, from: prepared.identity, to: prepared.targets
    )
    var uploaded = false
    do {
      try await run { client in
        try await client.storage.from("chat-photos").upload(
          path, data: packed.object, options: FileOptions(contentType: "application/octet-stream", upsert: false)
        )
      }
      uploaded = true
      let row = ChatPhotoInsert(
        id: messageId, coupleId: prepared.context.couple.id, senderUserId: prepared.context.userId,
        senderPublicKey: ChatCoding.text(prepared.identity.publicKey),
        envelopes: packed.envelopes.map { EnvelopeWire(keyId: $0.keyId, box: ChatCoding.text($0.box)) },
        kind: "photo", retention: retention.rawValue, photoPath: path
      )
      try await run { client in
        try await client.from("chat_messages").insert(row).execute()
      }
    } catch {
      if uploaded {
        _ = try? await run { client in
          try await client.storage.from("chat-photos").remove(paths: [path])
        }
      }
      throw ErrorMap.app(error)
    }
    await notify("chatMessage")
  }

  func chatPhoto(_ id: UUID) async throws -> Data {
    let prepared = try await preparedSend()
    guard let row = try await chatRows(coupleId: prepared.context.couple.id).first(where: { $0.id == id }),
          row.kind == "photo", let path = row.photoPath else { throw AppError.notEditable }
    if row.retention == ChatRetention.viewOnce.rawValue && ChatPhoto.expired(expiresAt: APIDate.parse(row.expiresAt), now: Date()) {
      throw AppError.notEditable
    }
    let object = try await run { client in
      try await client.storage.from("chat-photos").download(path: path)
    }
    let keys = try await loadDeviceKeys(coupleId: prepared.context.couple.id, senderKeys: [row.senderPublicKey])
    return try openPhoto(
      row, object: object, identity: prepared.identity, userId: prepared.context.userId,
      keys: keys, coupleId: prepared.context.couple.id
    )
  }

  func consumeViewOnce(_ id: UUID) async throws {
    guard let context = try await loadContext() else { throw AppError.notAuthenticated }
    guard let row = try await chatRows(coupleId: context.couple.id).first(where: { $0.id == id }) else {
      throw AppError.notEditable
    }
    if let path = row.photoPath, await removedChatObjects([path]) == false {
      throw AppError.saveFailed
    }
    try await run { client in
      try await client.rpc("consume_chat_photo", params: MessageIDParams(pMessageId: id)).execute()
    }
  }

  func deleteChatPhoto(_ id: UUID) async throws {
    guard let context = try await loadContext() else { throw AppError.notAuthenticated }
    if let row = try await chatRows(coupleId: context.couple.id).first(where: { $0.id == id }),
       let path = row.photoPath, await removedChatObjects([path]) == false {
      throw AppError.saveFailed
    }
    try await run { client in
      try await client.from("chat_messages").delete().eq("id", value: id.uuidString).execute()
    }
  }

  func sendScreenshotNotice() async throws {
    let prepared = try await preparedSend()
    let name = prepared.context.mine.displayName.isEmpty ? "They" : prepared.context.mine.displayName
    try await insertText(ChatNotice.screenshot(name), kind: "notice", prepared: prepared)
  }

  private struct PreparedSend {
    var context: LiveContext
    var identity: ChatIdentity
    var targets: [ChatTarget]
  }

  private func preparedSend() async throws -> PreparedSend {
    guard let context = try await loadContext() else { throw AppError.saveFailed }
    guard context.members.contains(where: { $0.userId != context.userId }) else { throw AppError.partnerNotReady }
    let identity = try await publishDeviceKey(userId: context.userId, reason: .send)
    let keys = try await loadDeviceKeys(coupleId: context.couple.id)
    let targets = chatTargets(keys: keys.filter { $0.retiredAt == nil }, userId: context.userId, identity: identity)
    guard targets.contains(where: { $0.userId != context.userId }) else { throw AppError.partnerNotReady }
    return PreparedSend(context: context, identity: identity, targets: targets)
  }

  private func insertText(_ text: String, kind: String, prepared: PreparedSend) async throws {
    let messageId = UUID()
    let envelopes = try ChatCrypto.seal(
      text: text, messageId: messageId, senderUserId: prepared.context.userId, from: prepared.identity, to: prepared.targets
    )
    let row = ChatPhotoInsert(
      id: messageId, coupleId: prepared.context.couple.id, senderUserId: prepared.context.userId,
      senderPublicKey: ChatCoding.text(prepared.identity.publicKey),
      envelopes: envelopes.map { EnvelopeWire(keyId: $0.keyId, box: ChatCoding.text($0.box)) },
      kind: kind, retention: nil, photoPath: nil
    )
    try await run { client in
      try await client.from("chat_messages").insert(row).execute()
    }
  }

  private func removedChatObjects(_ paths: [String]) async -> Bool {
    do {
      try await run { client in
        try await client.storage.from("chat-photos").remove(paths: paths)
      }
      return true
    } catch {
      return ChatStorageRemoval.clearsPath(error)
    }
  }

  private func openPhoto(
    _ row: ChatMessageRow, object: Data, identity: ChatIdentity, userId: UUID, keys: [DeviceKeyRow], coupleId: UUID
  ) throws -> Data {
    let published = keys.compactMap { key -> (userId: UUID, publicKey: Data)? in
      guard let raw = ChatCoding.data(key.publicKey) else { return nil }
      return (key.userId, raw)
    }
    guard let sender = ChatCoding.data(row.senderPublicKey),
          SenderKey.trusted(sender: sender, senderUserId: row.senderUserId, keys: published) else {
      throw ChatCryptoError.unreadable
    }
    let envelopes = row.envelopes.compactMap { wire -> ChatEnvelope? in
      guard let box = ChatCoding.data(wire.box) else { return nil }
      return ChatEnvelope(keyId: wire.keyId, box: box)
    }
    let retired = DeviceKeyStore.retired(userId: userId)
    guard let retention = ChatRetention(rawValue: row.retention ?? "") else { throw ChatCryptoError.unreadable }
    return try ChatPhotoCipher.jpeg(
      object: object, envelopes: envelopes, current: identity, retired: retired,
      messageId: row.id, coupleId: coupleId, retention: retention,
      senderUserId: row.senderUserId, recipientUserId: userId, senderPublic: sender
    )
  }
}

private struct MessageIDParams: Encodable {
  var pMessageId: UUID
  enum CodingKeys: String, CodingKey { case pMessageId = "p_message_id" }
}
