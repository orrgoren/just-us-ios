import Foundation
import Supabase

@MainActor
final class LiveBackend: DateBackend {
  var onRemoteChange: (@MainActor () -> Void)?
  let client: SupabaseClient?
  var watchTask: Task<Void, Never>?
  private var cachedUser: UUID?
  private var deviceToken: String?

  init() {
    guard let url = URL(string: AppConfig.supabaseURL), AppConfig.supabaseURL.hasPrefix("https://"), !AppConfig.anonKey.isEmpty else {
      client = nil
      return
    }
    client = SupabaseClient(supabaseURL: url, supabaseKey: AppConfig.anonKey)
  }

  func sendCode(email: String) async throws {
    guard let normalized = Validation.email(email) else { throw AppError.invalid(.email) }
    guard let redirect = AuthCallback.redirect else { throw AppError.server(code: "redirect") }
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
    return try await run { client in
      let response = try await client.auth.verifyOTP(email: normalized, token: digits, type: .email)
      guard let session = response.session else { throw AppError.notAuthenticated }
      self.cachedUser = session.user.id
      return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
    }
  }

  func session(from url: URL) async throws -> SessionUser {
    try await run { client in
      let session = try await client.auth.session(from: url)
      self.cachedUser = session.user.id
      return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
    }
  }

  func signInWithApple(idToken: String, nonce: String) async throws -> SessionUser {
    try await run { client in
      let session = try await client.auth.signInWithIdToken(
        credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
      )
      self.cachedUser = session.user.id
      return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
    }
  }

  func restore() async throws -> SessionUser? {
    guard let client else { return nil }
    do {
      let session = try await client.auth.session
      cachedUser = session.user.id
      return SessionUser(id: session.user.id, email: session.user.email, displayHint: nil)
    } catch {
      return nil
    }
  }

  func signOut() async {
    watchTask?.cancel()
    if let client, let cachedUser, let deviceToken {
      _ = try? await client.from("device_tokens").delete()
        .eq("user_id", value: cachedUser.uuidString)
        .eq("token", value: deviceToken)
        .execute()
    }
    if let client {
      try? await client.auth.signOut()
    }
    if let cachedUser { CacheStore.deleteAll() }
    cachedUser = nil
    deviceToken = nil
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
    deviceToken = token
    guard AppConfig.pushEnabled, let user = cachedUser, let client else { return }
    let environment = AppConfig.pushSandbox ? "sandbox" : "production"
    let withEnvironment = DeviceTokenEnvRow(userId: user, token: token, platform: "ios", environment: environment)
    do {
      try await client.from("device_tokens").upsert(withEnvironment, onConflict: "user_id,token").execute()
    } catch {
      let row = DeviceTokenRow(userId: user, token: token, platform: "ios")
      _ = try? await client.from("device_tokens").upsert(row, onConflict: "user_id,token").execute()
    }
  }

  func notify(_ kind: String) async {
    guard let client else { return }
    do {
      let _: PushAck = try await client.functions.invoke(
        "send-push",
        options: FunctionInvokeOptions(body: PushKindBody(kind: kind))
      )
    } catch {
      return
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
    try await run { client in
      try await client.rpc("leave_couple").execute()
    }
  }

  func deleteAccount() async throws {
    try await run { client in
      try await client.rpc("delete_my_account").execute()
    }
    await signOut()
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

struct PushAck: Decodable {
  var decision: String?
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
