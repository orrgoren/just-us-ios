import Foundation
import Supabase

extension LiveBackend {
  func ritual() async throws -> RitualSnapshot? {
    guard let context = try await loadContext() else { return nil }
    let completed = try await completedCount(context)
    let active = try await activeDate(context)
    if let active {
      watchMoods(dateId: active.id)
    }
    return try await makeRitual(context: context, completed: completed, active: active)
  }

  func setMood(_ mood: MoodKey) async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    try await runWrite { client in
      try await client.from("mood_votes").upsert(
        MoodWrite(dateId: date.id, userId: context.userId, mood: mood.rawValue),
        onConflict: "date_id,user_id"
      ).execute()
    }
    await notify("partnerMood")
  }

  func setPlace(_ choice: PlaceChoice) async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    guard date.plannerUserId == context.userId, date.status == .draft else { throw AppError.notPlanner }
    let completed = try await completedCount(context)
    let resolved = try Recommendation.resolve(completedCount: completed, choice: choice)
    try await runWrite { client in
      try await client.from("dates").update(PlacePatch(location: resolved.location.rawValue, locationIsOverride: resolved.isOverride))
        .eq("id", value: date.id.uuidString).eq("status", value: "draft").execute()
    }
  }

  func surprise(excluding: [String]) async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    guard date.plannerUserId == context.userId, date.status == .draft else { throw AppError.notPlanner }
    let votes: [MoodRow] = try await fetch("mood_votes", column: "date_id", value: date.id.uuidString)
    let recent: [RecentIdea] = try await runWrite { client in
      let response: PostgrestResponse<[RecentIdea]> = try await client.from("dates")
        .select("snapshot_idea_id").eq("couple_id", value: context.couple.id.uuidString)
        .eq("status", value: "completed").order("completed_at", ascending: false).limit(3).execute()
      return response.value
    }
    let moods = votes.compactMap { MoodKey(rawValue: $0.mood) }
    guard let idea = Recommendation.pick(
      ideas: IdeasCatalog.load(), location: date.location, moods: moods,
      recentIdeaIds: recent.compactMap(\.snapshotIdeaId), excludeIds: excluding
    ) else { throw AppError.missingPlan }
    let existing: [PlanRow] = try await fetch("private_date_plans", column: "date_id", value: date.id.uuidString)
    try await runWrite { client in
      try await client.from("private_date_plans").upsert(PlanWrite(
        dateId: date.id, ideaId: idea.id, privateNotes: existing.first?.privateNotes,
        preparedAt: ISO8601DateFormatter().string(from: Date())
      ), onConflict: "date_id").execute()
    }
  }

  func saveHint(teaser: String, outfit: String, notes: String) async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    guard let teaserValue = Validation.teaser(teaser), let outfitValue = Validation.teaser(outfit), Validation.note(notes) != nil else {
      throw AppError.invalid(.teaser)
    }
    try await runWrite { client in
      try await client.from("dates").update(HintPatch(
        publicTeaser: teaserValue.nilIfEmpty, outfitHint: outfitValue.nilIfEmpty
      )).eq("id", value: date.id.uuidString).eq("couple_id", value: context.couple.id.uuidString).execute()
      if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try await client.from("private_date_plans").update(NotesPatch(privateNotes: notes))
          .eq("date_id", value: date.id.uuidString).execute()
      }
    }
  }

  func saveDate(day: String, time: String, teaser: String, outfit: String, notes: String) async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    guard date.status == .draft, date.plannerUserId == context.userId else { throw AppError.notPlanner }
    let plans: [PlanRow] = try await fetch("private_date_plans", column: "date_id", value: date.id.uuidString)
    guard let ideaId = plans.first?.ideaId, let idea = IdeasCatalog.idea(ideaId, in: IdeasCatalog.load()), idea.loc == date.location else {
      throw AppError.missingPlan
    }
    _ = idea
    try await saveHint(teaser: teaser, outfit: outfit, notes: notes)
    let when = try ZonedTime.zonedLocalToUtc(date: day, time: time, timeZone: context.couple.timezone)
    try await runWrite { client in
      try await client.from("dates").update(SchedulePatch(
        scheduledAt: ISO8601DateFormatter().string(from: when), status: "scheduled"
      )).eq("id", value: date.id.uuidString).eq("status", value: "draft").execute()
    }
    await notify("planReady")
  }

  func reveal() async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    try await runWrite { client in
      try await client.from("dates").update(RevealPatch(revealedAt: ISO8601DateFormatter().string(from: Date())))
        .eq("id", value: date.id.uuidString).eq("couple_id", value: context.couple.id.uuidString)
        .eq("status", value: "scheduled").is("revealed_at", value: nil).execute()
    }
  }

  func skipWeek() async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    try await runWrite { client in
      try await client.from("dates").update(["status": "skipped"])
        .eq("id", value: date.id.uuidString).in("status", values: ["draft", "scheduled"].map { $0 as any PostgrestFilterValue }).execute()
    }
    try await ensureDraft()
  }

  func swapPlanner() async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context), date.status == .draft else {
      throw AppError.saveFailed
    }
    guard let other = context.members.first(where: { $0.userId != date.plannerUserId }) else { throw AppError.saveFailed }
    try await runWrite { client in
      try await client.from("private_date_plans").delete().eq("date_id", value: date.id.uuidString).execute()
      try await client.from("dates").update(PlannerPatch(plannerUserId: other.userId))
        .eq("id", value: date.id.uuidString).eq("status", value: "draft").execute()
    }
  }

  func reopen() async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context) else { throw AppError.saveFailed }
    try await runWrite { client in
      try await client.from("dates").update(["status": "draft"])
        .eq("id", value: date.id.uuidString).eq("status", value: "scheduled").is("revealed_at", value: nil).execute()
    }
  }

  func move(day: String, time: String) async throws {
    guard let context = try await loadContext(), let date = try await activeDate(context), date.status == .scheduled else {
      throw AppError.saveFailed
    }
    let when = try ZonedTime.zonedLocalToUtc(date: day, time: time, timeZone: context.couple.timezone)
    try await runWrite { client in
      try await client.from("dates").update(SchedulePatch(scheduledAt: ISO8601DateFormatter().string(from: when), status: "scheduled"))
        .eq("id", value: date.id.uuidString).eq("status", value: "scheduled").execute()
    }
  }

  func complete(note: String) async throws {
    guard let noteText = Validation.note(note), let context = try await loadContext(), let date = try await activeDate(context) else {
      throw AppError.invalid(.note)
    }
    try await runWrite { client in
      try await client.rpc("complete_date", params: CompleteParams(pDateId: date.id, pNote: noteText)).execute()
    }
  }

  func ensureDraft() async throws {
    guard let context = try await loadContext() else { throw AppError.notAuthenticated }
    try await runWrite { client in
      try await client.rpc("ensure_active_draft", params: CoupleIDParams(pCoupleId: context.couple.id)).execute()
    }
  }

  func memories() async throws -> [MemoryItem] {
    guard let context = try await loadContext() else { return [] }
    let rows: [MemoryDateRow] = try await runWrite { client in
      let response: PostgrestResponse<[MemoryDateRow]> = try await client.from("dates")
        .select("id, scheduled_at, location, completed_at, snapshot_title, snapshot_emoji, snapshot_summary, snapshot_idea_id, memory_photo_path, memory_notes(id, author_user_id, author_name, note)")
        .eq("couple_id", value: context.couple.id.uuidString).eq("status", value: "completed")
        .order("completed_at", ascending: false).execute()
      return response.value
    }
    var items: [MemoryItem] = []
    for (index, row) in rows.enumerated() {
      var jpeg: Data?
      var state: PhotoState = .empty
      if let path = row.memoryPhotoPath, !path.isEmpty {
        jpeg = try? await runWrite { client in
          try await client.storage.from("date-photos").download(path: path)
        }
        state = jpeg == nil ? .failed : .saved
      }
      let notes = (row.memoryNotes ?? []).map { note in
        let memberName = context.members.first { $0.userId == note.authorUserId }?.displayName
        let name = (note.authorName?.isEmpty == false ? note.authorName : nil) ?? memberName ?? ""
        return MemoryNote(
          id: note.id, authorUserId: note.authorUserId,
          authorName: name, note: note.note, mine: note.authorUserId == context.userId
        )
      }
      items.append(MemoryItem(
        id: row.id,
        title: catalogTitle(row),
        emoji: row.snapshotEmoji ?? "♥",
        summary: row.snapshotSummary,
        location: row.location == "out" ? .out : .home,
        when: APIDate.parse(row.completedAt) ?? APIDate.parse(row.scheduledAt) ?? Date(),
        number: rows.count - index,
        notes: notes,
        photoPath: row.memoryPhotoPath, photoJPEG: jpeg, photoState: state
      ))
    }
    return items
  }

  func saveNote(dateId: UUID, noteId: UUID?, text: String) async throws {
    guard let context = try await loadContext(), let note = Validation.note(text), !note.isEmpty else { throw AppError.invalid(.note) }
    if let noteId {
      try await runWrite { client in
        try await client.from("memory_notes").update(NotesBody(note: note))
          .eq("id", value: noteId.uuidString).eq("author_user_id", value: context.userId.uuidString).execute()
      }
    } else {
      try await runWrite { client in
        try await client.from("memory_notes").insert(NewNote(id: UUID(), dateId: dateId, authorUserId: context.userId, note: note)).execute()
      }
    }
  }

  func deleteNote(id: UUID) async throws {
    guard let context = try await loadContext() else { throw AppError.notAuthenticated }
    try await runWrite { client in
      try await client.from("memory_notes").delete().eq("id", value: id.uuidString)
        .eq("author_user_id", value: context.userId.uuidString).execute()
    }
  }

  func savePhoto(dateId: UUID, jpeg: Data) async throws {
    guard let context = try await loadContext() else { throw AppError.notAuthenticated }
    let path = "\(context.couple.id.uuidString.lowercased())/\(dateId.uuidString.lowercased()).jpg"
    var uploaded = false
    do {
      try await runWrite { client in
        try await client.storage.from("date-photos").upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
      }
      uploaded = true
      try await runWrite { client in
        try await client.rpc("set_memory_photo_path", params: PhotoPathParams(pDateId: dateId, pPath: path)).execute()
      }
    } catch {
      if PhotoSavePolicy.shouldDeleteObject(uploadSucceeded: uploaded, recordSucceeded: false), let client {
        _ = try? await client.storage.from("date-photos").remove(paths: [path])
      }
      throw ErrorMap.app(error)
    }
  }

  func settings() async throws -> SettingsSnapshot? {
    guard let context = try await loadContext() else { return nil }
    let invites: [InviteRow] = try await runWrite { client in
      let response: PostgrestResponse<[InviteRow]> = try await client.from("couple_invites").select("expires_at")
        .eq("couple_id", value: context.couple.id.uuidString).is("redeemed_at", value: nil).is("revoked_at", value: nil)
        .order("expires_at", ascending: false).limit(1).execute()
      return response.value
    }
    let partner = context.members.first { $0.userId != context.userId }
    return SettingsSnapshot(
      coupleId: context.couple.id,
      selfName: context.mine.displayName,
      partnerName: partner?.displayName ?? context.couple.inviteeName,
      partnerJoined: partner != nil,
      weekday: context.couple.weekday,
      localTime: APIDate.clock(context.couple.localTime),
      timezone: context.couple.timezone,
      durationMinutes: context.couple.durationMinutes,
      pendingInviteExpires: APIDate.parse(invites.first?.expiresAt),
      preferences: preferences()
    )
  }

  func saveSettings(_ settings: SettingsSnapshot) async throws {
    guard let context = try await loadContext() else { throw AppError.notAuthenticated }
    guard Validation.displayName(settings.selfName) != nil, Validation.displayName(settings.partnerName) != nil else {
      throw AppError.invalid(.name)
    }
    var patch = SettingsPatch(
      weekday: settings.weekday, localTime: settings.localTime, timezone: settings.timezone,
      durationMinutes: settings.durationMinutes, inviteeName: nil
    )
    if context.mine.memberIndex == 0 { patch.inviteeName = settings.partnerName }
    try await runWrite { client in
      try await client.from("couples").update(patch).eq("id", value: context.couple.id.uuidString).execute()
      try await client.from("couple_members").update(NamePatch(displayName: settings.selfName))
        .eq("user_id", value: context.userId.uuidString).execute()
      if let partner = context.members.first(where: { $0.userId != context.userId }) {
        try await client.from("couple_members").update(NamePatch(displayName: settings.partnerName))
          .eq("user_id", value: partner.userId.uuidString).execute()
      }
    }
    await savePreferences(settings.preferences)
  }

  private func runWrite<T>(_ body: (SupabaseClient) async throws -> T) async throws -> T {
    guard let context = try? await loadContext() else {
      throw AppError.notAuthenticated
    }
    do { return try await body(context.client) } catch let error as AppError {
      throw error
    } catch {
      throw ErrorMap.app(error)
    }
  }

  private func fetch<T: Decodable>(_ table: String, column: String, value: String) async throws -> [T] {
    try await runWrite { client in
      let response: PostgrestResponse<[T]> = try await client.from(table).select().eq(column, value: value).execute()
      return response.value
    }
  }

  private func completedCount(_ context: LiveContext) async throws -> Int {
    let rows: [IdRow] = try await fetch("dates", column: "couple_id", value: context.couple.id.uuidString)
    return rows.filter { $0.status == "completed" }.count
  }

  private func activeDate(_ context: LiveContext) async throws -> DateRow? {
    let rows: [DateRow] = try await runWrite { client in
      let response: PostgrestResponse<[DateRow]> = try await client.from("dates").select()
        .eq("couple_id", value: context.couple.id.uuidString).in("status", values: ["draft", "scheduled"].map { $0 as any PostgrestFilterValue }).limit(1).execute()
      return response.value
    }
    return rows.first
  }

  private func makeRitual(context: LiveContext, completed: Int, active: DateRow?) async throws -> RitualSnapshot {
    let partner = context.members.first { $0.userId != context.userId }
    var plan: FullPlan?
    var moods: [MoodVote] = []
    var dateCard: DateCard?
    if let active {
      let votes: [MoodRow] = try await fetch("mood_votes", column: "date_id", value: active.id.uuidString)
      moods = votes.compactMap { vote in
        guard let mood = MoodKey(rawValue: vote.mood) else { return nil }
        return MoodVote(userId: vote.userId, mood: mood)
      }
      let revealed = active.revealedAt != nil
      let isPlanner = active.plannerUserId == context.userId
      if isPlanner || revealed {
        let plans: [PlanRow] = try await fetch("private_date_plans", column: "date_id", value: active.id.uuidString)
        if let row = plans.first, let idea = IdeasCatalog.idea(row.ideaId, in: IdeasCatalog.load()) {
          plan = IdeasCatalog.plan(from: idea, notes: row.privateNotes)
        }
      }
      dateCard = card(from: active, context: context, completed: completed)
    }
    let view = RitualSnapshot(
      coupleId: context.couple.id,
      selfMember: MemberRef(userId: context.mine.userId, displayName: context.mine.displayName, memberIndex: context.mine.memberIndex),
      partner: partner.map { MemberRef(userId: $0.userId, displayName: $0.displayName, memberIndex: $0.memberIndex) },
      inviteeName: context.couple.inviteeName,
      completedCount: completed,
      weekday: context.couple.weekday,
      localTime: APIDate.clock(context.couple.localTime),
      timezone: context.couple.timezone,
      durationMinutes: context.couple.durationMinutes,
      date: dateCard, moods: moods,
      isPlanner: active?.plannerUserId == context.userId,
      revealed: active?.revealedAt != nil,
      plan: plan
    )
    return RitualPrivacy.seal(view)
  }

  private func card(from active: DateRow, context: LiveContext, completed: Int) -> DateCard {
    let when = APIDate.parse(active.scheduledAt) ?? Date()
    let parts = try? ZonedTime.zonedParts(instant: when, timeZone: context.couple.timezone)
    let suggested = (try? Recommendation.suggestedLocation(completedCount: completed)) ?? .home
    let planner = context.members.first { $0.userId == active.plannerUserId }?.displayName ?? context.couple.inviteeName
    return DateCard(
      id: active.id, status: active.status, scheduledAt: when,
      scheduledDate: parts?.date ?? "", scheduledTime: parts?.time ?? "",
      durationMinutes: active.durationMinutes, location: active.location,
      locationIsOverride: active.locationIsOverride, suggestedLocation: suggested,
      publicTeaser: active.publicTeaser, outfitHint: active.outfitHint,
      revealed: active.revealedAt != nil, plannerUserId: active.plannerUserId, plannerName: planner
    )
  }

  private func watchMoods(dateId: UUID) {
    watchTask?.cancel()
    guard let client else { return }
    watchTask = Task { [weak self] in
      let channel = client.channel("mood-\(dateId.uuidString)")
      let stream = channel.postgresChange(
        AnyAction.self, schema: "public", table: "mood_votes",
        filter: .eq("date_id", value: dateId.uuidString)
      )
      do { try await channel.subscribeWithError() } catch { return }
      for await _ in stream {
        if Task.isCancelled { break }
        await self?.onRemoteChange?()
      }
    }
  }

  private func catalogTitle(_ row: MemoryDateRow) -> String {
    if let id = row.snapshotIdeaId, let idea = IdeasCatalog.idea(id, in: IdeasCatalog.load()) {
      return idea.title
    }
    return row.snapshotTitle ?? L10n.enough
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct MoodWrite: Encodable {
  var dateId: UUID
  var userId: UUID
  var mood: String
  enum CodingKeys: String, CodingKey {
    case dateId = "date_id"
    case userId = "user_id"
    case mood
  }
}

private struct PlacePatch: Encodable {
  var location: String
  var locationIsOverride: Bool
  enum CodingKeys: String, CodingKey {
    case location
    case locationIsOverride = "location_is_override"
  }
}

private struct PlanWrite: Encodable {
  var dateId: UUID
  var ideaId: String
  var privateNotes: String?
  var preparedAt: String
  enum CodingKeys: String, CodingKey {
    case dateId = "date_id"
    case ideaId = "idea_id"
    case privateNotes = "private_notes"
    case preparedAt = "prepared_at"
  }
}

private struct HintPatch: Encodable {
  var publicTeaser: String?
  var outfitHint: String?
  enum CodingKeys: String, CodingKey {
    case publicTeaser = "public_teaser"
    case outfitHint = "outfit_hint"
  }
}

private struct NotesPatch: Encodable {
  var privateNotes: String
  enum CodingKeys: String, CodingKey { case privateNotes = "private_notes" }
}

private struct SchedulePatch: Encodable {
  var scheduledAt: String
  var status: String
  enum CodingKeys: String, CodingKey {
    case scheduledAt = "scheduled_at"
    case status
  }
}

private struct RevealPatch: Encodable {
  var revealedAt: String
  enum CodingKeys: String, CodingKey { case revealedAt = "revealed_at" }
}

private struct PlannerPatch: Encodable {
  var plannerUserId: UUID
  enum CodingKeys: String, CodingKey { case plannerUserId = "planner_user_id" }
}

private struct RecentIdea: Decodable {
  var snapshotIdeaId: String?
  enum CodingKeys: String, CodingKey { case snapshotIdeaId = "snapshot_idea_id" }
}

private struct NotesBody: Encodable { var note: String }

private struct NewNote: Encodable {
  var id: UUID
  var dateId: UUID
  var authorUserId: UUID
  var note: String
  enum CodingKeys: String, CodingKey {
    case id
    case dateId = "date_id"
    case authorUserId = "author_user_id"
    case note
  }
}

struct SettingsPatch: Encodable {
  var weekday: Int
  var localTime: String
  var timezone: String
  var durationMinutes: Int
  var inviteeName: String?
  enum CodingKeys: String, CodingKey {
    case weekday
    case localTime = "local_time"
    case timezone
    case durationMinutes = "default_duration_minutes"
    case inviteeName = "invitee_display_name"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(weekday, forKey: .weekday)
    try container.encode(localTime, forKey: .localTime)
    try container.encode(timezone, forKey: .timezone)
    try container.encode(durationMinutes, forKey: .durationMinutes)
    try container.encodeIfPresent(inviteeName, forKey: .inviteeName)
  }
}

private struct NamePatch: Encodable {
  var displayName: String
  enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}
