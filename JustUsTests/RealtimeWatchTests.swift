import XCTest
@testable import JustUs

final class RealtimeWatchTests: XCTestCase {
  func testSubscribeOnceUntilTheIdChangesOrTheSocketDrops() {
    let couple = UUID()
    let other = UUID()
    let stay = RealtimeWatch.Plan(subscribe: false, removeCurrent: false)
    let rejoin = RealtimeWatch.Plan(subscribe: true, removeCurrent: true)

    let fresh = RealtimeWatch.plan(current: nil, requested: couple, presence: .down)
    XCTAssertEqual(fresh, RealtimeWatch.Plan(subscribe: true, removeCurrent: false))
    XCTAssertEqual(
      RealtimeWatch.plan(current: couple, requested: couple, presence: .subscribed),
      stay
    )
    XCTAssertEqual(
      RealtimeWatch.plan(current: couple, requested: couple, presence: .subscribing),
      stay
    )
    XCTAssertEqual(
      RealtimeWatch.plan(current: couple, requested: couple, presence: .down),
      rejoin
    )
    XCTAssertEqual(
      RealtimeWatch.plan(current: couple, requested: other, presence: .subscribed),
      rejoin
    )
    XCTAssertEqual(
      RealtimeWatch.plan(current: couple, requested: other, presence: .subscribing),
      rejoin
    )
  }

  func testALiveWatchDoesNotJoinAgain() {
    var socket = WatchScript()
    let couple = UUID()
    let other = UUID()
    socket.ensure(couple)
    socket.ensure(couple)
    XCTAssertEqual(socket.joins, 1)
    XCTAssertEqual(socket.removals, 0)

    socket.presence = .subscribing
    socket.ensure(couple)
    XCTAssertEqual(socket.joins, 1)

    socket.presence = .down
    socket.ensure(couple)
    XCTAssertEqual(socket.joins, 2)
    XCTAssertEqual(socket.removals, 1)
    XCTAssertEqual(socket.current, couple)

    socket.ensure(other)
    XCTAssertEqual(socket.current, other)
    XCTAssertEqual(socket.joins, 3)
    XCTAssertEqual(socket.removals, 2)
  }
}

/// Applies ``RealtimeWatch/plan`` the way ``LiveWatch`` does: keep a live
/// channel, and remove the previous one before joining again.
private struct WatchScript {
  var current: UUID?
  var presence: RealtimeWatch.Presence = .down
  var joins = 0
  var removals = 0

  mutating func ensure(_ id: UUID) {
    let plan = RealtimeWatch.plan(current: current, requested: id, presence: presence)
    guard plan.subscribe else { return }
    if plan.removeCurrent {
      removals += 1
    }
    current = id
    presence = .subscribed
    joins += 1
  }
}
