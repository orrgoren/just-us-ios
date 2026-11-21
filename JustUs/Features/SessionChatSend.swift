import Foundation

struct PendingPhoto: Equatable {
  var jpeg: Data
  var retention: ChatRetention
}

extension SessionModel {
  func sendStagedPhoto() async {
    guard photoSending == false, let jpeg = stagedChatJPEG else { return }
    photoSending = true
    defer { photoSending = false }
    let id = UUID()
    let retention = chatRetention
    pendingPhotos[id] = PendingPhoto(jpeg: jpeg, retention: retention)
    messages.append(outgoingPhoto(id: id, jpeg: jpeg, retention: retention))
    stagedChatJPEG = nil
    errorMessage = nil
    retryKind = nil
    await finishPhoto(id: id)
  }

  func finishPhoto(id: UUID) async {
    guard let pending = pendingPhotos[id] else { return }
    do {
      let saved = try await backend.sendPhoto(pending.jpeg, retention: pending.retention, id: id)
      pendingPhotos[id] = nil
      messages = ChatThread.merge(messages, saved)
      errorMessage = nil
      retryKind = nil
    } catch {
      failPhoto(id: id, pending: pending, error: error)
    }
  }

  private func failPhoto(id: UUID, pending: PendingPhoto, error: Error) {
    guard messages.first(where: { $0.id == id })?.delivery != .sent else {
      pendingPhotos[id] = nil
      return
    }
    let mapped = ErrorMap.app(error)
    if keepsFailedBubble(mapped) {
      setDelivery(id, .failed)
    } else {
      messages.removeAll { $0.id == id }
      pendingPhotos[id] = nil
      if stagedChatJPEG == nil {
        stagedChatJPEG = pending.jpeg
        chatRetention = pending.retention
      }
    }
    noteChatFailure(error)
  }

  private func outgoingPhoto(id: UUID, jpeg: Data, retention: ChatRetention) -> ChatLine {
    let photo: ChatPhotoState = retention == .viewOnce ? .viewOnce : .kept
    return ChatLine(
      id: id, senderUserId: ritual?.selfMember.userId ?? UUID(), text: ChatTranscript.label(photo),
      createdAt: Date(), mine: true, unreadable: false, photo: photo,
      previewJPEG: photo == .kept ? jpeg : nil, delivery: .sending
    )
  }
}
