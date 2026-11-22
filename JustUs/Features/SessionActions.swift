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
        teaser = ritual.date?.publicTeaser ?? ""
        outfit = ritual.date?.outfitHint ?? ""
        privateNotes = ritual.plan?.privateNotes ?? ""
        planDay = ritual.date?.scheduledDate ?? ""
        planTime = ritual.date?.scheduledTime ?? ""
      } else if signedIn {
        teaser = ""
        outfit = ""
        privateNotes = ""
        planDay = ""
        planTime = ""
        if await backend.takeSpaceClosed() {
          rememberSpaceClosed()
        } else if UserDefaults.standard.bool(forKey: Self.closedSpaceKey(email)) {
          spaceClosed = true
        }
        if spaceClosed {
          screen = .setup
        }
      }
      offline = false
    } catch {
      await applyFailure(error, retry: nil)
    }
    await loadMessages()
  }

  func loadMessages() async {
    do {
      let raw = try await backend.messages()
      rememberSeals(raw)
      let remote = ScreenshotDedup.collapse(raw.map(displayedChat))
      messages = ChatThread.keepingPending(remote, local: messages)
      if let notice = backend.partnerKeyNotice() {
        chatKeyNotice = notice
      }
      await flushConsumes()
      if chatPresented { markChatSeen() }
    } catch {
      errorMessage = L10n.message(for: ErrorMap.app(error))
    }
  }

  func presentChat() {
    if tab == .chat { tab = .week }
    chatPresented = true
    chatBanner = nil
    markChatSeen()
    Task { await loadMessages() }
  }

  func markChatSeen() {
    guard let userId = ritual?.selfMember.userId else { return }
    let latest = messages.map(\.createdAt).max() ?? Date()
    ChatSeen.mark(latest, userId: userId)
  }

  func choose(mood: MoodKey) async {
    guard let current = ritual else { return }
    guard MoodEdit.allowed(status: current.date?.status, revealed: current.revealed) else {
      errorMessage = L10n.message(for: .notEditable)
      return
    }
    let previous = current.moods
    var optimistic = current
    if let index = optimistic.moods.firstIndex(where: { $0.userId == current.selfMember.userId }) {
      optimistic.moods[index].mood = mood
    } else {
      optimistic.moods.append(MoodVote(userId: current.selfMember.userId, mood: mood))
    }
    ritual = optimistic
    Haptics.tap()
    do {
      try await backend.setMood(mood)
      outbox["mood"] = nil
      Telemetry.analytics.record(.moodSet)
      errorMessage = nil
    } catch {
      let appError = ErrorMap.app(error)
      if appError != .offline, var rolled = ritual {
        rolled.moods = previous
        ritual = rolled
      }
      await remember(.mood(mood), key: "mood", error: error)
    }
  }

  func choose(place: PlaceChoice) async {
    await act { try await self.backend.setPlace(place); await self.refresh() }
  }

  func surprise() async {
    let excluding = ritual?.plan.map { [$0.ideaId] } ?? []
    await act(activity: .generic, retry: .surprise) {
      try await self.backend.surprise(excluding: excluding)
      await self.refresh()
    }
  }

  func saveDate() async {
    await act(activity: .saveDate, retry: .saveDate) {
      try await self.backend.saveDate(
        day: self.planDay, time: self.planTime, teaser: self.teaser, outfit: self.outfit, notes: self.privateNotes
      )
      Telemetry.analytics.record(.planSaved)
      await self.refresh()
      self.celebrate(.nightSet)
    }
  }

  func saveHint() async {
    await act(activity: .saveHint, retry: .saveHint) {
      try await self.backend.saveHint(teaser: self.teaser, outfit: self.outfit, notes: self.privateNotes)
      await self.refresh()
    }
  }

  func revealPlan() async {
    await act(activity: .reveal, retry: .reveal) {
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
    await act(activity: .finish, retry: .finish) {
      try await self.backend.complete(note: self.momentDraft)
      self.momentDraft = ""
      await self.refresh()
      self.tab = .memories
    }
  }

  func openNextWeek() async {
    await act(activity: .generic, retry: .openWeek) { try await self.backend.ensureDraft(); await self.refresh() }
  }

  func saveMoment() async {
    guard let dateId = editingDate else { return }
    let noteId = editingNote ?? UUID()
    editingNote = noteId
    await act(activity: .moment, retry: .moment) {
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

  func savePhoto(_ data: Data, dateId: UUID? = nil) async {
    let target = dateId ?? editingDate
    guard let target, let jpeg = PhotoBytes.jpeg(from: data), MemoryPhoto.accepted(jpeg) else {
      errorMessage = L10n.photoFailed
      return
    }
    await act { try await self.backend.savePhoto(dateId: target, jpeg: jpeg); await self.refresh() }
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
    await act(activity: .settings, retry: .settings) {
      try await self.backend.saveSettings(settings)
      await self.refresh()
    }
  }

  func sendChat() async {
    let clear: String
    do {
      clear = try ChatText.normalized(chatDraft)
    } catch {
      noteChatFailure(error)
      return
    }
    let id = UUID()
    messages.append(outgoingLine(id: id, text: clear))
    chatDraft = ""
    chatKeyNotice = nil
    errorMessage = nil
    retryKind = nil
    await finishSend(id: id, text: clear)
  }

  func retryChatLine(_ id: UUID) async {
    guard let line = messages.first(where: { $0.id == id }), line.delivery == .failed else { return }
    if pendingPhotos[id] != nil {
      setDelivery(id, .sending)
      errorMessage = nil
      await finishPhoto(id: id)
      return
    }
    guard line.photo == nil else { return }
    setDelivery(id, .sending)
    errorMessage = nil
    await finishSend(id: id, text: line.text)
  }

  func showIncoming(_ line: ChatLine) {
    let known = messages.contains { $0.id == line.id }
    messages = ScreenshotDedup.collapse(ChatThread.merge(messages, line))
    if line.photo == .opened || sealedOpens.contains(line.id) {
      sealOpen(line.id)
    }
    guard known == false else { return }
    if chatPresented {
      markChatSeen()
      chatBanner = nil
      return
    }
    if ChatPush.showsBanner(chat: true, chatVisible: false) {
      chatBanner = L10n.chatArrived
    }
  }

  func appendIncoming(_ row: ChatMessageRow) async {
    guard let line = await backend.incomingLine(row) else {
      await loadMessages()
      return
    }
    showIncoming(line)
  }

  func noteForegroundChat() {
    guard ChatPush.showsBanner(chat: true, chatVisible: chatPresented) else {
      chatBanner = nil
      return
    }
    chatBanner = L10n.chatArrived
  }

  private func finishSend(id: UUID, text: String) async {
    do {
      let saved = try await backend.sendMessage(text, id: id)
      messages = ChatThread.merge(messages, saved)
      errorMessage = nil
      retryKind = nil
    } catch {
      failSend(id: id, text: text, error: error)
    }
  }

  private func failSend(id: UUID, text: String, error: Error) {
    guard messages.first(where: { $0.id == id })?.delivery != .sent else { return }
    let mapped = ErrorMap.app(error)
    if keepsFailedBubble(mapped) {
      setDelivery(id, .failed)
    } else {
      messages.removeAll { $0.id == id }
      if chatDraft.isEmpty { chatDraft = text }
    }
    noteChatFailure(error)
  }

  func keepsFailedBubble(_ error: AppError) -> Bool {
    switch error {
    case .rateLimited, .sessionExpired, .notAuthenticated, .chatTooLong, .chatPhotoTooBig, .partnerNotReady, .invalid:
      return false
    default:
      return true
    }
  }

  private func outgoingLine(id: UUID, text: String) -> ChatLine {
    ChatLine(
      id: id, senderUserId: ritual?.selfMember.userId ?? UUID(), text: text, createdAt: Date(),
      mine: true, unreadable: false, delivery: .sending
    )
  }

  func setDelivery(_ id: UUID, _ delivery: ChatDelivery) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].delivery = delivery
  }

  func stageChatPhoto(_ data: Data) {
    guard let jpeg = PhotoBytes.jpeg(from: data, maxEdge: ChatPhoto.maxEdge, quality: 0.72), ChatPhoto.fits(jpeg) else {
      errorMessage = L10n.chatPhotoTooBig
      return
    }
    stagedChatJPEG = jpeg
    chatRetention = .viewOnce
    errorMessage = nil
  }

  func retryChat() async {
    if stagedChatJPEG != nil {
      await sendStagedPhoto()
    } else if let failed = messages.last(where: { $0.delivery == .failed && pendingPhotos[$0.id] != nil }) {
      await retryChatLine(failed.id)
    } else if let failed = messages.last(where: { $0.delivery == .failed && $0.photo == nil }) {
      await retryChatLine(failed.id)
    } else {
      await sendChat()
    }
  }

  func finishViewOnce(_ id: UUID) async {
    openChatPhoto = nil
    guard let line = messages.first(where: { $0.id == id }), line.mine == false else { return }
    guard line.photo == .viewOnce || sealedOpens.contains(id) else { return }
    sealOpen(id)
    pendingConsumes.insert(id)
    await flushConsumes()
  }

  func sealOpen(_ id: UUID) {
    sealedOpens.insert(id)
    storeSeals()
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index] = ChatOpen.seal(messages[index])
  }

  func canReopenPhoto(_ id: UUID) -> Bool {
    sealedOpens.contains(id) == false && messages.first { $0.id == id }?.photo == .viewOnce
  }

  func deleteChatPhoto(_ id: UUID) async {
    do {
      try await backend.deleteChatPhoto(id)
      await loadMessages()
    } catch {
      errorMessage = L10n.chatSendFailed
    }
  }

  func noteScreenshot() async {
    guard let id = openChatPhoto else { return }
    guard let line = messages.first(where: { $0.id == id }), line.mine == false else { return }
    guard line.photo == .viewOnce || line.photo == .opened else { return }
    let now = Date()
    guard ScreenshotDedup.allow(messageId: id, now: now, previous: lastShot) else { return }
    lastShot = (id, now)
    guard let notice = try? await backend.sendScreenshotNotice(for: id) else { return }
    showIncoming(notice)
  }

  private func displayedChat(_ line: ChatLine) -> ChatLine {
    sealedOpens.contains(line.id) ? ChatOpen.seal(line) : line
  }

  private func rememberSeals(_ lines: [ChatLine]) {
    if let userId = ritual?.selfMember.userId {
      sealedOpens.formUnion(SealedOpens.load(userId))
    }
    sealedOpens = Set(sealedOpens.filter { id in
      lines.contains { $0.id == id && $0.photo == .viewOnce }
    })
    storeSeals()
    pendingConsumes.formUnion(sealedOpens)
  }

  private func storeSeals() {
    guard let userId = ritual?.selfMember.userId else { return }
    SealedOpens.store(sealedOpens, userId: userId)
  }

  private func flushConsumes() async {
    let ids = pendingConsumes
    for id in ids {
      do {
        try await backend.consumeViewOnce(id)
        pendingConsumes.remove(id)
      } catch {
        continue
      }
    }
  }

  func noteChatFailure(_ error: Error) {
    let mapped = ErrorMap.app(error)
    if mapped == .sessionExpired || mapped == .notAuthenticated || mapped == .chatTooLong || mapped == .chatPhotoTooBig || mapped == .rateLimited {
      errorMessage = L10n.message(for: mapped)
      retryKind = nil
      return
    }
    errorMessage = L10n.chatSendFailed
    retryKind = .chat
  }

  func toggle(_ kind: PushKind, on: Bool) async {
    guard var settings else { return }
    switch kind {
    case .partnerMood: settings.preferences.partnerMood = on
    case .planReady: settings.preferences.planReady = on
    case .inviteAccepted: settings.preferences.inviteAccepted = on
    case .weeklyReminder, .inviteNudge: settings.preferences.weeklyReminder = on
    case .chatMessage: break
    }
    self.settings = settings
    await backend.savePreferences(settings.preferences)
  }

  func unlinkPartner() async {
    await act {
      try await self.backend.unlink()
      await self.refresh()
      self.clearRememberedClosure()
      self.screen = .setup
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
      self.clearSession()
      self.email = ""
      self.screen = .login
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
      let appError = ErrorMap.moodReplay(error)
      if appError == .notEditable || appError == .saveFailed {
        outbox["mood"] = nil
        errorMessage = L10n.message(for: appError)
        await refresh()
        return
      }
      errorMessage = L10n.message(for: appError)
    }
  }

  func applyScreenshot(_ name: String) async {
    if await applyEntryScreenshot(name) { return }
    if await applyHomeScreenshot(name) { return }
    await applyLaterScreenshot(name)
  }

  private func applyEntryScreenshot(_ name: String) async -> Bool {
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
    case "inviteRedeem":
      signedIn = true
      screen = .invite
    case "inviteReplace":
      signedIn = true
      pendingReplace = true
      inviteInput = SeedID.validToken
      screen = .invite
    case "inviteBlocked":
      signedIn = true
      blocked = true
      screen = .invite
    default:
      return false
    }
    return true
  }

  private func applyHomeScreenshot(_ name: String) async -> Bool {
    switch name {
    case "homeSolo":
      await signedIn("sam@solo.test")
      screen = .main
    case "homePlanner":
      await signedIn("alex@couple-a.test")
      screen = .main
    case "editHint":
      await signedIn("alex@couple-a.test")
      (backend as? FakeBackend)?.scheduleUnrevealed()
      await refresh()
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
    case "chat", "chatPhoto", "chatPhotoChoice":
      await chatScreenshot(name)
    case "chatBadge":
      await signedIn("alex@couple-a.test")
      (backend as? FakeBackend)?.seedUnreadChat()
      await loadMessages()
      tab = .week
      chatPresented = false
      screen = .main
    default:
      return false
    }
    return true
  }

  private func applyLaterScreenshot(_ name: String) async {
    switch name {
    case "settings":
      await signedIn("alex@couple-a.test")
      tab = .settings
      screen = .main
    case "deleteAccount":
      await signedIn("alex@couple-a.test")
      tab = .settings
      showDelete = true
      screen = .main
    case "offline", "errorBanner":
      await signedIn("alex@couple-a.test")
      backend.setOffline(true)
      offline = true
      errorMessage = L10n.offline
      screen = .main
    case "plannerTools", "selectedMood":
      await signedIn("alex@couple-a.test")
      screen = .main
    case "settingsBottom", "signOut":
      await signedIn("alex@couple-a.test")
      tab = .settings
      screen = .main
    case "photoMemory":
      await signedIn("riley@busy.test")
      tab = .memories
      screen = .main
    case "revealedPlan":
      await signedIn("blair@couple-a.test")
      (backend as? FakeBackend)?.markRevealed()
      await refresh()
      focusReveal = true
      screen = .main
    case "unlinkConfirm":
      await signedIn("alex@couple-a.test")
      tab = .settings
      confirmUnlink = true
      screen = .main
    case "postDeletion":
      await signedIn("demo@justus.app")
      deleteConfirm = L10n.deleteWord
      await deleteAccount()
    case "spaceClosed":
      await signedIn("alex@couple-a.test")
      deleteConfirm = L10n.deleteWord
      await deleteAccount()
      await signedIn("blair@couple-a.test")
    case "notificationTap":
      await signedIn("alex@couple-a.test")
      focusReveal = true
      screen = .main
    default:
      screen = .login
    }
  }

  private func chatScreenshot(_ name: String) async {
    await signedIn("alex@couple-a.test")
    if name == "chat" {
      (backend as? FakeBackend)?.seedChatPreview()
      await loadMessages()
    } else if name == "chatPhoto" {
      (backend as? FakeBackend)?.seedChatPhotoPreview()
      await loadMessages()
    } else {
      stageChatPhoto(PhotoBytes.sample())
    }
    tab = .week
    screen = .main
    presentChat()
  }

  private func signedIn(_ email: String) async {
    self.email = email
    _ = try? await backend.sendCode(email: email)
    _ = try? await backend.verify(email: email, code: "000000")
    signedIn = true
    await refresh()
  }

  private func act(activity: Activity = .generic, retry: RetryKind? = nil, _ body: () async throws -> Void) async {
    self.activity = activity
    busy = true
    defer {
      busy = false
      self.activity = nil
    }
    do {
      try await body()
      errorMessage = nil
      retryKind = nil
    } catch {
      await applyFailure(error, retry: retry)
    }
  }

  private func remember(_ pending: Pending, key: String, error: Error) async {
    let appError = ErrorMap.app(error)
    if appError == .sessionExpired || appError == .linkExpired {
      await applyFailure(error, retry: .sendCode)
      return
    }
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
