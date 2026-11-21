import Foundation

@MainActor
final class FakeBackend: DateBackend {
  var onRemoteChange: (@MainActor () -> Void)?
  var onChatInsert: (@MainActor (ChatMessageRow) -> Void)?
  var onChatOpened: (@MainActor (UUID) -> Void)?
  var onChatReload: (@MainActor () -> Void)?
  var recentShots: [UUID: Date] = [:]
  /// Holds the next view-once consume so a test can see the opened bubble first.
  var holdConsume = false
  private var consumeHold: CheckedContinuation<Void, Never>?
  /// Holds the next send so a test can see the optimistic bubble.
  var holdSend = false
  /// Thrown once, after the hold releases, instead of storing the message.
  var failSend: AppError?
  /// Thrown once from a photo send, so a key retry can be seen.
  var photoKeyFailure: AppError?
  /// Thrown at the start of consume, before the row is marked opened.
  var consumeError: AppError?
  private var sendHold: CheckedContinuation<Void, Never>?
  /// Forces the next mood save to fail the way a live write can, including a
  /// PostgREST 42501 after reveal.
  var moodFailure: AppError?
  let store: FakeStore
  private let cooldown: TimeInterval
  /// Wall clock for the streak and for a new draft. Tests can freeze it.
  var clock: @MainActor () -> Date = { Date() }
  /// PKCE verifier for the latest magic link. Sign-out drops it, so an old link cannot be reused.
  private(set) var codeVerifier: String?
  var chatFailure: AppError?
  /// When set, deleting a chat photo object fails and the row keeps its path.
  var photoRemoveError: Error?
  /// The token delete throws this instead of succeeding. A dead session signs out locally.
  var deleteFailure: Error?
  /// The key retire throws this after the token delete. The session stays, and the token is put back.
  var retireFailure: Error?
  private(set) var tokenRecoveries = 0
  private var seenPartnerKeys: [UUID: Set<Data>] = [:]
  private var phoneKeys: [UUID: UUID] = [:]
  private var keyNotice: String?

  init(store: FakeStore? = nil, cooldown: TimeInterval? = nil, now: Date? = nil) {
    // Default arguments are nonisolated, so the MainActor store is built in the body.
    if let now {
      self.store = store ?? FakeStore(inMemory: true, now: now)
      self.clock = { @MainActor in now }
    } else {
      self.store = store ?? FakeStore()
      self.clock = { Date() }
    }
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
    let userId = store.world.sessionUserId
    try await ChatSignOut.perform(
      deleteToken: {
        if let deleteFailure = self.deleteFailure { throw deleteFailure }
        if self.blockSignOut { throw AppError.signOutBlocked }
      },
      retire: {
        if let retireFailure = self.retireFailure { throw retireFailure }
        guard let userId else { return }
        for index in self.store.world.deviceKeys.indices where self.store.world.deviceKeys[index].userId == userId {
          self.store.world.deviceKeys[index].retiredAt = Date()
        }
        self.store.save()
      },
      authSignOut: { await self.dropExpiredSession() },
      recoverToken: { self.tokenRecoveries += 1 }
    )
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

  func scheduleUnrevealed() {
    guard let index = store.world.dates.firstIndex(where: { $0.id == SeedID.dateA }) else { return }
    store.world.dates[index].status = .scheduled
    store.world.dates[index].revealedAt = nil
    store.save()
  }

  func markRevealed() {
    guard let index = store.world.dates.firstIndex(where: { $0.id == SeedID.dateA }) else { return }
    store.world.dates[index].status = .scheduled
    store.world.dates[index].revealedAt = Date()
    store.save()
  }

  func finishDate() {
    guard let index = store.world.dates.firstIndex(where: { $0.id == SeedID.dateA }) else { return }
    store.world.dates[index].status = .completed
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

  func current() -> FakeUser? {
    guard let id = store.world.sessionUserId else { return nil }
    return store.world.users.first { $0.id == id }
  }

  func member(_ userId: UUID) -> FakeMember? {
    store.world.members.first { $0.userId == userId }
  }

  func display(_ userId: UUID) -> String {
    store.world.members.first { $0.userId == userId }?.displayName
      ?? store.world.users.first { $0.id == userId }?.email
      ?? ""
  }

  func guardOnline() throws {
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
      weekday: couple.weekday, time: couple.localTime, timeZone: couple.timezone, from: clock()
    )
    let completed = store.world.dates.filter { $0.coupleId == coupleId && $0.status == .completed }.count
    let members = store.world.members.filter { $0.coupleId == coupleId }.sorted { $0.memberIndex < $1.memberIndex }
    let nights = store.world.dates.filter { $0.coupleId == coupleId }.map {
      DatedNight(status: $0.status, scheduledAt: $0.scheduledAt, createdAt: $0.createdAt, plannerUserId: $0.plannerUserId)
    }
    let memberRefs = members.map {
      MemberRef(userId: $0.userId, displayName: $0.displayName, memberIndex: $0.memberIndex)
    }
    let plannerId = PlannerTurn.nextPlanner(nights: nights, members: memberRefs) ?? planner
    let location = try Recommendation.suggestedLocation(completedCount: completed)
    store.world.dates.append(FakeDate(
      id: UUID(), coupleId: coupleId, status: .draft, scheduledAt: when, createdAt: clock(),
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

  func partnerKeyNotice() -> String? {
    keyNotice
  }

  func messages() async throws -> [ChatLine] {
    if let chatFailure { throw chatFailure }
    guard let user = current(), let mine = member(user.id) else { return [] }
    let identity = try ensureKey(userId: user.id, reason: .refresh)
    let coupleKeys = store.world.deviceKeys.filter { member($0.userId)?.coupleId == mine.coupleId }
    let published = coupleKeys.map { (userId: $0.userId, publicKey: $0.publicKey) }
    let partnerKeys = coupleKeys.filter { $0.userId != user.id && $0.retiredAt == nil }.map(\.publicKey)
    let previous = seenPartnerKeys[user.id] ?? []
    if PartnerKeyMemory.changed(previous: previous, current: partnerKeys) {
      keyNotice = L10n.chatKeyChanged
    }
    seenPartnerKeys[user.id] = Set(partnerKeys)
    sweepExpiredChats(now: clock())
    let lines = store.world.chats
      .filter { $0.coupleId == mine.coupleId }
      .map { row in
        presentChat(row, identity: identity, userId: user.id, published: published)
      }
    return ChatWindow.chronological(lines)
  }

  func invalidateChatCache() {}

  func incomingLine(_ row: ChatMessageRow) async -> ChatLine? {
    nil
  }

  func releaseSend() {
    holdSend = false
    sendHold?.resume()
    sendHold = nil
  }

  func releaseConsume() {
    holdConsume = false
    consumeHold?.resume()
    consumeHold = nil
  }

  func pauseSendIfNeeded() async {
    guard holdSend else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      sendHold = continuation
    }
  }

  func pauseConsumeIfNeeded() async {
    guard holdConsume else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      consumeHold = continuation
    }
  }

  func sendMessage(_ text: String, id: UUID) async throws -> ChatLine {
    if holdSend {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        sendHold = continuation
      }
    }
    if let failSend {
      let error = failSend
      self.failSend = nil
      throw error
    }
    try guardOnline()
    let clear = try ChatText.normalized(text)
    guard let user = current(), let mine = member(user.id) else { throw AppError.saveFailed }
    if store.world.chats.contains(where: { $0.id == id }) {
      return ChatLine(
        id: id, senderUserId: user.id, text: clear, createdAt: clock(),
        mine: true, unreadable: false, delivery: .sent
      )
    }
    let partner = store.world.members.contains { $0.coupleId == mine.coupleId && $0.userId != user.id }
    guard partner else { throw AppError.partnerNotReady }
    let identity = try ensureKey(userId: user.id, reason: .send)
    let keys = store.world.deviceKeys.filter { member($0.userId)?.coupleId == mine.coupleId }
    let targets = ChatRecipients.choose(
      senderUserId: user.id, senderKeyId: identity.id,
      keys: keys.map {
        (id: $0.id, userId: $0.userId, publicKey: $0.publicKey, createdAt: $0.createdAt, retired: $0.retiredAt != nil)
      }
    )
    guard targets.contains(where: { $0.userId != user.id }) else { throw AppError.partnerNotReady }
    let envelopes = try ChatCrypto.seal(
      text: clear, messageId: id, senderUserId: user.id, from: identity, to: targets
    )
    let row = FakeChat(
      id: id, coupleId: mine.coupleId, senderUserId: user.id, senderPublicKey: identity.publicKey,
      createdAt: Date(), envelopes: envelopes.map { FakeEnvelope(keyId: $0.keyId, box: $0.box) }
    )
    store.world.chats.append(row)
    store.save()
    let published = store.world.deviceKeys.filter { member($0.userId)?.coupleId == mine.coupleId }
      .map { (userId: $0.userId, publicKey: $0.publicKey) }
    var line = presentChat(row, identity: identity, userId: user.id, published: published)
    line.delivery = .sent
    return line
  }

  func seedChatPreview() {
    guard let alex = member(SeedID.alex), let blairKey = try? ensureKey(userId: SeedID.blair),
          let alexKey = try? ensureKey(userId: SeedID.alex) else { return }
    let lines = [
      (SeedID.blair, blairKey, "I'll bring tea."),
      (SeedID.alex, alexKey, "Thursday still works.")
    ]
    for (userId, key, text) in lines {
      let keys = store.world.deviceKeys.filter { member($0.userId)?.coupleId == alex.coupleId }
      let targets = ChatRecipients.choose(
        senderUserId: userId, senderKeyId: key.id,
        keys: keys.map {
          (id: $0.id, userId: $0.userId, publicKey: $0.publicKey, createdAt: $0.createdAt, retired: $0.retiredAt != nil)
        }
      )
      let messageId = UUID()
      guard let envelopes = try? ChatCrypto.seal(
        text: text, messageId: messageId, senderUserId: userId, from: key, to: targets
      ) else { continue }
      store.world.chats.append(FakeChat(
        id: messageId, coupleId: alex.coupleId, senderUserId: userId, senderPublicKey: key.publicKey,
        createdAt: Date(), envelopes: envelopes.map { FakeEnvelope(keyId: $0.keyId, box: $0.box) }
      ))
    }
    store.save()
  }

  func ensureKey(userId: UUID, reason: KeyRotation.Reason = .refresh) throws -> ChatIdentity {
    let held = heldKey(userId: userId)
    let activeCount = store.world.deviceKeys.filter { $0.userId == userId && $0.retiredAt == nil }.count
    let decision = try KeyRotation.enforce(KeyRotation.step(
      hasRow: held != nil, retired: held?.retiredAt != nil, activeCount: activeCount,
      retiredAt: held?.retiredAt, now: clock(), reason: reason
    ), reason: reason)
    switch decision {
    case .keep, .hold:
      guard let held else { throw ChatCryptoError.unreadable }
      return try ChatIdentity.restored(id: held.id, privateKey: held.privateKey)
    case .publish:
      let created = ChatIdentity.generate()
      store.world.deviceKeys.append(FakeDeviceKey(
        id: created.id, userId: userId, publicKey: created.publicKey,
        privateKey: created.privateKey.rawRepresentation, createdAt: clock()
      ))
      phoneKeys[userId] = created.id
      capActiveKeys(userId: userId)
      store.save()
      return created
    }
  }

  /// This phone's key. A new process adopts the key it already saved instead of minting another.
  private func heldKey(userId: UUID) -> FakeDeviceKey? {
    if let id = phoneKeys[userId], let key = store.world.deviceKeys.first(where: { $0.id == id }) {
      return key
    }
    let mine = store.world.deviceKeys.filter { $0.userId == userId }
    let active = mine.filter { $0.retiredAt == nil }
    let pool = active.isEmpty ? mine : active
    let adopted = pool.max { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    if let adopted { phoneKeys[userId] = adopted.id }
    return adopted
  }

  private func capActiveKeys(userId: UUID) {
    let active = store.world.deviceKeys.filter { $0.userId == userId && $0.retiredAt == nil }
    let excess = Set(KeyCap.excessIds(active.map { ($0.id, $0.createdAt) }))
    guard excess.isEmpty == false else { return }
    let now = clock()
    for index in store.world.deviceKeys.indices {
      let key = store.world.deviceKeys[index]
      if key.userId == userId, excess.contains(key.id) {
        store.world.deviceKeys[index].retiredAt = now
      }
    }
  }

  func retiredIdentities(userId: UUID, current: UUID) -> [ChatIdentity] {
    store.world.deviceKeys.compactMap { key in
      guard key.userId == userId, key.id != current else { return nil }
      return try? ChatIdentity.restored(id: key.id, privateKey: key.privateKey)
    }
  }
}
