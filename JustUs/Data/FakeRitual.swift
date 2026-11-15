import Foundation

extension FakeBackend {
  func ritual() async throws -> RitualSnapshot? {
    guard let user = currentUser() else { return nil }
    guard let mine = member(user.id), let couple = couple(mine.coupleId) else { return nil }
    let members = store.world.members.filter { $0.coupleId == couple.id }.sorted { $0.memberIndex < $1.memberIndex }
    let completed = store.world.dates.filter { $0.coupleId == couple.id && $0.status == .completed }.count
    guard let date = activeDate(couple.id) else {
      return snapshot(user: user, mine: mine, couple: couple, members: members, completed: completed, date: nil)
    }
    return snapshot(user: user, mine: mine, couple: couple, members: members, completed: completed, date: date)
  }

  func setMood(_ mood: MoodKey) async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let date = activeDate(mine.coupleId) else {
      throw AppError.saveFailed
    }
    upsertMood(dateId: date.id, userId: user.id, mood: mood)
    store.save()
  }

  func setPlace(_ choice: PlaceChoice) async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    guard store.world.dates[index].plannerUserId == user.id else { throw AppError.notPlanner }
    guard store.world.dates[index].status == .draft else { throw AppError.notEditable }
    let completed = store.world.dates.filter { $0.coupleId == mine.coupleId && $0.status == .completed }.count
    let resolved = try Recommendation.resolve(completedCount: completed, choice: choice)
    store.world.dates[index].location = resolved.location
    store.world.dates[index].locationIsOverride = resolved.isOverride
    if let idea = idea(store.world.dates[index].ideaId), idea.loc != resolved.location {
      store.world.dates[index].ideaId = nil
      store.world.dates[index].planTitle = nil
    }
    store.save()
  }

  func surprise(excluding: [String]) async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    let date = store.world.dates[index]
    guard date.plannerUserId == user.id else { throw AppError.notPlanner }
    guard date.status == .draft else { throw AppError.notEditable }
    let moods = store.world.moods.filter { $0.dateId == date.id }.map(\.mood)
    let recent = store.world.dates.filter { $0.coupleId == mine.coupleId && $0.status == .completed }.compactMap(\.ideaId)
    guard let picked = Recommendation.pick(
      ideas: IdeasCatalog.load(), location: date.location, moods: moods,
      recentIdeaIds: recent, excludeIds: excluding
    ) else { throw AppError.missingPlan }
    store.world.dates[index].ideaId = picked.id
    store.world.dates[index].planTitle = picked.title
    store.save()
  }

  func saveHint(teaser: String, outfit: String, notes: String) async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    guard store.world.dates[index].plannerUserId == user.id else { throw AppError.notPlanner }
    let revealed = store.world.dates[index].revealedAt != nil
    guard HintEdit.allowed(status: store.world.dates[index].status, revealed: revealed) else {
      throw AppError.notEditable
    }
    guard let teaserValue = Validation.teaser(teaser), let outfitValue = Validation.teaser(outfit) else {
      throw AppError.invalid(.teaser)
    }
    guard let noteValue = Validation.note(notes) else { throw AppError.invalid(.note) }
    store.world.dates[index].publicTeaser = teaserValue.isEmpty ? nil : teaserValue
    store.world.dates[index].outfitHint = outfitValue.isEmpty ? nil : outfitValue
    store.world.dates[index].privateNotes = noteValue.nilIfEmpty
    store.save()
  }

  func saveDate(day: String, time: String, teaser: String, outfit: String, notes: String) async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let couple = couple(mine.coupleId), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    guard store.world.dates[index].plannerUserId == user.id else { throw AppError.notPlanner }
    guard store.world.dates[index].status == .draft else { throw AppError.notEditable }
    guard store.world.dates[index].ideaId != nil else { throw AppError.missingPlan }
    try await saveHint(teaser: teaser, outfit: outfit, notes: notes)
    guard let fresh = dateIndex(mine.coupleId) else { throw AppError.saveFailed }
    let when = try ZonedTime.zonedLocalToUtc(date: day, time: time, timeZone: couple.timezone)
    store.world.dates[fresh].scheduledAt = when
    store.world.dates[fresh].status = .scheduled
    store.save()
  }

  func reveal() async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    guard store.world.dates[index].status == .scheduled, store.world.dates[index].revealedAt == nil else {
      throw AppError.saveFailed
    }
    _ = user
    store.world.dates[index].revealedAt = Date()
    store.save()
  }

  func skipWeek() async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    _ = user
    store.world.dates[index].status = .skipped
    try addDraft(coupleId: mine.coupleId, planner: store.world.dates[index].plannerUserId)
    store.save()
  }

  func swapPlanner() async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    let members = store.world.members.filter { $0.coupleId == mine.coupleId }
    guard members.count >= 2, store.world.dates[index].status == .draft else { throw AppError.saveFailed }
    guard let other = members.first(where: { $0.userId != store.world.dates[index].plannerUserId }) else {
      throw AppError.saveFailed
    }
    store.world.dates[index].ideaId = nil
    store.world.dates[index].planTitle = nil
    store.world.dates[index].privateNotes = nil
    store.world.dates[index].plannerUserId = other.userId
    _ = user
    store.save()
  }

  func reopen() async throws {
    try online()
    guard let mine = currentMember(), let index = dateIndex(mine.coupleId) else { throw AppError.saveFailed }
    guard store.world.dates[index].status == .scheduled, store.world.dates[index].revealedAt == nil else {
      throw AppError.saveFailed
    }
    store.world.dates[index].status = .draft
    store.save()
  }

  func move(day: String, time: String) async throws {
    try online()
    guard let mine = currentMember(), let couple = couple(mine.coupleId), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    guard store.world.dates[index].status == .scheduled else { throw AppError.saveFailed }
    store.world.dates[index].scheduledAt = try ZonedTime.zonedLocalToUtc(date: day, time: time, timeZone: couple.timezone)
    store.save()
  }

  func complete(note: String) async throws {
    try online()
    guard let user = currentUser(), let mine = member(user.id), let index = dateIndex(mine.coupleId) else {
      throw AppError.saveFailed
    }
    guard let text = Validation.note(note) else { throw AppError.invalid(.note) }
    let date = store.world.dates[index]
    guard date.status == .scheduled || date.status == .draft else { throw AppError.saveFailed }
    store.world.dates[index].status = .completed
    store.world.dates[index].completedAt = Date()
    store.world.dates[index].snapshotTitle = date.planTitle
    store.world.dates[index].snapshotEmoji = idea(date.ideaId)?.emoji
    store.world.dates[index].snapshotSummary = idea(date.ideaId)?.summary
    if !text.isEmpty {
      store.world.notes.append(FakeNote(
        id: UUID(), dateId: date.id, authorUserId: user.id, authorName: name(user.id, couple: mine.coupleId), note: text
      ))
    }
    try addDraft(coupleId: mine.coupleId, planner: user.id)
    store.save()
  }

  func ensureDraft() async throws {
    try online()
    guard let mine = currentMember() else { throw AppError.notAuthenticated }
    try addDraft(coupleId: mine.coupleId, planner: mine.userId)
    store.save()
  }

  private func online() throws {
    if store.world.offline { throw AppError.offline }
  }

  private func currentUser() -> FakeUser? {
    guard let id = store.world.sessionUserId else { return nil }
    return store.world.users.first { $0.id == id }
  }

  private func currentMember() -> FakeMember? {
    guard let user = currentUser() else { return nil }
    return member(user.id)
  }

  private func couple(_ id: UUID) -> FakeCouple? {
    store.world.couples.first { $0.id == id }
  }

  private func dateIndex(_ coupleId: UUID) -> Int? {
    store.world.dates.firstIndex { $0.coupleId == coupleId && ($0.status == .draft || $0.status == .scheduled) }
  }

  private func idea(_ id: String?) -> DateIdea? {
    guard let id else { return nil }
    return IdeasCatalog.idea(id, in: IdeasCatalog.load())
  }

  private func name(_ userId: UUID, couple: UUID) -> String {
    store.world.members.first { $0.userId == userId && $0.coupleId == couple }?.displayName ?? ""
  }

  private func snapshot(
    user: FakeUser,
    mine: FakeMember,
    couple: FakeCouple,
    members: [FakeMember],
    completed: Int,
    date: FakeDate?
  ) -> RitualSnapshot {
    let partner = members.first { $0.userId != user.id }
    let card = date.map { makeCard($0, members: members, couple: couple, completed: completed) }
    let moods = date.map { item in
      store.world.moods.filter { $0.dateId == item.id }.map { MoodVote(userId: $0.userId, mood: $0.mood) }
    } ?? []
    let isPlanner = date?.plannerUserId == user.id
    let revealed = date?.revealedAt != nil
    var plan: FullPlan?
    if let date, isPlanner || revealed, let idea = idea(date.ideaId) {
      var built = IdeasCatalog.plan(from: idea, notes: date.privateNotes)
      if let title = date.planTitle { built.title = title }
      plan = built
    }
    let view = RitualSnapshot(
      coupleId: couple.id,
      selfMember: MemberRef(userId: mine.userId, displayName: mine.displayName, memberIndex: mine.memberIndex),
      partner: partner.map { MemberRef(userId: $0.userId, displayName: $0.displayName, memberIndex: $0.memberIndex) },
      inviteeName: couple.inviteeName,
      completedCount: completed,
      weekday: couple.weekday,
      localTime: couple.localTime,
      timezone: couple.timezone,
      durationMinutes: couple.durationMinutes,
      date: card,
      moods: moods,
      isPlanner: isPlanner,
      revealed: revealed,
      plan: plan
    )
    return RitualPrivacy.seal(view)
  }

  private func makeCard(_ date: FakeDate, members: [FakeMember], couple: FakeCouple, completed: Int) -> DateCard {
    let parts = (try? ZonedTime.zonedParts(instant: date.scheduledAt, timeZone: couple.timezone))
    let suggested = (try? Recommendation.suggestedLocation(completedCount: completed)) ?? .home
    let plannerName = members.first { $0.userId == date.plannerUserId }?.displayName ?? couple.inviteeName
    return DateCard(
      id: date.id, status: date.status, scheduledAt: date.scheduledAt,
      scheduledDate: parts?.date ?? "", scheduledTime: parts?.time ?? "",
      durationMinutes: date.durationMinutes, location: date.location,
      locationIsOverride: date.locationIsOverride, suggestedLocation: suggested,
      publicTeaser: date.publicTeaser, outfitHint: date.outfitHint,
      revealed: date.revealedAt != nil, plannerUserId: date.plannerUserId, plannerName: plannerName
    )
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
