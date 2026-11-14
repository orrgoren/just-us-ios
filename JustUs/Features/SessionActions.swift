import EventKit
import Foundation

extension SessionModel {
  func refresh() async {
    do {
      ritual = try await backendRitual()
      memories = try await backend.memories()
      settings = try await backend.settings()
      if let settings, draft.selfName.isEmpty {
        draft.selfName = settings.selfName
        draft.partnerName = settings.partnerName
        draft.weekday = settings.weekday
        draft.localTime = settings.localTime
        draft.timezone = settings.timezone
        draft.durationMinutes = settings.durationMinutes
      }
      if let ritual {
        teaser = ritual.date?.publicTeaser ?? teaser
        outfit = ritual.date?.outfitHint ?? outfit
        privateNotes = ritual.plan?.privateNotes ?? privateNotes
        planDay = ritual.date?.scheduledDate ?? planDay
        planTime = ritual.date?.scheduledTime ?? planTime
      }
      offline = false
    } catch {
      let appError = ErrorMap.app(error)
      if appError == .offline { offline = true }
      if appError == .sessionExpired { screen = .login }
      errorMessage = L10n.message(for: appError)
    }
  }

  func choose(mood: MoodKey) async {
    guard var current = ritual else { return }
    if let index = current.moods.firstIndex(where: { $0.userId == current.selfMember.userId }) {
      current.moods[index].mood = mood
    } else {
      current.moods.append(MoodVote(userId: current.selfMember.userId, mood: mood))
    }
    ritual = current
    Haptics.tap()
    do {
      try await backend.setMood(mood)
      outbox["mood"] = nil
      Telemetry.analytics.record(.moodSet)
    } catch {
      await remember(.mood(mood), key: "mood", error: error)
    }
  }

  func choose(place: PlaceChoice) async {
    await act { try await self.backend.setPlace(place); await self.refresh() }
  }

  func surprise() async {
    let excluding = ritual?.plan?.ideaId.map { [$0] } ?? []
    await act { try await self.backend.surprise(excluding: excluding); await self.refresh() }
  }

  func saveDate() async {
    await act {
      try await self.backend.saveDate(
        day: self.planDay, time: self.planTime, teaser: self.teaser, outfit: self.outfit, notes: self.privateNotes
      )
      Telemetry.analytics.record(.planSaved)
      await self.refresh()
    }
  }

  func revealPlan() async {
    await act {
      try await self.backend.reveal()
      Telemetry.analytics.record(.revealed)
      self.focusReveal = true
      await self.refresh()
    }
  }

  func skip() async { await act { try await self.backend.skipWeek(); await self.refresh() } }
  func swap() async { await act { try await self.backend.swapPlanner(); await self.refresh() } }
  func reopenDraft() async { await act { try await self.backend.reopen(); await self.refresh() } }

  func moveDate() async {
    await act { try await self.backend.move(day: self.planDay, time: self.planTime); await self.refresh() }
  }

  func finishNight() async {
    await act {
      try await self.backend.complete(note: self.momentDraft)
      self.momentDraft = ""
      await self.refresh()
      self.tab = .memories
    }
  }

  func openNextWeek() async { await act { try await self.backend.ensureDraft(); await self.refresh() } }

  func saveMoment() async {
    guard let dateId = editingDate else { return }
    let noteId = editingNote ?? UUID()
    editingNote = noteId
    await act {
      try await self.backend.saveNote(dateId: dateId, noteId: noteId, text: self.noteDraft)
      self.outbox["note"] = nil
      Telemetry.analytics.record(.memoryAdded)
      await self.refresh()
    }
  }

  func deleteMoment() async {
    guard let editingNote else { return }
    await act { try await self.backend.deleteNote(id: editingNote); await self.refresh() }
  }

  func savePhoto(_ data: Data) async {
    guard let editingDate, let jpeg = PhotoBytes.jpeg(from: data) else {
      errorMessage = L10n.photoFailed
      return
    }
    await act { try await self.backend.savePhoto(dateId: editingDate, jpeg: jpeg); await self.refresh() }
  }

  func useSamplePhoto() async {
    guard let editingDate else { return }
    await act { try await self.backend.savePhoto(dateId: editingDate, jpeg: PhotoBytes.sample()); await self.refresh() }
  }

  func saveSettings() async {
    guard var settings else { return }
    settings.selfName = draft.selfName.isEmpty ? settings.selfName : draft.selfName
    settings.partnerName = draft.partnerName.isEmpty ? settings.partnerName : draft.partnerName
    settings.weekday = draft.weekday
    settings.localTime = draft.localTime
    settings.timezone = draft.timezone
    settings.durationMinutes = draft.durationMinutes
    await act { try await self.backend.saveSettings(settings); await self.refresh() }
  }

  func toggle(_ kind: PushKind, on: Bool) async {
    guard var settings else { return }
    switch kind {
    case .partnerMood: settings.preferences.partnerMood = on
    case .planReady: settings.preferences.planReady = on
    case .inviteAccepted: settings.preferences.inviteAccepted = on
    case .weeklyReminder, .inviteNudge: settings.preferences.weeklyReminder = on
    }
    self.settings = settings
    await backend.savePreferences(settings.preferences)
  }

  func unlinkPartner() async {
    await act {
      try await self.backend.unlink()
      await self.refresh()
      self.screen = self.ritual == nil ? .setup : .main
    }
  }

  func deleteAccount() async {
    guard deleteConfirm == L10n.deleteWord else {
      errorMessage = L10n.message(for: .invalid(.confirm))
      return
    }
    await act {
      try await self.backend.deleteAccount()
      Telemetry.analytics.record(.accountDeleted)
      self.screen = .login
      self.showDelete = false
    }
  }

  func addCalendar() async {
    guard let ritual, let date = ritual.date else { return }
    if Launch.isUITest {
      _ = try? CalendarFile.build(
        coupleId: ritual.coupleId, startDate: date.scheduledDate, startTime: date.scheduledTime,
        durationMinutes: date.durationMinutes, timeZone: ritual.timezone
      )
      errorMessage = nil
      return
    }
    await EventWriter.add(date: date, zone: ritual.timezone)
  }

  func flush() async {
    guard let pending = outbox["mood"], case .mood(let mood) = pending else { return }
    do {
      try await backend.setMood(mood)
      outbox["mood"] = nil
      offline = false
    } catch {
      errorMessage = L10n.message(for: ErrorMap.app(error))
    }
  }

  func applyScreenshot(_ name: String) async {
    switch name {
    case "login": screen = .login
    case "code":
      email = "alex@couple-a.test"
      screen = .code
    case "setup": screen = .setup
    case "inviteShare":
      await signedIn("sam@solo.test")
      inviteToken = SeedID.validToken
      screen = .inviteShare
    case "softPrompt": screen = .softPrompt
    case "inviteRedeem": screen = .invite
    case "inviteReplace":
      pendingReplace = true
      inviteInput = SeedID.validToken
      screen = .invite
    case "inviteBlocked":
      blocked = true
      screen = .invite
    case "homeSolo":
      await signedIn("sam@solo.test")
      screen = .main
    case "homePlanner":
      await signedIn("alex@couple-a.test")
      screen = .main
    case "homePartner":
      await signedIn("blair@couple-a.test")
      screen = .main
    case "reveal":
      await signedIn("alex@couple-a.test")
      focusReveal = true
      screen = .main
    case "memories":
      await signedIn("riley@busy.test")
      tab = .memories
      screen = .main
    case "memoriesEmpty":
      await signedIn("sam@solo.test")
      tab = .memories
      screen = .main
    case "settings":
      await signedIn("alex@couple-a.test")
      tab = .settings
      screen = .main
    case "deleteAccount":
      await signedIn("alex@couple-a.test")
      tab = .settings
      showDelete = true
      screen = .main
    case "offline":
      await signedIn("alex@couple-a.test")
      backend.setOffline(true)
      offline = true
      screen = .main
    default:
      screen = .login
    }
  }

  private func signedIn(_ email: String) async {
    _ = try? await backend.sendCode(email: email)
    _ = try? await backend.verify(email: email, code: "000000")
    await refresh()
  }

  private func act(_ body: () async throws -> Void) async {
    busy = true
    defer { busy = false }
    do {
      try await body()
      errorMessage = nil
    } catch {
      let appError = ErrorMap.app(error)
      if appError == .offline { offline = true }
      errorMessage = L10n.message(for: appError)
    }
  }

  private func remember(_ pending: Pending, key: String, error: Error) async {
    let appError = ErrorMap.app(error)
    if appError == .offline {
      offline = true
      outbox[key] = pending
    }
    errorMessage = L10n.message(for: appError)
  }

  private func backendRitual() async throws -> RitualSnapshot? {
    try await backend.ritual()
  }
}

enum EventWriter {
  static func add(date: DateCard, zone: String) async {
    let store = EKEventStore()
    do {
      let granted = try await store.requestFullAccessToEvents()
      guard granted else { return }
      let event = EKEvent(eventStore: store)
      event.title = CalendarFile.summary
      event.notes = CalendarFile.details
      event.timeZone = TimeZone(identifier: zone)
      event.startDate = date.scheduledAt
      event.endDate = date.scheduledAt.addingTimeInterval(TimeInterval(date.durationMinutes * 60))
      event.calendar = store.defaultCalendarForNewEvents
      try store.save(event, span: .thisEvent)
    } catch {
      Telemetry.crashes.record(error)
    }
  }
}
