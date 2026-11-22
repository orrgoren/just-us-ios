import Foundation
import os
import Supabase

@MainActor
final class LiveBackend: DateBackend {
  var onRemoteChange: (@MainActor () -> Void)?
  var onChatInsert: (@MainActor (ChatMessageRow) -> Void)?
  var onChatOpened: (@MainActor (UUID) -> Void)?
  var onChatReload: (@MainActor () -> Void)?
  var chatMaterials: ChatMaterials?
  var recentShots: [UUID: Date] = [:]
  let client: SupabaseClient?
  let chatSocket = LiveWatch()
  let moodSocket = LiveWatch()
  let keySocket = LiveWatch()
  private var cachedUser: UUID?
  private var deviceToken: String?
  private var partnerKeyNoticeText: String?
  private let publishGate = KeyPublishGate()

  init() {
    deviceToken = DeviceTokenStore.load().token
    guard let url = URL(string: AppConfig.supabaseURL), AppConfig.supabaseURL.hasPrefix("https://"), !AppConfig.anonKey.isEmpty else {
      client = nil
      return
    }
    // Default options copy the session access token onto Realtime for
    // initialSession, signedIn, and tokenRefreshed. A custom auth.accessToken
    // closure would skip that, and chat_messages RLS would drop the events.
    client = SupabaseClient(supabaseURL: url, supabaseKey: AppConfig.anonKey)
  }

  func sendCode(email: String) async throws {
    guard let normalized = Validation.email(email) else { throw AppError.invalid(.email) }
    guard let redirect = AuthCallback.redirect else { throw AppError.server(code: "redirect") }
    AuthStorageReset.clearVerifier()
    try await run { client in
      try await client.auth.signInWithOTP(
        email: normalized,
        redirectTo: redirect,
        shouldCreateUser: true
      )
    }
  }

  func verify(email: String, code: String) async throws -> SessionUser {
    guard let normalized = Validation.email(email), let digits = Validation.code(code) else { throw AppError.invalid(.code) }
    let user = try await run { client in
      let response = try await client.auth.verifyOTP(email: normalized, token: digits, type: .email)
      guard let session = response.session else { throw AppError.notAuthenticated }
      self.cachedUser = session.user.id
      return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
    }
    await uploadDeviceToken()
    return user
  }

  func session(from url: URL) async throws -> SessionUser {
    if AuthCallback.isStale(url) {
      AuthStorageReset.clear()
      throw AppError.linkExpired
    }
    do {
      let user = try await run { client in
        let session = try await client.auth.session(from: url)
        self.cachedUser = session.user.id
        return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
      }
      await uploadDeviceToken()
      return user
    } catch let error as AppError {
      if error == .linkExpired || error == .sessionExpired || error == .notAuthenticated {
        AuthStorageReset.clear()
        throw AppError.linkExpired
      }
      throw error
    }
  }

  func signInWithApple(idToken: String, nonce: String) async throws -> SessionUser {
    let user = try await run { client in
      let session = try await client.auth.signInWithIdToken(
        credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
      )
      self.cachedUser = session.user.id
      return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
    }
    await uploadDeviceToken()
    return user
  }

  func restore() async throws -> SessionUser? {
    guard let client else { return nil }
    do {
      let session = try await client.auth.session
      cachedUser = session.user.id
      await uploadDeviceToken()
      return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
    } catch {
      let mapped = ErrorMap.app(error)
      if mapped == .sessionExpired || mapped == .linkExpired {
        AuthStorageReset.clear()
      }
      return nil
    }
  }

  func signOut() async throws {
    await stopSockets()
    try await ChatSignOut.perform(
      deleteToken: { try await self.deleteTokenKeepingSession() },
      retire: { try await self.retirePublishedKey() },
      authSignOut: { await self.authSignOut() },
      recoverToken: { await self.uploadDeviceToken() }
    )
    wipeAfterSignOut()
  }

  /// Deletes the push row and leaves the auth session in place when that delete fails.
  /// A dead session is rethrown so sign-out can finish on this phone.
  private func deleteTokenKeepingSession() async throws {
    try await deleteOwnDeviceToken(authSignOut: {}, passThroughDeadSession: true)
  }

  /// The server keeps the public key and marks it retired, so old messages still open.
  private func retirePublishedKey() async throws {
    guard let user = cachedUser, let identity = try? DeviceKeyStore.load(userId: user) else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    try await run { client in
      try await client.from("device_keys")
        .update(DeviceKeyRetire(retiredAt: stamp))
        .eq("id", value: identity.id.uuidString)
        .eq("user_id", value: user.uuidString)
        .execute()
    }
  }

  func dropExpiredSession() async {
    await stopSockets()
    DeviceTokenStore.clearDelete()
    await authSignOut()
    wipeAfterSignOut()
  }

  /// The saved device row is deleted while this session still matches `device_tokens_own`.
  /// Zero rows from that saved token leave the session in place. A newer unsaved token may
  /// delete nothing. A token with no recorded save is deleted on a best-effort basis, and
  /// a miss or a network error does not block sign-out.
  private func deleteTokenThenSignOut() async throws {
    try await deleteOwnDeviceToken(authSignOut: { await self.authSignOut() })
  }

  private func deleteOwnDeviceToken(
    authSignOut: @escaping () async -> Void = {},
    blocked: AppError = .signOutBlocked,
    passThroughDeadSession: Bool = false
  ) async throws {
    DeviceTokenStore.clearDelete()
    if deviceToken?.isEmpty != false {
      deviceToken = DeviceTokenStore.load().token
    }
    let stored = DeviceTokenStore.load()
    let saveSucceeded = cachedUser.map { stored.saveSucceeded(for: $0.uuidString) } ?? false
    let savedToken = stored.savedToken
    do {
      try await DeviceTokenSignOut.perform(
        current: deviceToken,
        saved: savedToken,
        saveSucceeded: saveSucceeded,
        delete: { token in
          let count = try await self.deletedDeviceTokenCount(token)
          if token == savedToken, count > 0 {
            var record = DeviceTokenStore.load()
            record.removedFromAccount()
            record.savedUserId = nil
            record.savedToken = nil
            DeviceTokenStore.save(record)
          }
          return count
        },
        authSignOut: authSignOut
      )
    } catch {
      PushLog.deleteFailed(error)
      if passThroughDeadSession, ChatSignOut.continues(after: error) {
        throw error
      }
      throw blocked
    }
    deviceToken = nil
  }

  private func authSignOut() async {
    if let client {
      try? await client.auth.signOut()
    }
  }

  private func deletedDeviceTokenCount(_ token: String) async throws -> Int {
    guard let client, let user = cachedUser, !token.isEmpty else {
      throw DeviceTokenSignOut.Failure.removedNoRows
    }
    let response: PostgrestResponse<[DeviceTokenIdentity]> = try await client
      .from("device_tokens")
      .delete(returning: .representation)
      .eq("user_id", value: user.uuidString)
      .eq("token", value: token)
      .execute()
    return response.value.count
  }

  private func wipeAfterSignOut() {
    // supabase-swift skips signOut when the access token is already gone, and it never deletes the
    // PKCE code verifier. Wipe both so the next launch cannot revive a dead session or an old link.
    AuthStorageReset.clear()
    if let cachedUser {
      CacheStore.deleteAll()
      DeviceKeyStore.delete(userId: cachedUser)
      PartnerKeyMemory.clear(userId: cachedUser)
    }
    cachedUser = nil
    chatMaterials = nil
    var record = DeviceTokenStore.load()
    record.removedFromAccount()
    DeviceTokenStore.save(record)
    DeviceTokenStore.clearDelete()
  }

  func membership() async throws -> MembershipKind {
    guard let context = try await loadContext() else { return .none }
    return try await eligibility(context)
  }

  func createCouple(_ draft: CoupleDraft) async throws {
    if let issue = Validation.couple(draft) { throw issue }
    let params = CreateCoupleParams(
      pSelfName: draft.selfName, pPartnerName: draft.partnerName, pWeekday: draft.weekday,
      pLocalTime: draft.localTime, pTimezone: draft.timezone, pDurationMinutes: draft.durationMinutes
    )
    try await run { client in
      try await client.rpc("create_couple", params: params).execute()
    }
    chatMaterials = nil
  }

  func createInvite() async throws -> String {
    guard let context = try await loadContext() else { throw AppError.notAuthenticated }
    let members: [MemberRow] = try await rows("couple_members", eq: ("couple_id", context.couple.id.uuidString))
    if members.count >= 2 { throw AppError.coupleFull }
    let token = InviteRules.makeToken()
    try await run { client in
      try await client.from("couple_invites")
        .update(RevokeInvite(revokedAt: ISO8601DateFormatter().string(from: Date())))
        .eq("couple_id", value: context.couple.id.uuidString)
        .is("redeemed_at", value: nil)
        .is("revoked_at", value: nil)
        .execute()
      try await client.from("couple_invites").insert(NewInvite(
        coupleId: context.couple.id,
        createdBy: context.userId,
        tokenHash: InviteRules.hash(token),
        expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 86_400))
      )).execute()
    }
    return token
  }

  func redeem(token: String, replaceEmpty: Bool) async throws {
    guard let extracted = InviteRules.token(from: token) else { throw AppError.invalidInvite }
    try await run { client in
      try await client.rpc("redeem_couple_invite", params: RedeemParams(pToken: extracted, pReplaceEmpty: replaceEmpty)).execute()
    }
    chatMaterials = nil
    await notify("inviteAccepted")
  }

  func syncLanguage(_ code: String) async {
    guard code == "en" || code == "he" else { return }
    guard let client, let user = cachedUser else { return }
    let row = ProfileLanguage(
      userId: user,
      lang: code,
      updatedAt: ISO8601DateFormatter().string(from: Date())
    )
    var lastError: Error?
    for _ in 0..<2 {
      do {
        try await client.from("profiles").upsert(row, onConflict: "user_id").execute()
        return
      } catch {
        lastError = error
      }
    }
    if let lastError { LanguageLog.saveFailed(lastError) }
  }

  func registerDevice(token: String) async {
    var record = DeviceTokenStore.load()
    record.received(token)
    DeviceTokenStore.save(record)
    deviceToken = token
    await uploadDeviceToken()
  }

  /// The APNs callback can arrive before the session exists. The token stays
  /// on disk until the upsert succeeds, and the next launch or sign-in retries it.
  private func uploadDeviceToken() async {
    DeviceTokenStore.clearDelete()
    let stored = DeviceTokenStore.load()
    guard stored.awaitingSave, let token = stored.token else { return }
    deviceToken = token
    guard let user = cachedUser else { return }
    guard AppConfig.pushEnabled else { return }
    guard let client else {
      PushLog.saveFailed("Supabase client is not configured")
      return
    }
    let environment = AppConfig.pushSandbox ? "sandbox" : "production"
    let row = DeviceTokenEnvRow(userId: user, token: token, platform: "ios", environment: environment)
    do {
      try await client.from("device_tokens").upsert(row, onConflict: "user_id,token").execute()
      markTokenSaved(token, userId: user)
    } catch {
      switch DeviceTokenSave.afterFailure(error, attemptedPlain: false) {
      case .upsertPlain:
        await uploadDeviceTokenWithoutEnvironment(user: user, token: token)
      case .giveUp:
        PushLog.saveFailed(error)
      }
    }
  }

  private func uploadDeviceTokenWithoutEnvironment(user: UUID, token: String) async {
    guard let client else {
      PushLog.saveFailed("Supabase client is not configured")
      return
    }
    let row = DeviceTokenRow(userId: user, token: token, platform: "ios")
    do {
      try await client.from("device_tokens").upsert(row, onConflict: "user_id,token").execute()
      markTokenSaved(token, userId: user)
    } catch {
      PushLog.saveFailed(error)
    }
  }

  /// `userId` is the account the upsert was sent for, captured before the request.
  private func markTokenSaved(_ token: String, userId: UUID) {
    var current = DeviceTokenStore.load()
    current.saved(for: userId.uuidString, token: token)
    DeviceTokenStore.save(current)
  }

  func notify(_ kind: String) async {
    guard let client else { return }
    do {
      let _: PushAck = try await client.functions.invoke(
        "send-push",
        options: FunctionInvokeOptions(body: PushKindBody(kind: kind))
      )
    } catch {
      PushFailureLog.record(error)
    }
  }

  func setOffline(_ offline: Bool) {}

  func injectPartnerMood() async {}

  func preferences() -> PushPreferences {
    guard let cachedUser, let data = UserDefaults.standard.data(forKey: "prefs-\(cachedUser.uuidString)"),
          let prefs = try? JSONDecoder().decode(PushPreferences.self, from: data) else { return .allOn }
    return prefs
  }

  func savePreferences(_ preferences: PushPreferences) async {
    guard let cachedUser, let data = try? JSONEncoder().encode(preferences) else { return }
    UserDefaults.standard.set(data, forKey: "prefs-\(cachedUser.uuidString)")
    guard let client else { return }
    _ = try? await client.from("notification_preferences").upsert(
      PreferenceRow(userId: cachedUser, preferences: preferences)
    ).execute()
  }

  func unlink() async throws {
    let closed = try await run { client in
      let response: PostgrestResponse<[UUID]> = try await client.rpc("leave_couple").execute()
      return response.value
    }
    chatMaterials = nil
    await forgetPhotos(closed)
  }

  func takeSpaceClosed() async -> Bool {
    guard let client, let user = cachedUser else { return false }
    struct ClosureRow: Decodable {
      var userId: UUID
      enum CodingKeys: String, CodingKey { case userId = "user_id" }
    }
    do {
      let response: PostgrestResponse<[ClosureRow]> = try await client
        .from("space_closures")
        .select("user_id")
        .eq("user_id", value: user.uuidString)
        .execute()
      guard response.value.isEmpty == false else { return false }
      _ = try? await client.from("space_closures").delete().eq("user_id", value: user.uuidString).execute()
      return true
    } catch {
      return false
    }
  }

  func deleteAccount() async throws {
    await stopSockets()
    // The row has to go before delete_my_account, while this login still matches device_tokens_own.
    try await deleteOwnDeviceToken(blocked: .accountDeleteBlocked)
    _ = try await run { client in
      let response: PostgrestResponse<[UUID]> = try await client.rpc("delete_my_account").execute()
      return response.value
    }
    // The login is already gone, so /auth/v1/user rejects this JWT. The
    // sweep deletes the photos and clears closed_couples. Leave still
    // calls the function, because that login remains.
    await dropExpiredSession()
  }

  func retryClosedPhotos() async {
    guard client != nil else { return }
    let closed = try? await run { client in
      let response: PostgrestResponse<[UUID]> = try await client.rpc("closed_couple_ids").execute()
      return response.value
    }
    await forgetPhotos(closed ?? [])
  }

  private func forgetPhotos(_ coupleIds: [UUID]) async {
    do {
      try await deleteCouplePhotos(coupleIds)
    } catch {
      return
    }
  }

  func partnerKeyNotice() -> String? {
    partnerKeyNoticeText
  }

  func messages() async throws -> [ChatLine] {
    let context: LiveContext?
    do {
      context = try await loadContext()
    } catch let error as AppError where error == .sessionExpired || error == .notAuthenticated {
      return []
    }
    guard let context else { return [] }
    let identity = try await publishDeviceKey(userId: context.userId, reason: .refresh)
    await watchChat(coupleId: context.couple.id)
    await watchKeys(userId: context.userId)
    let rows = try await chatRows(coupleId: context.couple.id)
    let keys = try await loadDeviceKeys(
      coupleId: context.couple.id, senderKeys: rows.map(\.senderPublicKey)
    )
    let partnerKeys = keys
      .filter { $0.userId != context.userId && $0.retiredAt == nil }
      .map(\.publicKey)
      .sorted()
    if PartnerKeyMemory.remember(userId: context.userId, current: partnerKeys) {
      partnerKeyNoticeText = L10n.chatKeyChanged
    }
    chatMaterials = ChatMaterials(context: context, identity: identity, keys: keys)
    await sweepChatPhotos()
    let fresh = (try? await chatRows(coupleId: context.couple.id)) ?? rows
    let retired = DeviceKeyStore.retired(userId: context.userId)
    let lines = fresh.map { row in
      chatLine(row, identity: identity, retired: retired, userId: context.userId, keys: keys)
    }
    return ChatWindow.chronological(lines)
  }

  func sendMessage(_ text: String, id: UUID) async throws -> ChatLine {
    try await writeMessage(text, id: id, allowRefresh: true)
  }

  func chatTargets(keys: [DeviceKeyRow], userId: UUID, identity: ChatIdentity) -> [ChatTarget] {
    let parsed: [(id: UUID, userId: UUID, publicKey: Data, createdAt: Date, retired: Bool)] = keys.compactMap { key in
      guard let raw = ChatCoding.data(key.publicKey), raw.count == 32 else { return nil }
      return (key.id, key.userId, raw, APIDate.parse(key.createdAt) ?? .distantPast, key.retiredAt != nil)
    }
    return ChatRecipients.choose(senderUserId: userId, senderKeyId: identity.id, keys: parsed)
  }

  func decrypted(
    _ row: ChatMessageRow, identity: ChatIdentity, retired: [ChatIdentity], userId: UUID, keys: [DeviceKeyRow]
  ) -> String? {
    let published = keys.compactMap { key -> (userId: UUID, publicKey: Data)? in
      guard let raw = ChatCoding.data(key.publicKey) else { return nil }
      return (key.userId, raw)
    }
    guard let sender = ChatCoding.data(row.senderPublicKey),
          SenderKey.trusted(sender: sender, senderUserId: row.senderUserId, keys: published) else { return nil }
    let envelopes = row.envelopes.compactMap { wire -> ChatEnvelope? in
      guard let box = ChatCoding.data(wire.box) else { return nil }
      return ChatEnvelope(keyId: wire.keyId, box: box)
    }
    return ChatHistory.open(
      envelopes: envelopes, current: identity, retired: retired, messageId: row.id,
      senderUserId: row.senderUserId, recipientUserId: userId, senderPublic: sender
    )
  }

  /// Reloads the keychain inside the gate, so a call that waited cannot publish the key the previous call just replaced.
  func publishDeviceKey(userId: UUID, reason: KeyRotation.Reason) async throws -> ChatIdentity {
    try await publishGate.run { @MainActor in
      try await self.publishDeviceKeyOnce(userId: userId, reason: reason)
    }
  }

  private func publishDeviceKeyOnce(userId: UUID, reason: KeyRotation.Reason) async throws -> ChatIdentity {
    let identity = try DeviceKeyStore.loadOrCreate(userId: userId)
    let encoded = ChatCoding.text(identity.publicKey)
    let existing = try await ownDeviceKey(userId: userId, publicKey: encoded)
    let hasRow = existing != nil
    let retired = existing?.retiredAt != nil
    let activeCount = (hasRow && retired == false) ? 0 : try await activeKeyCount(userId: userId)
    let now = Date()
    let decision = try KeyRotation.enforce(KeyRotation.step(
      hasRow: hasRow, retired: retired, activeCount: activeCount,
      retiredAt: APIDate.parse(existing?.retiredAt), now: now, reason: reason
    ), reason: reason)
    switch decision {
    case .keep, .hold:
      return identity
    case .publish:
      let fresh = (hasRow && retired) ? ChatIdentity.generate() : identity
      try await KeyPublish.stage(
        insert: { try await self.insertDeviceKey(fresh, userId: userId) },
        commit: {
          guard fresh.id != identity.id else { return }
          try DeviceKeyStore.commit(current: fresh, retiring: identity, userId: userId)
        }
      )
      return fresh
    }
  }

  private func ownDeviceKey(userId: UUID, publicKey: String) async throws -> DeviceKeyRow? {
    let rows: [DeviceKeyRow] = try await run { client in
      let response: PostgrestResponse<[DeviceKeyRow]> = try await client
        .from("device_keys")
        .select()
        .eq("user_id", value: userId.uuidString)
        .eq("public_key", value: publicKey)
        .limit(1)
        .execute()
      return response.value
    }
    return rows.first
  }

  private func activeKeyCount(userId: UUID) async throws -> Int {
    let rows: [DeviceKeyRow] = try await run { client in
      let response: PostgrestResponse<[DeviceKeyRow]> = try await client
        .from("device_keys")
        .select()
        .eq("user_id", value: userId.uuidString)
        .is("retired_at", value: nil)
        .execute()
      return response.value
    }
    return rows.count
  }

  private func insertDeviceKey(_ identity: ChatIdentity, userId: UUID) async throws {
    let row = DeviceKeyInsert(
      id: identity.id, userId: userId, publicKey: ChatCoding.text(identity.publicKey)
    )
    try await run { client in
      try await client.from("device_keys").insert(row).execute()
    }
  }

  func chatRows(coupleId: UUID) async throws -> [ChatMessageRow] {
    try await run { client in
      let response: PostgrestResponse<[ChatMessageRow]> = try await client
        .from("chat_messages")
        .select()
        .eq("couple_id", value: coupleId.uuidString)
        .order("created_at", ascending: false)
        .limit(ChatWindow.limit)
        .execute()
      return response.value
    }
  }

  func loadDeviceKeys(coupleId: UUID, senderKeys: [String] = []) async throws -> [DeviceKeyRow] {
    let members: [MemberIdRow] = try await run { client in
      let response: PostgrestResponse<[MemberIdRow]> = try await client
        .from("couple_members")
        .select("user_id")
        .eq("couple_id", value: coupleId.uuidString)
        .execute()
      return response.value
    }
    let ids = members.map(\.userId.uuidString)
    if ids.isEmpty { return [] }
    let active: [DeviceKeyRow] = try await run { client in
      let response: PostgrestResponse<[DeviceKeyRow]> = try await client
        .from("device_keys")
        .select()
        .in("user_id", values: ids.map { $0 as any PostgrestFilterValue })
        .is("retired_at", value: nil)
        .order("created_at", ascending: false)
        .execute()
      return response.value
    }
    let known = Set(active.map(\.publicKey))
    let missing = Array(Set(senderKeys).subtracting(known))
    guard missing.isEmpty == false else { return active }
    let retired: [DeviceKeyRow] = try await run { client in
      let response: PostgrestResponse<[DeviceKeyRow]> = try await client
        .from("device_keys")
        .select()
        .in("user_id", values: ids.map { $0 as any PostgrestFilterValue })
        .in("public_key", values: missing.map { $0 as any PostgrestFilterValue })
        .order("created_at", ascending: false)
        .limit(ChatWindow.retiredKeys)
        .execute()
      return response.value
    }
    var seen = Set(active.map(\.id))
    return active + retired.filter { seen.insert($0.id).inserted }
  }

  private func deleteCouplePhotos(_ coupleIds: [UUID]) async throws {
    guard coupleIds.isEmpty == false else { return }
    try await run { client in
      let _: PhotoDeleteAck = try await client.functions.invoke(
        "delete-couple-photos",
        options: FunctionInvokeOptions(body: PhotoDeleteRequest(coupleIds: coupleIds))
      )
    }
  }

  func run<T>(_ body: (SupabaseClient) async throws -> T) async throws -> T {
    guard let client else { throw AppError.unavailable }
    do {
      return try await body(client)
    } catch let error as AppError {
      throw error
    } catch {
      throw ErrorMap.app(error)
    }
  }

  private func rows<T: Decodable>(_ table: String, eq: (String, String)? = nil) async throws -> [T] {
    try await run { client in
      var query = client.from(table).select()
      if let eq { query = query.eq(eq.0, value: eq.1) }
      let response: PostgrestResponse<[T]> = try await query.execute()
      return response.value
    }
  }

  func loadContext() async throws -> LiveContext? {
    guard let client else { throw AppError.unavailable }
    let session: Session
    do { session = try await client.auth.session } catch { throw ErrorMap.app(error) }
    cachedUser = session.user.id
    let memberships: [MemberRow] = try await rows("couple_members", eq: ("user_id", session.user.id.uuidString))
    guard let mine = memberships.first else { return nil }
    let couples: [CoupleRow] = try await rows("couples", eq: ("id", mine.coupleId.uuidString))
    guard let couple = couples.first else { return nil }
    let members: [MemberRow] = try await rows("couple_members", eq: ("couple_id", couple.id.uuidString))
    return LiveContext(client: client, userId: session.user.id, mine: mine, couple: couple, members: members)
  }

  private func eligibility(_ context: LiveContext) async throws -> MembershipKind {
    let dates: [IdRow] = try await run { client in
      let response: PostgrestResponse<[IdRow]> = try await client.from("dates").select("id, status").eq("couple_id", value: context.couple.id.uuidString).execute()
      return response.value
    }
    let nonDraft = dates.filter { $0.status != "draft" }.count
    let ids = dates.map(\.id.uuidString)
    var plans = 0
    var notes = 0
    if !ids.isEmpty {
      let planRows: [IdRow] = try await run { client in
        let response: PostgrestResponse<[IdRow]> = try await client.from("private_date_plans").select("date_id").in("date_id", values: ids.map { $0 as any PostgrestFilterValue }).execute()
        return response.value
      }
      let noteRows: [IdRow] = try await run { client in
        let response: PostgrestResponse<[IdRow]> = try await client.from("memory_notes").select("id").in("date_id", values: ids.map { $0 as any PostgrestFilterValue }).execute()
        return response.value
      }
      plans = planRows.count
      notes = noteRows.count
    }
    return InviteRules.canLeaveSolo(
      memberCount: context.members.count, nonDraftCount: nonDraft, planCount: plans, noteCount: notes
    ) ? .emptySolo : .kept
  }
}

struct LiveContext {
  var client: SupabaseClient
  var userId: UUID
  var mine: MemberRow
  var couple: CoupleRow
  var members: [MemberRow]
}

struct IdRow: Decodable {
  var id: UUID = UUID()
  var status: String?
  enum CodingKeys: String, CodingKey {
    case id
    case status
    case dateId = "date_id"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let id = try container.decodeIfPresent(UUID.self, forKey: .id) {
      self.id = id
    } else if let dateId = try container.decodeIfPresent(UUID.self, forKey: .dateId) {
      self.id = dateId
    } else {
      self.id = UUID()
    }
    status = try container.decodeIfPresent(String.self, forKey: .status)
  }
}

struct RevokeInvite: Encodable {
  var revokedAt: String
  enum CodingKeys: String, CodingKey { case revokedAt = "revoked_at" }
}

struct NewInvite: Encodable {
  var coupleId: UUID
  var createdBy: UUID
  var tokenHash: String
  var expiresAt: String
  enum CodingKeys: String, CodingKey {
    case coupleId = "couple_id"
    case createdBy = "created_by"
    case tokenHash = "token_hash"
    case expiresAt = "expires_at"
  }
}

struct DeviceTokenIdentity: Decodable {
  var userId: UUID
  var token: String
  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case token
  }
}

struct DeviceTokenRow: Encodable {
  var userId: UUID
  var token: String
  var platform: String
  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case token
    case platform
  }
}

struct DeviceTokenEnvRow: Encodable {
  var userId: UUID
  var token: String
  var platform: String
  var environment: String
  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case token
    case platform
    case environment
  }
}

struct PushKindBody: Encodable {
  var kind: String
}

private struct PhotoDeleteRequest: Encodable {
  var coupleIds: [UUID]
}

private struct PhotoDeleteAck: Decodable {
  var deleted: Int
}

struct PushAck: Decodable {
  var decision: String?
}

enum PushFailureLog {
  private static let logger = Logger(subsystem: "com.orrgoren.justus", category: "push")
  /// Tests set this so a failed notify is visible. The send itself still succeeds.
  static var handler: (@Sendable (String) -> Void)?

  static func record(_ error: Error) {
    _ = error
    logger.error("send-push failed")
    handler?("send-push failed")
  }
}

enum AuthStorageReset {
  static let sessionKey = "supabase.auth.token"
  static let verifierKey = "supabase.auth.token-code-verifier"
  static let legacySessionKey = "supabase.session"

  static func clear() {
    let storage = KeychainLocalStorage()
    try? storage.remove(key: sessionKey)
    try? storage.remove(key: verifierKey)
    try? storage.remove(key: legacySessionKey)
  }

  static func clearVerifier() {
    try? KeychainLocalStorage().remove(key: verifierKey)
  }
}

struct ProfileLanguage: Encodable {
  var userId: UUID
  var lang: String
  var updatedAt: String

  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case lang
    case updatedAt = "updated_at"
  }
}

enum LanguageLog {
  private static let logger = Logger(subsystem: "com.orrgoren.justus", category: "language")

  static func saveFailed(_ error: Error) {
    logger.error("profile language save failed: \(String(describing: error), privacy: .private)")
  }
}

struct PreferenceRow: Encodable {
  var userId: UUID
  var partnerMood: Bool
  var planReady: Bool
  var inviteAccepted: Bool
  var weeklyReminder: Bool

  init(userId: UUID, preferences: PushPreferences) {
    self.userId = userId
    partnerMood = preferences.partnerMood
    planReady = preferences.planReady
    inviteAccepted = preferences.inviteAccepted
    weeklyReminder = preferences.weeklyReminder
  }

  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case partnerMood = "partner_mood"
    case planReady = "plan_ready"
    case inviteAccepted = "invite_accepted"
    case weeklyReminder = "weekly_reminder"
  }
}
