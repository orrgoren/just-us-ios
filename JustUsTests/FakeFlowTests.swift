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
}
