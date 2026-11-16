import XCTest
@testable import JustUs

@MainActor
final class FakeFlowTests: XCTestCase {
  override nonisolated func setUp() {
    super.setUp()
    PendingInviteStore.clear()
    DeviceTokenStore.reset()
  }

  override nonisolated func tearDown() {
    PendingInviteStore.clear()
    DeviceTokenStore.reset()
    super.tearDown()
  }

  func testTurnFollowsTheLastPlanner() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    let loaded = try await backend.ritual()
    let alex = try XCTUnwrap(loaded)
    XCTAssertTrue(alex.isPlanner)
    XCTAssertEqual(alex.date?.plannerUserId, SeedID.alex)
    XCTAssertEqual(alex.streakWeeks, 2)
    try await backend.complete(note: "A good night")
    let next = try await backend.ritual()
    let handedOn = try XCTUnwrap(next)
    XCTAssertEqual(handedOn.date?.plannerUserId, SeedID.blair)
    XCTAssertFalse(handedOn.isPlanner)
    XCTAssertEqual(handedOn.streakWeeks, 3)
  }

  func testStreakStillHoldsThirtyDaysOut() async throws {
    let later = Date().addingTimeInterval(30 * 24 * 60 * 60)
    let backend = FakeBackend(cooldown: 0, now: later)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    let loaded = try await backend.ritual()
    let alex = try XCTUnwrap(loaded)
    XCTAssertEqual(alex.date?.plannerUserId, SeedID.alex)
    XCTAssertEqual(alex.streakWeeks, 2)
    try await backend.complete(note: "A good night")
    let next = try await backend.ritual()
    let handedOn = try XCTUnwrap(next)
    XCTAssertEqual(handedOn.date?.plannerUserId, SeedID.blair)
    XCTAssertEqual(handedOn.streakWeeks, 3)
  }

  func testSkipDoesNotHandTheTurnOver() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    try await backend.skipWeek()
    let loaded = try await backend.ritual()
    let again = try XCTUnwrap(loaded)
    XCTAssertEqual(again.date?.plannerUserId, SeedID.alex)
    XCTAssertTrue(again.isPlanner)
  }

  func testPartnerCannotSeePlan() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "blair@couple-a.test")
    _ = try await backend.verify(email: "blair@couple-a.test", code: "000000")
    let loaded = try await backend.ritual()
    let ritual = try XCTUnwrap(loaded)
    XCTAssertFalse(ritual.isPlanner)
    XCTAssertNil(ritual.plan)
    XCTAssertFalse(RitualPrivacy.containsSecret(ritual, secret: "A table for two"))
    XCTAssertEqual(ritual.date?.publicTeaser, "Come hungry")
  }

  func testMoodDoesNotOverwritePartner() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    try await backend.setMood(.fun)
    await backend.injectPartnerMood()
    let loaded = try await backend.ritual()
    let ritual = try XCTUnwrap(loaded)
    XCTAssertEqual(ritual.moods.first { $0.userId == SeedID.alex }?.mood, .fun)
    XCTAssertEqual(ritual.moods.first { $0.userId == SeedID.blair }?.mood, .chill)
  }

  func testSelfUsedFullAndReplace() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "jordan@invite.test")
    _ = try await backend.verify(email: "jordan@invite.test", code: "000000")
    do {
      try await backend.redeem(token: SeedID.validToken, replaceEmpty: true)
      XCTFail("Self redeem should fail")
    } catch let error as AppError {
      XCTAssertEqual(error, .selfRedeem)
    }

    try await backend.signOut()
    _ = try await backend.sendCode(email: "new@example.com")
    _ = try await backend.verify(email: "new@example.com", code: "000000")
    do {
      try await backend.redeem(token: SeedID.usedToken, replaceEmpty: false)
      XCTFail("Used invite should fail")
    } catch let error as AppError {
      XCTAssertEqual(error, .usedInvite)
    }
    do {
      try await backend.redeem(token: SeedID.fullToken, replaceEmpty: false)
      XCTFail("Full couple should fail")
    } catch let error as AppError {
      XCTAssertEqual(error, .coupleFull)
    }

    try await backend.signOut()
    _ = try await backend.sendCode(email: "sam@solo.test")
    _ = try await backend.verify(email: "sam@solo.test", code: "000000")
    try await backend.redeem(token: SeedID.validToken, replaceEmpty: true)
    let loaded = try await backend.ritual()
    let ritual = try XCTUnwrap(loaded)
    XCTAssertEqual(ritual.coupleId, SeedID.coupleJordan)
  }

  func testDeletionClosesTheSharedSpace() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    try await backend.deleteAccount()
    XCTAssertFalse(backend.store.world.users.contains { $0.id == SeedID.alex })
    XCTAssertTrue(backend.store.world.users.contains { $0.id == SeedID.blair })
    XCTAssertFalse(backend.store.world.members.contains { $0.coupleId == SeedID.coupleA })
    XCTAssertFalse(backend.store.world.couples.contains { $0.id == SeedID.coupleA })
    XCTAssertFalse(backend.store.world.dates.contains { $0.coupleId == SeedID.coupleA })
    XCTAssertFalse(backend.store.world.moods.contains { $0.dateId == SeedID.dateA })
    XCTAssertFalse(backend.store.world.invites.contains { $0.coupleId == SeedID.coupleA })
    XCTAssertTrue(backend.store.world.couples.contains { $0.id == SeedID.coupleB })

    let partner = SessionModel(backend: backend)
    partner.email = "blair@couple-a.test"
    await partner.sendCode()
    partner.code = "000000"
    await partner.verify()
    XCTAssertEqual(partner.screen, .setup)
    XCTAssertTrue(partner.spaceClosed)
    XCTAssertEqual(partner.errorMessage, nil)
    await partner.refresh()
    XCTAssertEqual(partner.screen, .setup)
    XCTAssertTrue(partner.spaceClosed)
    await partner.signOut()
    partner.email = "blair@couple-a.test"
    await partner.sendCode()
    partner.code = "000000"
    await partner.verify()
    XCTAssertEqual(partner.screen, .setup)
    XCTAssertTrue(partner.spaceClosed)
    UserDefaults.standard.removeObject(forKey: SessionModel.closedSpaceKey("blair@couple-a.test"))
  }

  func testRefreshLeavesMainForTheClosedNotice() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    XCTAssertEqual(model.screen, .main)
    backend.store.markSpaceClosed(SeedID.alex)
    backend.removeCouple(SeedID.coupleA)
    await model.refresh()
    XCTAssertEqual(model.screen, .setup)
    XCTAssertTrue(model.spaceClosed)
    await model.refresh()
    XCTAssertEqual(model.screen, .setup)
    XCTAssertTrue(model.spaceClosed)
    UserDefaults.standard.removeObject(forKey: SessionModel.closedSpaceKey("alex@couple-a.test"))
  }

  func testUnlinkClosesTheSharedSpace() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    try await backend.unlink()
    XCTAssertFalse(backend.store.world.couples.contains { $0.id == SeedID.coupleA })
    XCTAssertTrue(backend.store.world.users.contains { $0.id == SeedID.alex })
    let partner = SessionModel(backend: backend)
    partner.email = "blair@couple-a.test"
    await partner.sendCode()
    partner.code = "000000"
    await partner.verify()
    XCTAssertEqual(partner.screen, .setup)
    XCTAssertTrue(partner.spaceClosed)
    UserDefaults.standard.removeObject(forKey: SessionModel.closedSpaceKey("blair@couple-a.test"))
  }

  func testOfflineMoodIsRejectedUntilOnline() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    backend.setOffline(true)
    do {
      try await backend.setMood(.chill)
      XCTFail("Offline write should fail")
    } catch let error as AppError {
      XCTAssertEqual(error, .offline)
    }
    backend.setOffline(false)
    try await backend.setMood(.chill)
    let loaded = try await backend.ritual()
    let ritual = try XCTUnwrap(loaded)
    XCTAssertEqual(ritual.moods.first { $0.userId == SeedID.alex }?.mood, .chill)
  }

  func testWrongAndExpiredCodes() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    do {
      _ = try await backend.verify(email: "alex@couple-a.test", code: "222222")
      XCTFail("Wrong code")
    } catch let error as AppError {
      XCTAssertEqual(error, .invalidCode)
    }
    do {
      _ = try await backend.verify(email: "alex@couple-a.test", code: "111111")
      XCTFail("Expired code")
    } catch let error as AppError {
      XCTAssertEqual(error, .expiredCode)
    }
    do {
      _ = try await backend.verify(email: "alex@couple-a.test", code: "424242")
      XCTFail("Demo code is only for the demo mailbox")
    } catch let error as AppError {
      XCTAssertEqual(error, .invalidCode)
    }
  }

  func testPlannerCanEditTheHintUntilReveal() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    try await backend.saveDate(
      day: "2026-11-19", time: "20:30", teaser: "Come hungry", outfit: "Cozy", notes: "Only the planner knows"
    )
    let scheduledLoaded = try await backend.ritual()
    let scheduled = try XCTUnwrap(scheduledLoaded)
    XCTAssertEqual(scheduled.date?.status, .scheduled)
    XCTAssertFalse(scheduled.revealed)

    try await backend.saveHint(teaser: "Bring a sweater", outfit: "Pajamas", notes: "Candles")
    let editedLoaded = try await backend.ritual()
    let edited = try XCTUnwrap(editedLoaded)
    XCTAssertEqual(edited.date?.status, .scheduled)
    XCTAssertEqual(edited.date?.publicTeaser, "Bring a sweater")
    XCTAssertEqual(edited.date?.outfitHint, "Pajamas")
    XCTAssertEqual(edited.plan?.privateNotes, "Candles")
    XCTAssertEqual(edited.plan?.ideaId, "h6")

    do {
      try await backend.saveDate(day: "2026-11-19", time: "21:00", teaser: "Later", outfit: "Nope", notes: "No")
      XCTFail("Saving the date again should not reschedule it")
    } catch let error as AppError {
      XCTAssertEqual(error, .notEditable)
    }
    do {
      try await backend.surprise(excluding: [])
      XCTFail("A scheduled idea stays put")
    } catch let error as AppError {
      XCTAssertEqual(error, .notEditable)
    }

    try await backend.reveal()
    do {
      try await backend.saveHint(teaser: "Too late", outfit: "Nope", notes: "Hidden")
      XCTFail("A revealed hint stays")
    } catch let error as AppError {
      XCTAssertEqual(error, .notEditable)
    }
    let revealedLoaded = try await backend.ritual()
    let revealed = try XCTUnwrap(revealedLoaded)
    XCTAssertEqual(revealed.date?.publicTeaser, "Bring a sweater")
    XCTAssertEqual(revealed.plan?.privateNotes, "Candles")
  }

  func testPartnerCannotEditTheScheduledHint() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    try await backend.saveDate(
      day: "2026-11-19", time: "20:30", teaser: "Come hungry", outfit: "Cozy", notes: "Only the planner knows"
    )
    try await backend.signOut()
    _ = try await backend.sendCode(email: "blair@couple-a.test")
    _ = try await backend.verify(email: "blair@couple-a.test", code: "000000")
    do {
      try await backend.saveHint(teaser: "Stolen", outfit: "Stolen", notes: "Stolen")
      XCTFail("The partner is not the planner")
    } catch let error as AppError {
      XCTAssertEqual(error, .notPlanner)
    }
    let loaded = try await backend.ritual()
    let ritual = try XCTUnwrap(loaded)
    XCTAssertEqual(ritual.date?.publicTeaser, "Come hungry")
    XCTAssertNil(ritual.plan)
  }

  func testSaveHintActionLeavesTheDateScheduled() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    try await backend.saveDate(
      day: "2026-11-19", time: "20:30", teaser: "Come hungry", outfit: "Cozy", notes: "Only the planner knows"
    )
    await model.refresh()
    model.teaser = "Bring a sweater"
    model.outfit = "Pajamas"
    model.privateNotes = "Candles"
    await model.saveHint()
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.ritual?.date?.status, .scheduled)
    XCTAssertEqual(model.ritual?.date?.publicTeaser, "Bring a sweater")
    XCTAssertEqual(model.ritual?.plan?.privateNotes, "Candles")
    await model.saveDate()
    XCTAssertEqual(model.errorMessage, L10n.message(for: .notEditable))
    XCTAssertNotEqual(model.errorMessage, L10n.message(for: .notPlanner))
    XCTAssertEqual(model.ritual?.date?.status, .scheduled)
  }

  func testHintEditRuleAndCopy() {
    XCTAssertTrue(HintEdit.allowed(status: .draft, revealed: false))
    XCTAssertTrue(HintEdit.allowed(status: .scheduled, revealed: false))
    XCTAssertFalse(HintEdit.allowed(status: .scheduled, revealed: true))
    XCTAssertFalse(HintEdit.allowed(status: .completed, revealed: false))
    XCTAssertFalse(L10n.message(for: .notEditable).localizedCaseInsensitiveContains("planner"))
    XCTAssertTrue(L10n.message(for: .notPlanner).localizedCaseInsensitiveContains("planner"))
  }

  func testFailedMoodSaveRollsBack() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    let before = model.ritual?.moods
    XCTAssertEqual(before?.first { $0.userId == SeedID.alex }?.mood, .romance)
    backend.setOffline(true)
    await model.choose(mood: .chill)
    XCTAssertEqual(model.ritual?.moods.first { $0.userId == SeedID.alex }?.mood, .chill)
    XCTAssertEqual(model.outbox["mood"], .mood(.chill))
    XCTAssertEqual(model.errorMessage, L10n.message(for: .offline))
    backend.setOffline(false)
    await model.flush()
    XCTAssertNil(model.outbox["mood"])
    await model.refresh()
    XCTAssertEqual(model.ritual?.moods.first { $0.userId == SeedID.alex }?.mood, .chill)
    backend.markRevealed()
    let shown = model.ritual?.moods
    await model.choose(mood: .adventure)
    XCTAssertEqual(model.ritual?.moods, shown)
    XCTAssertNil(model.outbox["mood"])
    XCTAssertEqual(model.errorMessage, L10n.message(for: .notEditable))
  }

  func testRejectedMoodReplayDoesNotBlockSignOut() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    backend.setOffline(true)
    await model.choose(mood: .chill)
    XCTAssertEqual(model.outbox["mood"], .mood(.chill))
    backend.markRevealed()
    backend.setOffline(false)
    await model.flush()
    XCTAssertNil(model.outbox["mood"])
    XCTAssertEqual(model.ritual?.moods.first { $0.userId == SeedID.alex }?.mood, .romance)
    XCTAssertEqual(model.errorMessage, L10n.message(for: .notEditable))
    await model.signOut()
    XCTAssertEqual(model.screen, .login)
    XCTAssertFalse(model.signedIn)
  }

  func testFinishedDateAndPermissionDenialDropTheQueuedMood() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    backend.setOffline(true)
    await model.choose(mood: .chill)
    backend.finishDate()
    backend.setOffline(false)
    await model.flush()
    XCTAssertNil(model.outbox["mood"])
    XCTAssertEqual(model.errorMessage, L10n.message(for: .saveFailed))
    XCTAssertEqual(model.ritual?.date, nil)
    await model.signOut()
    XCTAssertEqual(model.screen, .login)
  }

  func testPermissionDeniedReplayDropsTheQueuedMood() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    backend.setOffline(true)
    await model.choose(mood: .adventure)
    backend.moodFailure = .server(code: "42501")
    backend.setOffline(false)
    await model.flush()
    XCTAssertNil(model.outbox["mood"])
    XCTAssertEqual(model.ritual?.moods.first { $0.userId == SeedID.alex }?.mood, .romance)
    XCTAssertEqual(model.errorMessage, L10n.message(for: .notEditable))
    await model.signOut()
    XCTAssertEqual(model.screen, .login)
  }

  func testScheduledMoodSavesAndRevealDoesNot() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    backend.scheduleUnrevealed()
    await model.refresh()
    XCTAssertEqual(model.ritual?.date?.status, .scheduled)
    XCTAssertEqual(model.ritual?.revealed, false)
    XCTAssertTrue(MoodChips.isEnabled(status: model.ritual?.date?.status, revealed: model.ritual?.revealed == true))
    await model.choose(mood: .fun)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.ritual?.moods.first { $0.userId == SeedID.alex }?.mood, .fun)
    backend.markRevealed()
    await model.refresh()
    XCTAssertFalse(MoodChips.isEnabled(status: model.ritual?.date?.status, revealed: model.ritual?.revealed == true))
    await model.choose(mood: .adventure)
    XCTAssertEqual(model.errorMessage, L10n.message(for: .notEditable))
    XCTAssertEqual(model.ritual?.moods.first { $0.userId == SeedID.alex }?.mood, .fun)
  }

  func testChatIsCiphertextAndThePartnerCanReadIt() async throws {
    let store = FakeStore(inMemory: true)
    let blair = SessionModel(backend: FakeBackend(store: store, cooldown: 0))
    blair.email = "blair@couple-a.test"
    await blair.sendCode()
    blair.code = "000000"
    await blair.verify()
    _ = try await blair.backend.messages()
    let alex = SessionModel(backend: FakeBackend(store: store, cooldown: 0))
    alex.email = "alex@couple-a.test"
    await alex.sendCode()
    alex.code = "000000"
    await alex.verify()
    let secret = "xylophone-harbor"
    alex.chatDraft = secret
    await alex.sendChat()
    XCTAssertNil(alex.errorMessage)
    XCTAssertEqual(alex.messages.last?.text, secret)
    let stored = store.world.chats.flatMap(\.envelopes).map(\.box).reduce(into: Data()) { $0.append($1) }
    XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains(secret))
    blair.email = "blair@couple-a.test"
    await blair.sendCode()
    blair.code = "000000"
    await blair.verify()
    XCTAssertEqual(blair.messages.last?.text, secret)
    XCTAssertEqual(blair.messages.last?.mine, false)
    XCTAssertNil(blair.chatKeyNotice)
    let replacement = ChatIdentity.generate()
    store.world.deviceKeys.append(FakeDeviceKey(
      id: replacement.id, userId: SeedID.alex, publicKey: replacement.publicKey,
      privateKey: replacement.privateKey.rawRepresentation, createdAt: Date().addingTimeInterval(10)
    ))
    await blair.refresh()
    XCTAssertEqual(blair.chatKeyNotice, L10n.chatKeyChanged)
  }

  func testChatLoadErrorsStayVisible() async throws {
    let store = FakeStore(inMemory: true)
    let backend = FakeBackend(store: store, cooldown: 0)
    let blair = SessionModel(backend: backend)
    blair.email = "blair@couple-a.test"
    await blair.sendCode()
    blair.code = "000000"
    await blair.verify()
    _ = try await blair.backend.messages()
    let alex = SessionModel(backend: backend)
    alex.email = "alex@couple-a.test"
    await alex.sendCode()
    alex.code = "000000"
    await alex.verify()
    alex.chatDraft = "hello"
    await alex.sendChat()
    XCTAssertNil(alex.errorMessage)
    XCTAssertEqual(alex.messages.count, 1)
    backend.chatFailure = .server(code: "chat")
    await alex.refresh()
    XCTAssertEqual(alex.errorMessage, L10n.message(for: .server(code: "chat")))
    XCTAssertEqual(alex.messages.count, 1)
    alex.chatDraft = String(repeating: "a", count: 2001)
    backend.chatFailure = nil
    await alex.sendChat()
    XCTAssertEqual(alex.errorMessage, L10n.message(for: .chatTooLong))
  }

  func testHintSaveRejectsAnUpdateThatTouchesNoRows() {
    XCTAssertNoThrow(try HintEdit.requireUpdated(dateRows: 1, planRows: 1))
    for (dates, plans) in [(0, 1), (1, 0), (0, 0)] {
      XCTAssertThrowsError(try HintEdit.requireUpdated(dateRows: dates, planRows: plans)) { error in
        XCTAssertEqual(error as? AppError, .notEditable)
      }
    }
  }
}
