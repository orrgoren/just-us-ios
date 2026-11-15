import Foundation

extension FakeBackend {
  func memories() async throws -> [MemoryItem] {
    guard let mine = memberOfSession() else { return [] }
    let rows = store.world.dates
      .filter { $0.coupleId == mine.coupleId && $0.status == .completed }
      .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    return rows.enumerated().map { index, date in
      let notes = store.world.notes.filter { $0.dateId == date.id }.map { note in
        MemoryNote(
          id: note.id, authorUserId: note.authorUserId, authorName: note.authorName,
          note: note.note, mine: note.authorUserId == mine.userId
        )
      }
      return MemoryItem(
        id: date.id,
        title: date.snapshotTitle ?? date.planTitle ?? L10n.enough,
        emoji: date.snapshotEmoji ?? "♥",
        summary: date.snapshotSummary,
        location: date.location,
        when: date.completedAt ?? date.scheduledAt,
        number: rows.count - index,
        notes: notes,
        photoPath: date.photoJPEG == nil ? nil : "\(mine.coupleId.uuidString)/\(date.id.uuidString).jpg",
        photoJPEG: date.photoJPEG,
        photoState: date.photoJPEG == nil ? .empty : .saved
      )
    }
  }

  func saveNote(dateId: UUID, noteId: UUID?, text: String) async throws {
    try requireOnline()
    guard let mine = memberOfSession() else { throw AppError.notAuthenticated }
    guard owns(dateId, couple: mine.coupleId) else { throw AppError.saveFailed }
    guard let note = Validation.note(text), !note.isEmpty else { throw AppError.invalid(.note) }
    if let noteId, let index = store.world.notes.firstIndex(where: { $0.id == noteId && $0.authorUserId == mine.userId }) {
      store.world.notes[index].note = note
    } else {
      let id = noteId ?? UUID()
      store.world.notes.removeAll { $0.id == id }
      store.world.notes.append(FakeNote(
        id: id, dateId: dateId, authorUserId: mine.userId,
        authorName: member(mine.userId)?.displayName ?? "", note: note
      ))
    }
    store.save()
  }

  func deleteNote(id: UUID) async throws {
    try requireOnline()
    guard let mine = memberOfSession() else { throw AppError.notAuthenticated }
    let before = store.world.notes.count
    store.world.notes.removeAll { $0.id == id && $0.authorUserId == mine.userId }
    if store.world.notes.count == before { throw AppError.saveFailed }
    store.save()
  }

  func savePhoto(dateId: UUID, jpeg: Data) async throws {
    try requireOnline()
    guard let mine = memberOfSession(), let index = store.world.dates.firstIndex(where: { $0.id == dateId && $0.coupleId == mine.coupleId }) else {
      throw AppError.saveFailed
    }
    guard PhotoSavePolicy.shouldCommitPath(uploadSucceeded: true) else { throw AppError.saveFailed }
    store.world.dates[index].photoJPEG = jpeg
    store.save()
  }

  func settings() async throws -> SettingsSnapshot? {
    guard let mine = memberOfSession(), let couple = store.world.couples.first(where: { $0.id == mine.coupleId }) else {
      return nil
    }
    let partner = store.world.members.first { $0.coupleId == couple.id && $0.userId != mine.userId }
    let invite = store.world.invites
      .filter { $0.coupleId == couple.id && !$0.used && !$0.revoked && $0.expires > Date() }
      .max { $0.expires < $1.expires }
    return SettingsSnapshot(
      coupleId: couple.id,
      selfName: mine.displayName,
      partnerName: partner?.displayName ?? couple.inviteeName,
      partnerJoined: partner != nil,
      weekday: couple.weekday,
      localTime: couple.localTime,
      timezone: couple.timezone,
      durationMinutes: couple.durationMinutes,
      pendingInviteExpires: invite?.expires,
      preferences: preferences()
    )
  }

  func saveSettings(_ settings: SettingsSnapshot) async throws {
    try requireOnline()
    guard let mine = memberOfSession(), let coupleIndex = store.world.couples.firstIndex(where: { $0.id == mine.coupleId }) else {
      throw AppError.notAuthenticated
    }
    guard let selfName = Validation.displayName(settings.selfName), let partnerName = Validation.displayName(settings.partnerName) else {
      throw AppError.invalid(.name)
    }
    guard Validation.weekday(settings.weekday), Validation.time(settings.localTime) != nil else { throw AppError.invalid(.time) }
    guard ZonedTime.isValidZone(settings.timezone), Validation.duration(settings.durationMinutes) else {
      throw AppError.invalid(.timezone)
    }
    store.world.couples[coupleIndex].weekday = settings.weekday
    store.world.couples[coupleIndex].localTime = settings.localTime
    store.world.couples[coupleIndex].timezone = settings.timezone
    store.world.couples[coupleIndex].durationMinutes = settings.durationMinutes
    if mine.memberIndex == 0 {
      store.world.couples[coupleIndex].inviteeName = partnerName
    }
    if let index = store.world.members.firstIndex(where: { $0.userId == mine.userId }) {
      store.world.members[index].displayName = selfName
    }
    if let partner = store.world.members.firstIndex(where: { $0.coupleId == mine.coupleId && $0.userId != mine.userId }) {
      store.world.members[partner].displayName = partnerName
    }
    await savePreferences(settings.preferences)
    store.save()
  }

  func retryClosedPhotos() async {}

  func unlink() async throws {
    try requireOnline()
    guard let mine = memberOfSession() else { throw AppError.notAuthenticated }
    let coupleId = mine.coupleId
    let partners = store.world.members.filter { $0.coupleId == coupleId && $0.userId != mine.userId }
    for partner in partners {
      store.markSpaceClosed(partner.userId)
    }
    removeCouple(coupleId)
    store.save()
  }

  func deleteAccount() async throws {
    try requireOnline()
    guard let userId = store.world.sessionUserId else { throw AppError.notAuthenticated }
    if let mine = member(userId) {
      let coupleId = mine.coupleId
      let partners = store.world.members.filter { $0.coupleId == coupleId && $0.userId != userId }
      for partner in partners {
        store.markSpaceClosed(partner.userId)
      }
      removeCouple(coupleId)
    }
    store.world.users.removeAll { $0.id == userId }
    store.world.sessionUserId = nil
    store.world.preferences[userId.uuidString] = nil
    store.save()
    _ = AccountDeletionPolicy.closesTheSharedSpace
  }

  func takeSpaceClosed() async -> Bool {
    guard let userId = store.world.sessionUserId else { return false }
    return store.takeSpaceClosed(userId)
  }

  private func memberOfSession() -> FakeMember? {
    guard let id = store.world.sessionUserId else { return nil }
    return member(id)
  }

  private func requireOnline() throws {
    if store.world.offline { throw AppError.offline }
  }

  private func owns(_ dateId: UUID, couple: UUID) -> Bool {
    store.world.dates.contains { $0.id == dateId && $0.coupleId == couple }
  }
}
