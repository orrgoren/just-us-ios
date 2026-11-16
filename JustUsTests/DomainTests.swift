import XCTest
@testable import JustUs

final class DomainTests: XCTestCase {
  func testJerusalemOffsets() throws {
    let winter = try ZonedTime.zonedLocalToUtc(date: "2026-01-15", time: "20:30", timeZone: "Asia/Jerusalem")
    let summer = try ZonedTime.zonedLocalToUtc(date: "2026-07-16", time: "20:30", timeZone: "Asia/Jerusalem")
    XCTAssertEqual(ZonedTime.offsetMinutes(at: winter, zone: "Asia/Jerusalem"), 120)
    XCTAssertEqual(ZonedTime.offsetMinutes(at: summer, zone: "Asia/Jerusalem"), 180)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    XCTAssertEqual(calendar.component(.hour, from: winter), 18)
    XCTAssertEqual(calendar.component(.hour, from: summer), 17)
  }

  func testNextThursdaySlot() throws {
    let afternoon = try ZonedTime.zonedLocalToUtc(date: "2026-11-12", time: "18:00", timeZone: "Asia/Jerusalem")
    let evening = try ZonedTime.zonedLocalToUtc(date: "2026-11-12", time: "21:00", timeZone: "Asia/Jerusalem")
    let sameDay = try ZonedTime.nextWeeklySlot(weekday: 4, time: "20:30", timeZone: "Asia/Jerusalem", from: afternoon)
    let nextWeek = try ZonedTime.nextWeeklySlot(weekday: 4, time: "20:30", timeZone: "Asia/Jerusalem", from: evening)
    let sameParts = try ZonedTime.zonedParts(instant: sameDay, timeZone: "Asia/Jerusalem")
    let nextParts = try ZonedTime.zonedParts(instant: nextWeek, timeZone: "Asia/Jerusalem")
    XCTAssertEqual(sameParts.date, "2026-11-12")
    XCTAssertEqual(sameParts.time, "20:30")
    XCTAssertEqual(nextParts.date, "2026-11-19")
  }

  func testInviteHashVectors() {
    XCTAssertEqual(
      InviteRules.hash("hello"),
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )
    XCTAssertEqual(
      InviteRules.hash("א|2024-01-01|כותרת|פתק"),
      "c023e458984d230a7735bcf220beaea3d0c6f67dfa87899f680d9416431aecb5"
    )
  }

  func testContrastMeetsBodyAA() {
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ink, Palette.canvas), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.muted, Palette.canvas), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ivory, Palette.wine), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ink, Palette.blush), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ink, Palette.champagne), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.muted, Palette.blush), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.canvas, Palette.wine), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.inkDark, Palette.canvasDark), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.mutedDark, Palette.canvasDark), 4.5)
  }

  func testRevealCopyHasNoSecrets() {
    let body = PushPolicy.body(kind: .planReady, partnerName: "Blair")
    XCTAssertEqual(body, "Your date is ready to reveal.")
    XCTAssertTrue(PushPolicy.forbiddenFragments(in: body, secrets: ["A table for two", "Cozy", "home"]).isEmpty)
  }

  func testNightSendsAndTheOtherRulesStay() throws {
    var calendar = Calendar(identifier: .gregorian)
    let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Jerusalem"))
    calendar.timeZone = zone
    var parts = DateComponents()
    parts.year = 2026
    parts.month = 11
    parts.day = 12
    parts.hour = 23
    let late = try XCTUnwrap(calendar.date(from: parts))
    XCTAssertEqual(
      PushPolicy.decide(kind: .partnerMood, now: late, timeZone: zone, history: [], preferences: .allOn),
      .send
    )
    parts.hour = 3
    let early = try XCTUnwrap(calendar.date(from: parts))
    XCTAssertEqual(
      PushPolicy.decide(kind: .weeklyReminder, now: early, timeZone: zone, history: [], preferences: .allOn),
      .send
    )
    parts.hour = 12
    let noon = try XCTUnwrap(calendar.date(from: parts))
    let prior = PushRecord(kind: .weeklyReminder, sentAt: noon, transactional: false)
    XCTAssertEqual(
      PushPolicy.decide(kind: .partnerMood, now: noon.addingTimeInterval(60), timeZone: zone, history: [prior], preferences: .allOn),
      .suppress("daily_non_transactional")
    )
    XCTAssertEqual(
      PushPolicy.decide(kind: .planReady, now: noon.addingTimeInterval(60), timeZone: zone, history: [prior], preferences: .allOn),
      .suppress("daily_non_transactional")
    )
    let recentMood = PushRecord(kind: .partnerMood, sentAt: noon, transactional: false)
    XCTAssertEqual(
      PushPolicy.decide(kind: .partnerMood, now: noon.addingTimeInterval(3600), timeZone: zone, history: [recentMood], preferences: .allOn),
      .suppress("deduped_6h")
    )
    parts.day = 11
    parts.hour = 20
    let previousEvening = try XCTUnwrap(calendar.date(from: parts))
    let previousMood = PushRecord(kind: .partnerMood, sentAt: previousEvening, transactional: false)
    XCTAssertEqual(
      PushPolicy.decide(kind: .partnerMood, now: early, timeZone: zone, history: [previousMood], preferences: .allOn),
      .send
    )
    XCTAssertEqual(
      PushPolicy.decide(kind: .inviteNudge, now: noon, timeZone: zone, history: [], preferences: .allOn, inviteAgeHours: 10),
      .suppress("outside_nudge_window")
    )
    XCTAssertEqual(
      PushPolicy.decide(kind: .inviteNudge, now: noon, timeZone: zone, history: [], preferences: .allOn, inviteAgeHours: 24),
      .send
    )
  }

  func testPlaceRhythmAndPhotoPolicy() throws {
    XCTAssertEqual(try Recommendation.suggestedLocation(completedCount: 0), .home)
    XCTAssertEqual(try Recommendation.suggestedLocation(completedCount: 3), .out)
    XCTAssertEqual(try Recommendation.defaultPlannerIndex(completedCount: 0), 0)
    XCTAssertEqual(try Recommendation.defaultPlannerIndex(completedCount: 1), 1)
    XCTAssertTrue(PhotoSavePolicy.shouldCommitPath(uploadSucceeded: true))
    XCTAssertFalse(PhotoSavePolicy.shouldCommitPath(uploadSucceeded: false))
    XCTAssertTrue(PhotoSavePolicy.shouldDeleteObject(uploadSucceeded: true, recordSucceeded: false))
    XCTAssertTrue(AccountDeletionPolicy.closesTheSharedSpace)
  }

  func testDeepLinkInvite() throws {
    let url = try XCTUnwrap(URL(string: "justus://invite/\(String(repeating: "a", count: 43))"))
    XCTAssertEqual(DeepLinks.route(from: url), .invite(String(repeating: "a", count: 43)))
    XCTAssertEqual(DeepLinks.route(userInfo: ["type": "plan_ready"]), .reveal)
    XCTAssertEqual(DeepLinks.pushRoute("inviteNudge"), .settings)
  }

  func testLiveTestsRefuseProductionHost() throws {
    guard ProcessInfo.processInfo.environment["JUSTUS_ALLOW_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Live tests stay off unless JUSTUS_ALLOW_LIVE_TESTS=1")
    }
    XCTAssertFalse(AppConfig.refusesProductionLiveTests, "Refusing the production Supabase project")
  }
}
