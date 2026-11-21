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

  private func signedIn(_ backend: FakeBackend) async -> SessionModel {
    // Blair already has a phone in this couple. Without that key the send is partnerNotReady
    // and the optimistic bubble is removed.
    _ = try? backend.ensureKey(userId: SeedID.blair)
    let alex = SessionModel(backend: backend)
    alex.email = "alex@couple-a.test"
    await alex.sendCode()
    alex.code = "000000"
    await alex.verify()
    await alex.refresh()
    return alex
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
