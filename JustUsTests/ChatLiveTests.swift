import Supabase
import XCTest
@testable import JustUs

@MainActor
final class ChatLiveTests: XCTestCase {
  func testOptimisticSendShowsThenSettles() async {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    backend.holdSend = true
    alex.chatDraft = "on its way"
    let task = Task { await alex.sendChat() }
    let appeared = await waitUntil { alex.messages.last?.delivery == .sending }
    XCTAssertTrue(appeared)
    XCTAssertEqual(alex.chatDraft, "")
    XCTAssertNil(alex.activity)
    XCTAssertFalse(alex.busy)
    XCTAssertEqual(alex.messages.last?.text, "on its way")
    backend.releaseSend()
    await task.value
    XCTAssertEqual(alex.messages.last?.delivery, .sent)
    XCTAssertNil(alex.errorMessage)
  }

  func testFailedSendRetriesFromTheBubble() async throws {
    let store = FakeStore(inMemory: true)
    let backend = FakeBackend(store: store, cooldown: 0)
    let alex = await signedIn(backend)
    backend.failSend = .offline
    alex.chatDraft = "try again"
    await alex.sendChat()
    let failed = try XCTUnwrap(alex.messages.last)
    XCTAssertEqual(failed.delivery, .failed)
    XCTAssertEqual(failed.text, "try again")
    XCTAssertEqual(alex.errorMessage, L10n.chatSendFailed)
    await alex.retryChatLine(failed.id)
    XCTAssertEqual(alex.messages.last?.id, failed.id)
    XCTAssertEqual(alex.messages.last?.delivery, .sent)
    XCTAssertEqual(alex.messages.last?.text, "try again")
    XCTAssertEqual(store.world.chats.filter { $0.id == failed.id }.count, 1)
    XCTAssertNil(alex.errorMessage)
  }

  func testIncomingInsertAppendsWithoutReloading() async {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    let before = alex.messages.count
    backend.chatFailure = .server(code: "chat")
    let line = ChatLine(
      id: UUID(), senderUserId: SeedID.blair, text: "just this", createdAt: Date(), mine: false, unreadable: false
    )
    alex.showIncoming(line)
    XCTAssertEqual(alex.messages.count, before + 1)
    XCTAssertEqual(alex.messages.last?.text, "just this")
    XCTAssertNil(alex.errorMessage)
    XCTAssertEqual(ChatSocket.step(.insert), .append)
    XCTAssertEqual(ChatSocket.step(.update), .patch)
    XCTAssertEqual(ChatSocket.step(.delete), .reload)
    XCTAssertEqual(ChatSocket.step(.reconnect), .reload)
    XCTAssertEqual(ChatSocket.step(.undecodable), .reload)
  }

  func testAReloadStillReadsTheThread() async {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    alex.chatDraft = "stored"
    await alex.sendChat()
    backend.chatFailure = .server(code: "chat")
    await alex.loadMessages()
    XCTAssertEqual(alex.errorMessage, L10n.message(for: .server(code: "chat")))
    XCTAssertEqual(alex.messages.last?.text, "stored")
  }

  func testForegroundChatPushStaysOffTheLockScreen() async {
    XCTAssertEqual(ChatPush.presentation(["type": "chatMessage"]), [])
    XCTAssertEqual(ChatPush.presentation(["type": "chat"]), [])
    XCTAssertEqual(ChatPush.presentation(["type": "planReady"]), [.banner, .sound])
    XCTAssertTrue(ChatPush.showsBanner(chat: true, chatVisible: false))
    XCTAssertFalse(ChatPush.showsBanner(chat: true, chatVisible: true))
    XCTAssertFalse(ChatPush.showsBanner(chat: false, chatVisible: false))
    let alex = await signedIn(coupleBackend())
    alex.tab = .week
    alex.noteForegroundChat()
    XCTAssertEqual(alex.chatBanner, L10n.chatArrived)
    alex.tab = .chat
    alex.noteForegroundChat()
    XCTAssertNil(alex.chatBanner)
  }

  func testScrollFollowsOnlyWhenAlreadyAtTheBottom() {
    XCTAssertEqual(ChatScroll.action(nearBottom: true), .follow)
    XCTAssertEqual(ChatScroll.action(nearBottom: false), .pill)
    var presence = ChatPresence()
    XCTAssertFalse(presence.receive(subscribed: true))
    XCTAssertFalse(presence.receive(subscribed: false))
    XCTAssertTrue(presence.receive(subscribed: true))
  }

  func testChatTimeUsesTheLocaleClock() {
    var calendar = Calendar(identifier: .gregorian)
    let zone = TimeZone(secondsFromGMT: 0) ?? .current
    calendar.timeZone = zone
    let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 15, minute: 4)) ?? Date()
    let us = ChatTime.label(date, locale: Locale(identifier: "en_US"), timeZone: zone)
    let gb = ChatTime.label(date, locale: Locale(identifier: "en_GB"), timeZone: zone)
    XCTAssertTrue(us.contains("3:04"))
    XCTAssertTrue(us.contains("PM"))
    XCTAssertFalse(us.contains("2026"))
    XCTAssertTrue(gb.contains("15:04"))
    XCTAssertFalse(gb.contains("PM"))
    XCTAssertNotEqual(us, gb)
  }

  func testDayLinesGroupAcrossMidnightAndTimeZones() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    utc.locale = Locale(identifier: "en_US")
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 15)) ?? Date()
    let today = utc.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9)) ?? now
    let yesterday = utc.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 23, minute: 59)) ?? now
    let sunday = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)) ?? now
    XCTAssertEqual(ChatDay.label(today, now: now, calendar: utc).lowercased(), "today")
    XCTAssertEqual(ChatDay.label(yesterday, now: now, calendar: utc).lowercased(), "yesterday")
    let dated = ChatDay.label(sunday, now: now, calendar: utc)
    XCTAssertTrue(dated.contains("15"))
    XCTAssertTrue(dated.localizedCaseInsensitiveContains("Sun"))

    var hebrew = utc
    hebrew.locale = Locale(identifier: "he_IL")
    let hebrewToday = ChatDay.label(today, now: now, calendar: hebrew)
    let hebrewSunday = ChatDay.label(sunday, now: now, calendar: hebrew)
    XCTAssertFalse(hebrewToday.localizedCaseInsensitiveContains("today"))
    XCTAssertFalse(hebrewToday.isEmpty)
    XCTAssertFalse(hebrewSunday.localizedCaseInsensitiveContains("sun"))
    XCTAssertNotEqual(hebrewSunday, dated)

    let late = line("late", at: yesterday)
    let early = line("early", at: utc.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 0, minute: 1)) ?? now)
    let split = ChatDay.rows([early, late], now: now, calendar: utc)
    XCTAssertEqual(dividerLabels(split).map { $0.lowercased() }, ["yesterday", "today"])
    XCTAssertEqual(messageTexts(split), ["late", "early"])

    let evening = utc.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 22, minute: 30)) ?? now
    let afterMidnight = utc.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 1, minute: 30)) ?? now
    let pair = [line("evening", at: evening), line("after", at: afterMidnight)]
    XCTAssertEqual(ChatDay.rows(pair, now: now, calendar: utc).filter(isDivider).count, 2)
    var losAngeles = utc
    losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? utc.timeZone
    XCTAssertEqual(ChatDay.rows(pair, now: now, calendar: losAngeles).filter(isDivider).count, 1)
    var jerusalem = utc
    jerusalem.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? utc.timeZone
    jerusalem.locale = Locale(identifier: "he_IL")
    let jerusalemRows = ChatDay.rows(pair, now: now, calendar: jerusalem)
    XCTAssertEqual(jerusalemRows.filter(isDivider).count, 1)
    XCTAssertEqual(messageTexts(jerusalemRows), ["evening", "after"])
    XCTAssertTrue(ChatDay.rows([], now: now, calendar: utc).isEmpty)
  }

  func testComposerArrowWaitsForText() {
    XCTAssertFalse(ChatComposer.showsSend(""))
    XCTAssertFalse(ChatComposer.showsSend("   \n"))
    XCTAssertTrue(ChatComposer.showsSend("hi"))
  }

  func testScreenshotWatchRegistersOnce() {
    let center = NotificationCenter()
    let name = Notification.Name("justus.test.screenshot")
    let watch = ScreenshotWatch(center: center, name: name)
    var hits = 0
    watch.onShot = { hits += 1 }
    watch.register()
    watch.register()
    center.post(name: name, object: nil)
    XCTAssertEqual(watch.registrations, 1)
    XCTAssertEqual(hits, 1)
    watch.unregister()
    center.post(name: name, object: nil)
    XCTAssertEqual(hits, 1)
  }

  func testCloseScreenshotRowsCollapse() {
    let now = Date()
    let first = notice("Blair took a screenshot", at: now)
    let second = notice("Blair took a screenshot", at: now.addingTimeInterval(1))
    let later = notice("Blair took a screenshot", at: now.addingTimeInterval(10))
    XCTAssertEqual(ScreenshotDedup.collapse([first, second]).count, 1)
    XCTAssertEqual(ScreenshotDedup.collapse([first, later]).count, 2)
  }

  func testOpenedUpdatePatchesWithoutReloading() async throws {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    let sent = try await backend.sendPhoto(PhotoBytes.sample(), retention: .viewOnce)
    await alex.loadMessages()
    backend.chatFailure = .server(code: "chat")
    let opened = ChatLine(
      id: sent.id, senderUserId: SeedID.alex, text: L10n.chatOpened, createdAt: sent.createdAt,
      mine: true, unreadable: false, photo: .opened
    )
    alex.showIncoming(opened)
    XCTAssertEqual(alex.messages.first { $0.id == sent.id }?.photo, .opened)
    XCTAssertNil(alex.errorMessage)
    let partial: [String: AnyJSON] = [
      "id": .string(sent.id.uuidString),
      "photo_path": .null
    ]
    XCTAssertEqual(LiveBackend().openedPhotoId(partial), sent.id)
    XCTAssertNil(LiveBackend().openedPhotoId(["id": .string(sent.id.uuidString)]))
  }

  func testMergeReplacesTheSameSend() {
    let id = UUID()
    let sending = ChatLine(
      id: id, senderUserId: SeedID.alex, text: "hi", createdAt: Date(), mine: true, unreadable: false, delivery: .sending
    )
    let sent = ChatLine(
      id: id, senderUserId: SeedID.alex, text: "hi", createdAt: sending.createdAt, mine: true, unreadable: false
    )
    let merged = ChatThread.merge([sending], sent)
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].delivery, .sent)
    XCTAssertEqual(merged[0].text, "hi")
  }

  private func coupleBackend() -> FakeBackend {
    FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
  }

  func testReloadKeepsAnUnsentBubble() async {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    let pending = ChatLine(
      id: UUID(), senderUserId: SeedID.alex, text: "still here", createdAt: Date(),
      mine: true, unreadable: false, delivery: .failed
    )
    alex.messages.append(pending)
    await alex.loadMessages()
    XCTAssertEqual(alex.messages.first { $0.id == pending.id }?.text, "still here")
    XCTAssertEqual(alex.messages.first { $0.id == pending.id }?.delivery, .failed)
  }

  func testASentBubbleStaysSentWhenTheWriteFailsLate() async {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    backend.holdSend = true
    backend.failSend = .offline
    alex.chatDraft = "landed"
    let task = Task { await alex.sendChat() }
    let appeared = await waitUntil { alex.messages.last?.delivery == .sending }
    XCTAssertTrue(appeared)
    alex.setDelivery(alex.messages[alex.messages.count - 1].id, .sent)
    backend.releaseSend()
    await task.value
    XCTAssertEqual(alex.messages.last?.delivery, .sent)
    XCTAssertNil(alex.errorMessage)
  }

  func testPhotoRetryReusesTheSameId() async throws {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    backend.photoKeyFailure = .offline
    alex.stageChatPhoto(PhotoBytes.sample())
    await alex.sendStagedPhoto()
    let failed = try XCTUnwrap(alex.messages.last)
    XCTAssertEqual(failed.delivery, .failed)
    XCTAssertTrue(backend.store.world.chats.filter { $0.id == failed.id }.isEmpty)
    await alex.retryChatLine(failed.id)
    XCTAssertEqual(alex.messages.last?.delivery, .sent)
    XCTAssertEqual(backend.store.world.chats.filter { $0.id == failed.id }.count, 1)
  }

  func testASecondPhotoTapDoesNotInsertTwice() async {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    backend.holdSend = true
    alex.stageChatPhoto(PhotoBytes.sample())
    let first = Task { await alex.sendStagedPhoto() }
    let appeared = await waitUntil { alex.messages.contains { $0.photo != nil && $0.delivery == .sending } }
    XCTAssertTrue(appeared)
    await alex.sendStagedPhoto()
    backend.releaseSend()
    await first.value
    XCTAssertEqual(backend.store.world.chats.filter { $0.kind == "photo" }.count, 1)
  }

  func testARepeatedTextIdDoesNotInsertTwice() async throws {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    alex.chatDraft = "once"
    await alex.sendChat()
    let id = try XCTUnwrap(alex.messages.last?.id)
    _ = try await backend.sendMessage("once", id: id)
    XCTAssertEqual(backend.store.world.chats.filter { $0.id == id }.count, 1)
  }

  func testPhotoKeyRefreshRetriesOnce() async throws {
    let backend = coupleBackend()
    let alex = await signedIn(backend)
    backend.photoKeyFailure = .server(code: "unknown_sender_key")
    alex.stageChatPhoto(PhotoBytes.sample())
    await alex.sendStagedPhoto()
    let sent = try XCTUnwrap(alex.messages.last)
    XCTAssertEqual(sent.delivery, .sent)
    XCTAssertEqual(backend.store.world.chats.filter { $0.id == sent.id }.count, 1)
    XCTAssertNil(alex.errorMessage)
  }

  func testKeyRingNoticesANewDevice() {
    let id = UUID()
    XCTAssertTrue(ChatKeyRing.matches(cached: [id], fresh: [id]))
    XCTAssertFalse(ChatKeyRing.matches(cached: [id], fresh: [id, UUID()]))
  }

  func testAnAlreadyStoredInsertCountsAsSent() {
    XCTAssertTrue(ChatInsertGate.alreadyStored(AppError.server(code: "23505")))
    XCTAssertTrue(ChatInsertGate.alreadyStored(AppError.server(code: "409")))
    XCTAssertFalse(ChatInsertGate.alreadyStored(AppError.offline))
  }

  func testHebrewClockDoesNotUseMeridiem() {
    let label = ChatTime.label(
      Date(timeIntervalSince1970: 1_700_000_000),
      locale: Locale(identifier: "he_IL"),
      timeZone: TimeZone(secondsFromGMT: 0) ?? .current
    )
    XCTAssertTrue(label.contains("22:13"))
    XCTAssertFalse(label.contains("PM"))
  }

  private func signedIn(_ backend: FakeBackend) async -> SessionModel {
    // Both phones publish a key before the thread is used. Without Blair's key the send is
    // partnerNotReady and the optimistic bubble is removed.
    _ = try? backend.ensureKey(userId: SeedID.alex)
    _ = try? backend.ensureKey(userId: SeedID.blair)
    let alex = SessionModel(backend: backend)
    alex.email = "alex@couple-a.test"
    await alex.sendCode()
    alex.code = "000000"
    await alex.verify()
    await alex.refresh()
    return alex
  }

  private func line(_ text: String, at date: Date) -> ChatLine {
    ChatLine(id: UUID(), senderUserId: SeedID.alex, text: text, createdAt: date, mine: true, unreadable: false)
  }

  private func dividerLabels(_ rows: [ChatDay.Row]) -> [String] {
    rows.compactMap { row in
      if case .divider(_, let label) = row { return label }
      return nil
    }
  }

  private func messageTexts(_ rows: [ChatDay.Row]) -> [String] {
    rows.compactMap { row in
      if case .message(let line) = row { return line.text }
      return nil
    }
  }

  private func isDivider(_ row: ChatDay.Row) -> Bool {
    if case .divider = row { return true }
    return false
  }

  private func notice(_ text: String, at date: Date) -> ChatLine {
    ChatLine(
      id: UUID(), senderUserId: SeedID.blair, text: text, createdAt: date, mine: false, unreadable: false, notice: true
    )
  }

  private func waitUntil(_ ready: () -> Bool) async -> Bool {
    for _ in 0..<40 {
      if ready() { return true }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return ready()
  }
}
