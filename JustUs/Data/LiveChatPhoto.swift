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

  func sendPhoto(_ jpeg: Data, retention: ChatRetention, id: UUID) async throws -> ChatLine {
    try await writePhoto(jpeg, retention: retention, id: id, allowRefresh: true)
  }

  private func writePhoto(
    _ jpeg: Data, retention: ChatRetention, id: UUID, allowRefresh: Bool
  ) async throws -> ChatLine {
    guard ChatPhoto.fits(jpeg) else { throw AppError.chatPhotoTooBig }
    let prepared = try await preparedSend()
    let path = ChatPhoto.objectPath(coupleId: prepared.context.couple.id, messageId: id)
    let packed = try ChatPhotoCipher.package(
      jpeg: jpeg, messageId: id, coupleId: prepared.context.couple.id, retention: retention,
      senderUserId: prepared.context.userId, from: prepared.identity, to: prepared.targets
    )
    var uploaded = false
    do {
      try await uploadPhoto(path, object: packed.object)
      uploaded = true
      try await insertPhoto(id: id, prepared: prepared, retention: retention, path: path, envelopes: packed.envelopes)
    } catch {
      if ChatInsertGate.alreadyStored(error) {
        nudgeChat()
        return sentPhotoLine(id: id, prepared: prepared, retention: retention, path: path, jpeg: jpeg)
      }
      if allowRefresh, ChatSendRecovery.refreshKeys(error) {
        chatMaterials = nil
        _ = await removedChatObjects([path])
        return try await writePhoto(jpeg, retention: retention, id: id, allowRefresh: false)
      }
      if uploaded {
        _ = await removedChatObjects([path])
      }
      throw ErrorMap.app(error)
    }
    nudgeChat()
    return sentPhotoLine(id: id, prepared: prepared, retention: retention, path: path, jpeg: jpeg)
  }

  private func uploadPhoto(_ path: String, object: Data) async throws {
    do {
      try await run { client in
        try await client.storage.from("chat-photos").upload(
          path, data: object, options: FileOptions(contentType: "application/octet-stream", upsert: false)
        )
      }
    } catch {
      guard ChatInsertGate.alreadyStored(error) else { throw error }
    }
  }

  private func insertPhoto(
    id: UUID, prepared: PreparedSend, retention: ChatRetention, path: String, envelopes: [ChatEnvelope]
  ) async throws {
    let row = ChatPhotoInsert(
      id: id, coupleId: prepared.context.couple.id, senderUserId: prepared.context.userId,
      senderPublicKey: ChatCoding.text(prepared.identity.publicKey),
      envelopes: envelopes.map { EnvelopeWire(keyId: $0.keyId, box: ChatCoding.text($0.box)) },
      kind: "photo", retention: retention.rawValue, photoPath: path
    )
    try await run { client in
      try await client.from("chat_messages").insert(row).execute()
    }
  }

  private func sentPhotoLine(
    id: UUID, prepared: PreparedSend, retention: ChatRetention, path: String, jpeg: Data
  ) -> ChatLine {
    let expires = retention == .viewOnce ? Date().addingTimeInterval(ChatPhoto.lifetime) : nil
    let photo = ChatPhoto.state(
      kind: "photo", retention: retention.rawValue, hasObject: true, opened: false, expiresAt: expires, now: Date()
    )
    return ChatLine(
      id: id, senderUserId: prepared.context.userId, text: photo.map(ChatTranscript.label) ?? L10n.chatPhotoTap,
      createdAt: Date(), mine: true, unreadable: false, photo: photo,
      previewJPEG: photo == .kept ? jpeg : nil, photoPath: path, delivery: .sent
    )
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
    try await run { client in
      try await client.rpc("consume_chat_photo", params: MessageIDParams(pMessageId: id)).execute()
    }
    guard let path = row.photoPath else { return }
    guard await removedChatObjects([path]) else { throw AppError.saveFailed }
    try await run { client in
      try await client.rpc("clear_chat_photo_path", params: MessageIDParams(pMessageId: id)).execute()
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

  func sendScreenshotNotice(for photoId: UUID) async throws -> ChatLine? {
    let now = Date()
    let previous = recentShots[photoId].map { (photoId, $0) }
    guard ScreenshotDedup.allow(messageId: photoId, now: now, previous: previous) else { return nil }
    recentShots[photoId] = now
    do {
      let prepared = try await preparedSend()
      let rawName = prepared.context.mine.displayName
      let text = ChatNotice.screenshot(rawName.isEmpty ? "They" : rawName)
      let id = try await insertText(text, kind: "notice", prepared: prepared, noticeMessageId: photoId)
      nudgeChat()
      return ChatLine(
        id: id, senderUserId: prepared.context.userId, text: text, createdAt: now,
        mine: true, unreadable: false, notice: true, delivery: .sent
      )
    } catch {
      if ChatInsertGate.alreadyStored(error) { return nil }
      recentShots[photoId] = nil
      throw error
    }
  }

  struct PreparedSend {
    var context: LiveContext
    var identity: ChatIdentity
    var targets: [ChatTarget]
  }

  func preparedSend() async throws -> PreparedSend {
    if let cached = cachedPreparedSend() {
      if await keyRingCurrent() { return cached }
      chatMaterials = nil
    }
    guard let context = try await loadContext() else { throw AppError.saveFailed }
    guard context.members.contains(where: { $0.userId != context.userId }) else { throw AppError.partnerNotReady }
    let identity = try await publishDeviceKey(userId: context.userId, reason: .send)
    let keys = try await loadDeviceKeys(coupleId: context.couple.id)
    let targets = chatTargets(keys: keys.filter { $0.retiredAt == nil }, userId: context.userId, identity: identity)
    guard targets.contains(where: { $0.userId != context.userId }) else { throw AppError.partnerNotReady }
    chatMaterials = ChatMaterials(context: context, identity: identity, keys: keys)
    return PreparedSend(context: context, identity: identity, targets: targets)
  }

  private func keyRingCurrent() async -> Bool {
    guard let materials = chatMaterials else { return false }
    let memberIds = materials.context.members.map(\.userId.uuidString)
    guard memberIds.isEmpty == false else { return false }
    do {
      let rows: [DeviceKeyStamp] = try await run { client in
        let response: PostgrestResponse<[DeviceKeyStamp]> = try await client
          .from("device_keys")
          .select("id, retired_at")
          .in("user_id", values: memberIds.map { $0 as any PostgrestFilterValue })
          .execute()
        return response.value
      }
      let fresh = Set(rows.compactMap { $0.retiredAt == nil ? $0.id : nil })
      let cached = Set(materials.keys.compactMap { $0.retiredAt == nil ? $0.id : nil })
      return ChatKeyRing.matches(cached: cached, fresh: fresh)
    } catch {
      return false
    }
  }

  private func cachedPreparedSend() -> PreparedSend? {
    guard let materials = chatMaterials else { return nil }
    let targets = chatTargets(
      keys: materials.keys.filter { $0.retiredAt == nil }, userId: materials.context.userId, identity: materials.identity
    )
    guard targets.contains(where: { $0.userId != materials.context.userId }) else {
      chatMaterials = nil
      return nil
    }
    return PreparedSend(context: materials.context, identity: materials.identity, targets: targets)
  }

  @discardableResult
  private func insertText(
    _ text: String, kind: String, prepared: PreparedSend, noticeMessageId: UUID? = nil
  ) async throws -> UUID {
    let messageId = UUID()
    let envelopes = try ChatCrypto.seal(
      text: text, messageId: messageId, senderUserId: prepared.context.userId, from: prepared.identity, to: prepared.targets
    )
    let row = ChatPhotoInsert(
      id: messageId, coupleId: prepared.context.couple.id, senderUserId: prepared.context.userId,
      senderPublicKey: ChatCoding.text(prepared.identity.publicKey),
      envelopes: envelopes.map { EnvelopeWire(keyId: $0.keyId, box: ChatCoding.text($0.box)) },
      kind: kind, retention: nil, photoPath: nil, noticeMessageId: noticeMessageId
    )
    try await run { client in
      try await client.from("chat_messages").insert(row).execute()
    }
    return messageId
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
