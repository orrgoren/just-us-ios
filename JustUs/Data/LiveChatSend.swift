import Foundation
import Supabase

struct ChatMaterials {
  var context: LiveContext
  var identity: ChatIdentity
  var keys: [DeviceKeyRow]
}

extension LiveBackend {
  func invalidateChatCache() {
    chatMaterials = nil
  }

  func nudgeChat() {
    Task { await self.notify("chatMessage") }
  }

  func incomingLine(_ row: ChatMessageRow) async -> ChatLine? {
    let prepared: PreparedSend
    do {
      prepared = try await preparedSend()
    } catch {
      return nil
    }
    let keys = chatMaterials?.keys ?? []
    let line = chatLine(
      row, identity: prepared.identity, retired: DeviceKeyStore.retired(userId: prepared.context.userId),
      userId: prepared.context.userId, keys: keys
    )
    return line.unreadable ? nil : line
  }

  func deliverChat(_ action: AnyAction) {
    switch action {
    case .insert(let insert):
      if let row = try? insert.decodeRecord(as: ChatMessageRow.self, decoder: JSONDecoder()) {
        onChatInsert?(row)
        return
      }
      reloadChat(.undecodable)
    case .update(let update):
      if let row = try? update.decodeRecord(as: ChatMessageRow.self, decoder: JSONDecoder()) {
        onChatInsert?(row)
        return
      }
      if let id = openedPhotoId(update.record) {
        onChatOpened?(id)
        return
      }
      reloadChat(.undecodable)
    case .delete:
      reloadChat(.delete)
    }
  }

  /// A photo update may arrive as the whole row or as just the opened columns.
  func openedPhotoId(_ record: [String: AnyJSON]) -> UUID? {
    guard let raw = record["id"]?.stringValue, let id = UUID(uuidString: raw) else { return nil }
    if let opened = record["opened_at"]?.stringValue, opened.isEmpty == false { return id }
    if let path = record["photo_path"], path.stringValue == nil { return id }
    return nil
  }

  func reloadChat(_ event: ChatSocket.Event) {
    guard ChatSocket.step(event) == .reload else { return }
    onChatReload?()
  }

  func writeMessage(_ text: String, id: UUID, allowRefresh: Bool) async throws -> ChatLine {
    do {
      return try await insertMessage(text, id: id)
    } catch {
      guard allowRefresh, ChatSendRecovery.refreshKeys(error) else { throw error }
      chatMaterials = nil
      return try await insertMessage(text, id: id)
    }
  }

  private func insertMessage(_ text: String, id: UUID) async throws -> ChatLine {
    let clear = try ChatText.normalized(text)
    let prepared = try await preparedSend()
    let envelopes = try ChatCrypto.seal(
      text: clear, messageId: id, senderUserId: prepared.context.userId, from: prepared.identity, to: prepared.targets
    )
    guard envelopes.contains(where: { $0.keyId != prepared.identity.id }) else { throw AppError.partnerNotReady }
    let row = ChatInsert(
      id: id, coupleId: prepared.context.couple.id, senderUserId: prepared.context.userId,
      senderPublicKey: ChatCoding.text(prepared.identity.publicKey),
      envelopes: envelopes.map { EnvelopeWire(keyId: $0.keyId, box: ChatCoding.text($0.box)) }
    )
    try await run { client in
      try await client.from("chat_messages").insert(row).execute()
    }
    nudgeChat()
    return ChatLine(
      id: id, senderUserId: prepared.context.userId, text: clear, createdAt: Date(),
      mine: true, unreadable: false, delivery: .sent
    )
  }
}
