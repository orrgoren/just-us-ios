import XCTest
@testable import JustUs

@MainActor
final class SwapSkipTests: XCTestCase {
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

  func testASkipAfterASwapKeepsThatPlanner() async throws {
    let store = FakeStore(inMemory: true)
    let backend = FakeBackend(store: store, cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    let opened = try await backend.ritual()
    let before = try XCTUnwrap(opened)
    XCTAssertEqual(before.date?.plannerUserId, SeedID.alex)
    try await backend.swapPlanner()
    try await backend.skipWeek()
    let loaded = try await backend.ritual()
    let held = try XCTUnwrap(loaded)
    XCTAssertEqual(held.date?.plannerUserId, SeedID.blair)
    XCTAssertFalse(held.isPlanner)
    let again = PlannerTurn.nextPlanner(nights: nights(store, before.coupleId), members: members(store, before.coupleId))
    XCTAssertEqual(again, SeedID.blair)
    XCTAssertEqual(held.date?.plannerUserId, again)
  }

  private func nights(_ store: FakeStore, _ coupleId: UUID) -> [DatedNight] {
    store.world.dates.filter { $0.coupleId == coupleId }.map {
      DatedNight(status: $0.status, scheduledAt: $0.scheduledAt, createdAt: $0.createdAt, plannerUserId: $0.plannerUserId)
    }
  }

  private func members(_ store: FakeStore, _ coupleId: UUID) -> [MemberRef] {
    store.world.members.filter { $0.coupleId == coupleId }.map {
      MemberRef(userId: $0.userId, displayName: $0.displayName, memberIndex: $0.memberIndex)
    }
  }
}
