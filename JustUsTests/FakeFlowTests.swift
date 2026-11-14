import XCTest
@testable import JustUs

@MainActor
final class FakeFlowTests: XCTestCase {
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

    await backend.signOut()
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

    await backend.signOut()
    _ = try await backend.sendCode(email: "sam@solo.test")
    _ = try await backend.verify(email: "sam@solo.test", code: "000000")
    try await backend.redeem(token: SeedID.validToken, replaceEmpty: true)
    let loaded = try await backend.ritual()
    let ritual = try XCTUnwrap(loaded)
    XCTAssertEqual(ritual.coupleId, SeedID.coupleJordan)
  }

  func testDeletionKeepsPartnerHistory() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    try await backend.deleteAccount()
    XCTAssertFalse(backend.store.world.users.contains { $0.id == SeedID.alex })
    XCTAssertTrue(backend.store.world.members.contains { $0.userId == SeedID.blair })
    XCTAssertTrue(backend.store.world.dates.contains { $0.id == SeedID.dateA })
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
}
