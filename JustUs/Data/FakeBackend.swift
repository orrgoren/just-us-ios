import Foundation

@MainActor
final class FakeBackend: DateBackend {
  var onRemoteChange: (@MainActor () -> Void)?
  let store: FakeStore
  private let cooldown: TimeInterval
  /// PKCE verifier for the latest magic link. Sign-out drops it, so an old link cannot be reused.
  private(set) var codeVerifier: String?

  init(store: FakeStore? = nil, cooldown: TimeInterval? = nil) {
    // Default arguments are nonisolated, so the MainActor store is built in the body.
    self.store = store ?? FakeStore()
    if let cooldown {
      self.cooldown = cooldown
    } else {
      self.cooldown = 30
    }
  }

  func sendCode(email: String) async throws {
    try guardOnline()
    guard let normalized = Validation.email(email) else { throw AppError.invalid(.email) }
    if let sent = store.world.otpSentAt[normalized], Date().timeIntervalSince(sent) < cooldown {
      throw AppError.cooldown(seconds: max(1, Int(cooldown - Date().timeIntervalSince(sent))))
    }
    store.world.otpSentAt[normalized] = Date()
    codeVerifier = UUID().uuidString
    store.save()
  }

  func verify(email: String, code: String) async throws -> SessionUser {
    try guardOnline()
    guard let normalized = Validation.email(email) else { throw AppError.invalid(.email) }
    guard store.world.otpSentAt[normalized] != nil else { throw AppError.invalidCode }
    try accept(code: code, email: normalized)
    let user = user(email: normalized)
    store.world.sessionUserId = user.id
    store.save()
    return SessionUser(id: user.id, email: user.email, displayHint: nil)
  }

  func session(from url: URL) async throws -> SessionUser {
    try guardOnline()
    guard AuthCallback.isCallback(url) else { throw AppError.notAuthenticated }
    if AuthCallback.isStale(url) { throw AppError.linkExpired }
    let items = AuthCallback.params(url)
    let hasGrant = items["code"] != nil || items["access_token"] != nil
    guard hasGrant, codeVerifier != nil, let email = store.world.otpSentAt.max(by: { $0.value < $1.value })?.key else {
      throw AppError.linkExpired
    }
    codeVerifier = nil
    store.world.otpSentAt[email] = nil
    let account = user(email: email)
    store.world.sessionUserId = account.id
    store.save()
    return SessionUser(id: account.id, email: account.email, displayHint: nil)
  }

  func signInWithApple(idToken: String, nonce: String) async throws -> SessionUser {
    _ = idToken
    _ = nonce
    try guardOnline()
    let email = "apple@uitest.local"
    let user = user(email: email)
    store.world.sessionUserId = user.id
    store.save()
    return SessionUser(id: user.id, email: user.email, displayHint: nil)
  }

  func restore() async throws -> SessionUser? {
    guard let id = store.world.sessionUserId, let user = store.world.users.first(where: { $0.id == id }) else {
      return nil
    }
    return SessionUser(id: user.id, email: user.email, displayHint: nil)
  }

  var blockSignOut = false

  func signOut() async throws {
    if blockSignOut { throw AppError.signOutBlocked }
    await dropExpiredSession()
  }

  func dropExpiredSession() async {
    store.world.sessionUserId = nil
    store.world.otpSentAt = [:]
    codeVerifier = nil
    store.save()
    CacheStore.deleteAll()
  }

  func membership() async throws -> MembershipKind {
    guard let user = current() else { throw AppError.notAuthenticated }
    guard let member = member(user.id) else { return .none }
    return eligibility(coupleId: member.coupleId)
  }

  func createCouple(_ draft: CoupleDraft) async throws {
    try guardOnline()
    guard let user = current() else { throw AppError.notAuthenticated }
    if member(user.id) != nil { throw AppError.alreadyInCouple }
    if let issue = Validation.couple(draft) { throw issue }
    let coupleId = UUID()
    store.world.couples.append(FakeCouple(
      id: coupleId, inviteeName: draft.partnerName, weekday: draft.weekday,
      localTime: draft.localTime, timezone: draft.timezone, durationMinutes: draft.durationMinutes
    ))
    store.world.members.append(FakeMember(
      userId: user.id, coupleId: coupleId, displayName: draft.selfName, memberIndex: 0
    ))
    try addDraft(coupleId: coupleId, planner: user.id)
    store.save()
  }

  func createInvite() async throws -> String {
    try guardOnline()
    guard let user = current(), let mine = member(user.id) else { throw AppError.notAuthenticated }
    let others = store.world.members.filter { $0.coupleId == mine.coupleId }
    if others.count >= 2 { throw AppError.coupleFull }
    for index in store.world.invites.indices where store.world.invites[index].coupleId == mine.coupleId && !store.world.invites[index].used {
      store.world.invites[index].revoked = true
    }
    let token = InviteRules.makeToken()
    store.world.invites.append(FakeInvite(
      token: token, coupleId: mine.coupleId, inviterId: user.id,
      expires: Date().addingTimeInterval(7 * 86_400), used: false, revoked: false
    ))
    store.save()
    return token
  }

  func redeem(token: String, replaceEmpty: Bool) async throws {
    try guardOnline()
    guard let user = current() else { throw AppError.notAuthenticated }
    guard let extracted = InviteRules.token(from: token) else { throw AppError.invalidInvite }
    guard let invite = store.world.invites.first(where: { $0.token == extracted && !$0.revoked }) else {
      throw AppError.invalidInvite
    }
    if invite.used { throw AppError.usedInvite }
    if invite.expires < Date() { throw AppError.expiredInvite }
    if invite.inviterId == user.id { throw AppError.selfRedeem }
    let members = store.world.members.filter { $0.coupleId == invite.coupleId }
    if members.count >= 2 { throw AppError.coupleFull }
    if let mine = member(user.id) {
      try leaveForRedeem(member: mine, replaceEmpty: replaceEmpty)
    }
    let index = store.world.members.filter { $0.coupleId == invite.coupleId }.count
    store.world.members.append(FakeMember(
      userId: user.id, coupleId: invite.coupleId, displayName: display(user.id), memberIndex: index
    ))
    if let inviteIndex = store.world.invites.firstIndex(where: { $0.token == extracted }) {
      store.world.invites[inviteIndex].used = true
    }
    store.save()
  }

  func setOffline(_ offline: Bool) {
    store.world.offline = offline
    store.save()
  }

  func injectPartnerMood() async {
    guard let user = current(), let mine = member(user.id), let date = activeDate(mine.coupleId) else { return }
    guard let partner = store.world.members.first(where: { $0.coupleId == mine.coupleId && $0.userId != user.id }) else {
      return
    }
    upsertMood(dateId: date.id, userId: partner.userId, mood: .chill)
    store.save()
    onRemoteChange?()
  }

  func preferences() -> PushPreferences {
    guard let user = current() else { return .allOn }
    return store.world.preferences[user.id.uuidString] ?? .allOn
  }

  func savePreferences(_ preferences: PushPreferences) async {
    guard let user = current() else { return }
    store.world.preferences[user.id.uuidString] = preferences
    store.save()
  }

  func registerDevice(token: String) async {
    _ = token
  }

  func markRevealed() {
    guard let index = store.world.dates.firstIndex(where: { $0.id == SeedID.dateA }) else { return }
    store.world.dates[index].status = .scheduled
    store.world.dates[index].revealedAt = Date()
    store.save()
  }

  private func accept(code: String, email: String) throws {
    guard let digits = Validation.code(code) else { throw AppError.invalid(.code) }
    if digits == "111111" { throw AppError.expiredCode }
    if digits == "222222" { throw AppError.invalidCode }
    if digits == "424242" {
      guard email == "demo@justus.app" else { throw AppError.invalidCode }
      return
    }
    guard digits == "000000" else { throw AppError.invalidCode }
  }

  private func user(email: String) -> FakeUser {
    if let existing = store.world.users.first(where: { $0.email == email }) { return existing }
    let created = FakeUser(id: UUID(), email: email)
    store.world.users.append(created)
    store.world.preferences[created.id.uuidString] = .allOn
    return created
  }

  private func current() -> FakeUser? {
    guard let id = store.world.sessionUserId else { return nil }
    return store.world.users.first { $0.id == id }
  }

  func member(_ userId: UUID) -> FakeMember? {
    store.world.members.first { $0.userId == userId }
  }

  private func display(_ userId: UUID) -> String {
    store.world.members.first { $0.userId == userId }?.displayName
      ?? store.world.users.first { $0.id == userId }?.email
      ?? ""
  }

  private func guardOnline() throws {
    if store.world.offline { throw AppError.offline }
  }

  private func eligibility(coupleId: UUID) -> MembershipKind {
    let members = store.world.members.filter { $0.coupleId == coupleId }.count
    let dates = store.world.dates.filter { $0.coupleId == coupleId }
    let nonDraft = dates.filter { $0.status != .draft }.count
    let plans = dates.filter { $0.ideaId != nil }.count
    let notes = store.world.notes.filter { note in dates.contains { $0.id == note.dateId } }.count
    return InviteRules.canLeaveSolo(memberCount: members, nonDraftCount: nonDraft, planCount: plans, noteCount: notes)
      ? .emptySolo : .kept
  }

  private func leaveForRedeem(member: FakeMember, replaceEmpty: Bool) throws {
    switch eligibility(coupleId: member.coupleId) {
    case .none:
      return
    case .emptySolo:
      guard replaceEmpty else { throw AppError.alreadyInCouple }
      removeCouple(member.coupleId)
    case .kept:
      throw AppError.soloNotEmpty
    }
  }

  func removeCouple(_ coupleId: UUID) {
    let dateIds = Set(store.world.dates.filter { $0.coupleId == coupleId }.map(\.id))
    store.world.couples.removeAll { $0.id == coupleId }
    store.world.members.removeAll { $0.coupleId == coupleId }
    store.world.dates.removeAll { $0.coupleId == coupleId }
    store.world.moods.removeAll { dateIds.contains($0.dateId) }
    store.world.notes.removeAll { dateIds.contains($0.dateId) }
    store.world.invites.removeAll { $0.coupleId == coupleId }
  }

  func activeDate(_ coupleId: UUID) -> FakeDate? {
    store.world.dates.first { $0.coupleId == coupleId && ($0.status == .draft || $0.status == .scheduled) }
  }

  func addDraft(coupleId: UUID, planner: UUID) throws {
    guard store.world.dates.contains(where: { $0.coupleId == coupleId && ($0.status == .draft || $0.status == .scheduled) }) == false else {
      return
    }
    guard let couple = store.world.couples.first(where: { $0.id == coupleId }) else { throw AppError.saveFailed }
    let when = try ZonedTime.nextWeeklySlot(
      weekday: couple.weekday, time: couple.localTime, timeZone: couple.timezone, from: Date()
    )
    let completed = store.world.dates.filter { $0.coupleId == coupleId && $0.status == .completed }.count
    let plannerIndex = try Recommendation.defaultPlannerIndex(completedCount: completed)
    let members = store.world.members.filter { $0.coupleId == coupleId }.sorted { $0.memberIndex < $1.memberIndex }
    let plannerId = members.indices.contains(plannerIndex) ? members[plannerIndex].userId : planner
    let location = try Recommendation.suggestedLocation(completedCount: completed)
    store.world.dates.append(FakeDate(
      id: UUID(), coupleId: coupleId, status: .draft, scheduledAt: when,
      durationMinutes: couple.durationMinutes, location: location, locationIsOverride: false,
      publicTeaser: nil, outfitHint: nil, revealedAt: nil, plannerUserId: plannerId,
      ideaId: nil, planTitle: nil, privateNotes: nil, photoJPEG: nil,
      snapshotTitle: nil, snapshotEmoji: nil, snapshotSummary: nil, completedAt: nil
    ))
  }

  func upsertMood(dateId: UUID, userId: UUID, mood: MoodKey) {
    if let index = store.world.moods.firstIndex(where: { $0.dateId == dateId && $0.userId == userId }) {
      store.world.moods[index].mood = mood
    } else {
      store.world.moods.append(FakeMood(dateId: dateId, userId: userId, mood: mood))
    }
  }
}
