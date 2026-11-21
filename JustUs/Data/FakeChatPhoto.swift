import Foundation

extension FakeBackend {
  func presentChat(
    _ row: FakeChat, identity: ChatIdentity, userId: UUID, published: [(userId: UUID, publicKey: Data)]
  ) -> ChatLine {
    let photo = ChatPhoto.state(
      kind: row.kind, retention: row.retention, hasObject: row.objectBytes != nil && row.photoPath != nil,
      opened: row.openedAt != nil, expiresAt: row.expiresAt, now: clock()
    )
    let trusted = SenderKey.trusted(sender: row.senderPublicKey, senderUserId: row.senderUserId, keys: published)
    let envelopes = row.envelopes.map { ChatEnvelope(keyId: $0.keyId, box: $0.box) }
    let retired = retiredIdentities(userId: userId, current: identity.id)
    let text: String?
    if photo == nil && trusted {
      text = ChatHistory.open(
        envelopes: envelopes, current: identity, retired: retired, messageId: row.id,
        senderUserId: row.senderUserId, recipientUserId: userId, senderPublic: row.senderPublicKey
      )
    } else {
      text = nil
    }
    var preview: Data?
    if photo == .kept, trusted, let object = row.objectBytes {
      preview = try? ChatPhotoCipher.jpeg(
        object: object, envelopes: envelopes, current: identity, retired: retired,
        messageId: row.id, coupleId: row.coupleId, retention: .keep,
        senderUserId: row.senderUserId, recipientUserId: userId, senderPublic: row.senderPublicKey
      )
    }
    let shown = photo.map(ChatTranscript.label) ?? text ?? L10n.chatUnreadable
    return ChatLine(
      id: row.id, senderUserId: row.senderUserId, text: shown, createdAt: row.createdAt,
      mine: row.senderUserId == userId, unreadable: photo == nil && text == nil,
      photo: photo, previewJPEG: preview, photoPath: row.photoPath, notice: row.kind == "notice"
    )
  }

  func sweepExpiredChats(now: Date) {
    for index in store.world.chats.indices {
      let row = store.world.chats[index]
      guard row.kind == "photo", row.retention == ChatRetention.viewOnce.rawValue, row.openedAt == nil else { continue }
      guard ChatPhoto.expired(expiresAt: row.expiresAt, now: now) else { continue }
      guard objectCleared() else { continue }
      store.world.chats[index].objectBytes = nil
      store.world.chats[index].photoPath = nil
    }
  }

  func sendPhoto(_ jpeg: Data, retention: ChatRetention) async throws -> ChatLine {
    try guardOnline()
    guard ChatPhoto.fits(jpeg) else { throw AppError.chatPhotoTooBig }
    let prepared = try preparedSend()
    let messageId = UUID()
    let path = ChatPhoto.objectPath(coupleId: prepared.coupleId, messageId: messageId)
    let packed = try ChatPhotoCipher.package(
      jpeg: jpeg, messageId: messageId, coupleId: prepared.coupleId, retention: retention,
      senderUserId: prepared.userId, from: prepared.identity, to: prepared.targets
    )
    let row = FakeChat(
      id: messageId, coupleId: prepared.coupleId, senderUserId: prepared.userId,
      senderPublicKey: prepared.identity.publicKey, createdAt: clock(),
      envelopes: packed.envelopes.map { FakeEnvelope(keyId: $0.keyId, box: $0.box) },
      kind: "photo", retention: retention.rawValue, objectBytes: packed.object,
      openedAt: nil, expiresAt: retention == .viewOnce ? clock().addingTimeInterval(ChatPhoto.lifetime) : nil,
      photoPath: path
    )
    store.world.chats.append(row)
    store.save()
    let published = store.world.deviceKeys.filter { member($0.userId)?.coupleId == prepared.coupleId }
      .map { (userId: $0.userId, publicKey: $0.publicKey) }
    var line = presentChat(row, identity: prepared.identity, userId: prepared.userId, published: published)
    line.delivery = .sent
    if line.photo == .kept { line.previewJPEG = jpeg }
    return line
  }

  func chatPhoto(_ id: UUID) async throws -> Data {
    guard let user = current(), let mine = member(user.id) else { throw AppError.notAuthenticated }
    guard let row = store.world.chats.first(where: { $0.id == id && $0.coupleId == mine.coupleId }),
          row.kind == "photo", let object = row.objectBytes, row.photoPath != nil else { throw AppError.notEditable }
    if row.retention == ChatRetention.viewOnce.rawValue && ChatPhoto.expired(expiresAt: row.expiresAt, now: clock()) {
      throw AppError.notEditable
    }
    let identity = try ensureKey(userId: user.id, reason: .refresh)
    let envelopes = row.envelopes.map { ChatEnvelope(keyId: $0.keyId, box: $0.box) }
    guard let retention = ChatRetention(rawValue: row.retention ?? "") else { throw AppError.notEditable }
    return try ChatPhotoCipher.jpeg(
      object: object, envelopes: envelopes, current: identity,
      retired: retiredIdentities(userId: user.id, current: identity.id),
      messageId: row.id, coupleId: row.coupleId, retention: retention,
      senderUserId: row.senderUserId, recipientUserId: user.id, senderPublic: row.senderPublicKey
    )
  }

  func consumeViewOnce(_ id: UUID) async throws {
    await pauseConsumeIfNeeded()
    guard let user = current(), let mine = member(user.id),
          let index = store.world.chats.firstIndex(where: { $0.id == id && $0.coupleId == mine.coupleId }) else {
      throw AppError.notEditable
    }
    let row = store.world.chats[index]
    guard row.kind == "photo", row.retention == ChatRetention.viewOnce.rawValue else { throw AppError.notEditable }
    if row.openedAt != nil || row.objectBytes == nil { return }
    if row.senderUserId == user.id { throw AppError.notEditable }
    if ChatPhoto.expired(expiresAt: row.expiresAt, now: clock()) { throw AppError.notEditable }
    guard objectCleared() else { throw AppError.saveFailed }
    store.world.chats[index].objectBytes = nil
    store.world.chats[index].photoPath = nil
    store.world.chats[index].openedAt = clock()
    store.save()
  }

  func deleteChatPhoto(_ id: UUID) async throws {
    guard let user = current(), let mine = member(user.id) else { throw AppError.notAuthenticated }
    guard let row = store.world.chats.first(where: { $0.id == id && $0.coupleId == mine.coupleId }), row.kind == "photo" else {
      throw AppError.notEditable
    }
    if row.photoPath != nil || row.objectBytes != nil {
      guard objectCleared() else { throw AppError.saveFailed }
    }
    _ = user
    store.world.chats.removeAll { $0.id == id }
    store.save()
  }

  func sendScreenshotNotice(for photoId: UUID) async throws -> ChatLine? {
    try guardOnline()
    let now = clock()
    let previous = recentShots[photoId].map { (photoId, $0) }
    guard ScreenshotDedup.allow(messageId: photoId, now: now, previous: previous) else { return nil }
    recentShots[photoId] = now
    let prepared = try preparedSend()
    let name = display(prepared.userId)
    let text = ChatNotice.screenshot(name.isEmpty ? "They" : name)
    let messageId = UUID()
    let envelopes = try ChatCrypto.seal(
      text: text, messageId: messageId, senderUserId: prepared.userId, from: prepared.identity, to: prepared.targets
    )
    store.world.chats.append(FakeChat(
      id: messageId, coupleId: prepared.coupleId, senderUserId: prepared.userId,
      senderPublicKey: prepared.identity.publicKey, createdAt: now,
      envelopes: envelopes.map { FakeEnvelope(keyId: $0.keyId, box: $0.box) },
      kind: "notice"
    ))
    store.save()
    return ChatLine(
      id: messageId, senderUserId: prepared.userId, text: text, createdAt: now,
      mine: true, unreadable: false, notice: true, delivery: .sent
    )
  }

  func seedChatPhotoPreview() {
    guard let alex = member(SeedID.alex) else { return }
    let jpeg = PhotoBytes.sample()
    let when = clock()
    if let blair = try? ensureKey(userId: SeedID.blair),
       let packed = try? sealedPhoto(jpeg, sender: SeedID.blair, key: blair, couple: alex.coupleId, retention: .viewOnce) {
      store.world.chats.append(FakeChat(
        id: packed.id, coupleId: alex.coupleId, senderUserId: SeedID.blair, senderPublicKey: blair.publicKey,
        createdAt: when.addingTimeInterval(-30), envelopes: packed.envelopes, kind: "photo",
        retention: ChatRetention.viewOnce.rawValue, objectBytes: packed.object, openedAt: nil,
        expiresAt: when.addingTimeInterval(ChatPhoto.lifetime), photoPath: packed.path
      ))
    }
    if let alexKey = try? ensureKey(userId: SeedID.alex),
       let packed = try? sealedPhoto(jpeg, sender: SeedID.alex, key: alexKey, couple: alex.coupleId, retention: .keep) {
      store.world.chats.append(FakeChat(
        id: packed.id, coupleId: alex.coupleId, senderUserId: SeedID.alex, senderPublicKey: alexKey.publicKey,
        createdAt: when.addingTimeInterval(-20), envelopes: packed.envelopes, kind: "photo",
        retention: ChatRetention.keep.rawValue, objectBytes: packed.object, openedAt: nil,
        expiresAt: nil, photoPath: packed.path
      ))
    }
    store.world.chats.append(FakeChat(
      id: UUID(), coupleId: alex.coupleId, senderUserId: SeedID.blair, senderPublicKey: Data(repeating: 1, count: 32),
      createdAt: when.addingTimeInterval(-10), envelopes: [], kind: "photo",
      retention: ChatRetention.viewOnce.rawValue, objectBytes: nil, openedAt: when, expiresAt: when, photoPath: nil
    ))
    if let blair = try? ensureKey(userId: SeedID.blair) {
      let messageId = UUID()
      let keys = store.world.deviceKeys.filter { member($0.userId)?.coupleId == alex.coupleId }
      let targets = ChatRecipients.choose(
        senderUserId: SeedID.blair, senderKeyId: blair.id,
        keys: keys.map { (id: $0.id, userId: $0.userId, publicKey: $0.publicKey, createdAt: $0.createdAt, retired: $0.retiredAt != nil) }
      )
      if let envelopes = try? ChatCrypto.seal(
        text: ChatNotice.screenshot("Blair"), messageId: messageId, senderUserId: SeedID.blair, from: blair, to: targets
      ) {
        store.world.chats.append(FakeChat(
          id: messageId, coupleId: alex.coupleId, senderUserId: SeedID.blair, senderPublicKey: blair.publicKey,
          createdAt: when, envelopes: envelopes.map { FakeEnvelope(keyId: $0.keyId, box: $0.box) }, kind: "notice"
        ))
      }
    }
    store.save()
  }

  private struct PreparedSend {
    var userId: UUID
    var coupleId: UUID
    var identity: ChatIdentity
    var targets: [ChatTarget]
  }

  private func preparedSend() throws -> PreparedSend {
    guard let user = current(), let mine = member(user.id) else { throw AppError.saveFailed }
    let partner = store.world.members.contains { $0.coupleId == mine.coupleId && $0.userId != user.id }
    guard partner else { throw AppError.partnerNotReady }
    let identity = try ensureKey(userId: user.id, reason: .send)
    let keys = store.world.deviceKeys.filter { member($0.userId)?.coupleId == mine.coupleId }
    let targets = ChatRecipients.choose(
      senderUserId: user.id, senderKeyId: identity.id,
      keys: keys.map { (id: $0.id, userId: $0.userId, publicKey: $0.publicKey, createdAt: $0.createdAt, retired: $0.retiredAt != nil) }
    )
    guard targets.contains(where: { $0.userId != user.id }) else { throw AppError.partnerNotReady }
    return PreparedSend(userId: user.id, coupleId: mine.coupleId, identity: identity, targets: targets)
  }

  private func objectCleared() -> Bool {
    ChatStorageRemoval.clearsPath(photoRemoveError)
  }

  private func sealedPhoto(
    _ jpeg: Data, sender: UUID, key: ChatIdentity, couple: UUID, retention: ChatRetention
  ) throws -> (id: UUID, path: String, envelopes: [FakeEnvelope], object: Data) {
    let keys = store.world.deviceKeys.filter { member($0.userId)?.coupleId == couple }
    let targets = ChatRecipients.choose(
      senderUserId: sender, senderKeyId: key.id,
      keys: keys.map { (id: $0.id, userId: $0.userId, publicKey: $0.publicKey, createdAt: $0.createdAt, retired: $0.retiredAt != nil) }
    )
    let messageId = UUID()
    let packed = try ChatPhotoCipher.package(
      jpeg: jpeg, messageId: messageId, coupleId: couple, retention: retention, senderUserId: sender, from: key, to: targets
    )
    return (
      messageId,
      ChatPhoto.objectPath(coupleId: couple, messageId: messageId),
      packed.envelopes.map { FakeEnvelope(keyId: $0.keyId, box: $0.box) },
      packed.object
    )
  }
}
