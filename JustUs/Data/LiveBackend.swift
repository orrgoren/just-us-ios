import Foundation
import os
import Supabase

@MainActor
final class LiveBackend: DateBackend {
  var onRemoteChange: (@MainActor () -> Void)?
  let client: SupabaseClient?
  var watchTask: Task<Void, Never>?
  var chatWatch: Task<Void, Never>?
  private var cachedUser: UUID?
  private var deviceToken: String?
  private var partnerKeyNoticeText: String?

  init() {
    deviceToken = DeviceTokenStore.load().token
    guard let url = URL(string: AppConfig.supabaseURL), AppConfig.supabaseURL.hasPrefix("https://"), !AppConfig.anonKey.isEmpty else {
      client = nil
      return
    }
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
    watchTask?.cancel()
    chatWatch?.cancel()
    try await retirePublishedKey()
    try await deleteTokenThenSignOut()
    wipeAfterSignOut()
  }

  /// The server keeps the public key and marks it retired, so old messages still open.
  private func retirePublishedKey() async throws {
    guard let user = cachedUser, let identity = try? DeviceKeyStore.load(userId: user) else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    do {
      try await run { client in
        try await client.from("device_keys")
          .update(DeviceKeyRetire(retiredAt: stamp))
          .eq("id", value: identity.id.uuidString)
          .eq("user_id", value: user.uuidString)
          .execute()
      }
    } catch {
      throw AppError.signOutBlocked
    }
  }

  func dropExpiredSession() async {
    watchTask?.cancel()
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
    blocked: AppError = .signOutBlocked
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
    await notify("inviteAccepted")
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
    watchTask?.cancel()
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
    let identity = try DeviceKeyStore.loadOrCreate(userId: context.userId)
    try await publishDeviceKey(identity, userId: context.userId)
    watchChat(coupleId: context.couple.id)
    let keys = try await loadDeviceKeys(coupleId: context.couple.id)
    let partnerKeys = keys
      .filter { $0.userId != context.userId && $0.retiredAt == nil }
      .map(\.publicKey)
      .sorted()
    if PartnerKeyMemory.remember(userId: context.userId, current: partnerKeys) {
      partnerKeyNoticeText = L10n.chatKeyChanged
    }
    let rows: [ChatMessageRow] = try await run { client in
      let response: PostgrestResponse<[ChatMessageRow]> = try await client
        .from("chat_messages")
        .select()
        .eq("couple_id", value: context.couple.id.uuidString)
        .order("created_at", ascending: false)
        .limit(ChatWindow.limit)
        .execute()
      return response.value
    }
    let lines = rows.map { row in
      let text = decrypted(row, identity: identity, userId: context.userId, keys: keys)
      return ChatLine(
        id: row.id, senderUserId: row.senderUserId, text: text ?? L10n.chatUnreadable,
        createdAt: APIDate.parse(row.createdAt) ?? Date(), mine: row.senderUserId == context.userId,
        unreadable: text == nil
      )
    }
    return ChatWindow.chronological(lines)
  }

  func sendMessage(_ text: String) async throws {
    let clear = try ChatText.normalized(text)
    guard let context = try await loadContext() else { throw AppError.saveFailed }
    guard context.members.contains(where: { $0.userId != context.userId }) else { throw AppError.partnerNotReady }
    let identity = try DeviceKeyStore.loadOrCreate(userId: context.userId)
    try await publishDeviceKey(identity, userId: context.userId)
    let keys = try await loadDeviceKeys(coupleId: context.couple.id)
    let targets = chatTargets(keys: keys.filter { $0.retiredAt == nil }, userId: context.userId, identity: identity)
    guard targets.contains(where: { $0.userId != context.userId }) else { throw AppError.partnerNotReady }
    let messageId = UUID()
    let envelopes = try ChatCrypto.seal(
      text: clear, messageId: messageId, senderUserId: context.userId, from: identity, to: targets
    )
    guard envelopes.contains(where: { $0.keyId != identity.id }) else { throw AppError.partnerNotReady }
    let row = ChatInsert(
      id: messageId, coupleId: context.couple.id, senderUserId: context.userId,
      senderPublicKey: ChatCoding.text(identity.publicKey),
      envelopes: envelopes.map { EnvelopeWire(keyId: $0.keyId, box: ChatCoding.text($0.box)) }
    )
    try await run { client in
      try await client.from("chat_messages").insert(row).execute()
    }
    await notify("chatMessage")
  }

  private func chatTargets(keys: [DeviceKeyRow], userId: UUID, identity: ChatIdentity) -> [ChatTarget] {
    let parsed: [(id: UUID, userId: UUID, publicKey: Data, createdAt: Date, retired: Bool)] = keys.compactMap { key in
      guard let raw = ChatCoding.data(key.publicKey), raw.count == 32 else { return nil }
      return (key.id, key.userId, raw, APIDate.parse(key.createdAt) ?? .distantPast, key.retiredAt != nil)
    }
    return ChatRecipients.choose(senderUserId: userId, senderKeyId: identity.id, keys: parsed)
  }

  private func decrypted(
    _ row: ChatMessageRow, identity: ChatIdentity, userId: UUID, keys: [DeviceKeyRow]
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
    return try? ChatCrypto.open(
      envelopes: envelopes, identity: identity, messageId: row.id,
      senderUserId: row.senderUserId, recipientUserId: userId, senderPublic: sender
    )
  }

  private func publishDeviceKey(_ identity: ChatIdentity, userId: UUID) async throws {
    let encoded = ChatCoding.text(identity.publicKey)
    let existing: [DeviceKeyRow] = try await run { client in
      let response: PostgrestResponse<[DeviceKeyRow]> = try await client
        .from("device_keys")
        .select()
        .eq("user_id", value: userId.uuidString)
        .eq("public_key", value: encoded)
        .limit(1)
        .execute()
      return response.value
    }
    if existing.isEmpty == false { return }
    let row = DeviceKeyInsert(id: identity.id, userId: userId, publicKey: encoded)
    try await run { client in
      try await client.from("device_keys").insert(row).execute()
    }
  }

  private func loadDeviceKeys(coupleId: UUID) async throws -> [DeviceKeyRow] {
    let members: [MemberIdRow] = try await run { client in
      let response: PostgrestResponse<[MemberIdRow]> = try await client
        .from("couple_members")
        .select("user_id")
        .eq("couple_id", value: coupleId.uuidString)
        .execute()
      return response.value
    }
    let ids = members.map(\.userId.uuidString)
    return try await run { client in
      let response: PostgrestResponse<[DeviceKeyRow]> = try await client
        .from("device_keys")
        .select()
        .in("user_id", values: ids.map { $0 as any PostgrestFilterValue })
        .execute()
      return response.value
    }
  }

  private func watchChat(coupleId: UUID) {
    chatWatch?.cancel()
    guard let client else { return }
    chatWatch = Task { [weak self] in
      let channel = client.channel("chat-\(coupleId.uuidString)")
      // A Realtime DELETE carries the row id only. Reload the couple's messages
      // instead of trying to read a payload that is not there.
      let stream = channel.postgresChange(
        AnyAction.self, schema: "public", table: "chat_messages",
        filter: .eq("couple_id", value: coupleId.uuidString)
      )
      do { try await channel.subscribeWithError() } catch { return }
      for await _ in stream {
        if Task.isCancelled { break }
        await self?.onRemoteChange?()
      }
    }
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

  private func run<T>(_ body: (SupabaseClient) async throws -> T) async throws -> T {
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
