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
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.accentOnDark, Palette.canvasDark), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ivory, Palette.winePressed), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ink, Palette.blushPressed), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.inkDark, Palette.secondaryDark), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.inkDark, Palette.secondaryDarkPressed), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.accentOnDark, Palette.secondaryDark), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.muted, Palette.champagne), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.mutedDark, Palette.disabledFillDark), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.wine, Palette.blush), 4.5)
    XCTAssertEqual(Palette.moodSelected(.romance), Palette.wine)
    for mood in MoodKey.allCases {
      XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ivory, Palette.moodSelected(mood)), 4.5, String(describing: mood))
      XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ivory, Palette.moodSelectedDark(mood)), 4.5, String(describing: mood))
      XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.moodSelectedDark(mood), Palette.canvasDark), 3, String(describing: mood))
      XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.moodBorderDark(mood), Palette.canvasDark), 3, String(describing: mood))
      XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.moodBorderDark(mood), Palette.moodTintDark(mood)), 3, String(describing: mood))
      XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ink, Palette.moodTint(mood)), 4.5, String(describing: mood))
      XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.inkDark, Palette.moodTintDark(mood)), 4.5, String(describing: mood))
    }
  }

  func testMoodReplayMapsAPermissionDenial() {
    XCTAssertEqual(ErrorMap.moodReplay(AppError.server(code: "42501")), .notEditable)
    XCTAssertEqual(ErrorMap.moodReplay(AppError.notEditable), .notEditable)
    XCTAssertEqual(ErrorMap.moodReplay(AppError.saveFailed), .saveFailed)
    XCTAssertEqual(ErrorMap.moodReplay(AppError.server(code: "23505")), .server(code: "23505"))
    XCTAssertEqual(ErrorMap.moodReplay(AppError.offline), .offline)
  }

  func testMoodChipsDisableOnceRevealed() {
    XCTAssertTrue(MoodChips.isEnabled(status: .draft, revealed: false))
    XCTAssertTrue(MoodChips.isEnabled(status: .scheduled, revealed: false))
    XCTAssertFalse(MoodChips.isEnabled(status: .scheduled, revealed: true))
    XCTAssertFalse(MoodChips.isEnabled(status: .completed, revealed: true))
    XCTAssertFalse(MoodChips.isEnabled(status: nil, revealed: false))
  }

  func testMoodStaysEditableUntilReveal() {
    XCTAssertTrue(MoodEdit.allowed(status: .draft, revealed: false))
    XCTAssertTrue(MoodEdit.allowed(status: .scheduled, revealed: false))
    XCTAssertFalse(MoodEdit.allowed(status: .scheduled, revealed: true))
    XCTAssertFalse(MoodEdit.allowed(status: .completed, revealed: false))
    XCTAssertFalse(MoodEdit.allowed(status: .skipped, revealed: false))
    XCTAssertFalse(MoodEdit.allowed(status: nil, revealed: false))
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

  func testPlannerAlternatesFromTheLastPlannedNight() throws {
    let alex = MemberRef(userId: SeedID.alex, displayName: "Alex", memberIndex: 0)
    let blair = MemberRef(userId: SeedID.blair, displayName: "Blair", memberIndex: 1)
    let members = [blair, alex]
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [], members: members), SeedID.alex)
    let finished = try night("2026-11-12", .completed, SeedID.blair)
    let skipped = try night("2026-11-19", .skipped, SeedID.alex)
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [finished, skipped], members: members), SeedID.alex)
    let scheduled = try night("2026-11-19", .scheduled, SeedID.alex)
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [finished, scheduled], members: members), SeedID.blair)
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [finished], members: [alex]), SeedID.alex)
  }

  func testOneSkipAMonthKeepsTheWeeksTogether() throws {
    let kept = try [
      night("2026-10-29", .completed, SeedID.alex),
      night("2026-11-05", .skipped, SeedID.blair),
      night("2026-11-12", .completed, SeedID.blair)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: kept, timeZone: "Asia/Jerusalem"), 2)
    let secondSkip = try [
      night("2026-11-05", .completed, SeedID.alex),
      night("2026-11-12", .skipped, SeedID.blair),
      night("2026-11-19", .skipped, SeedID.alex)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: secondSkip, timeZone: "Asia/Jerusalem"), 0)
    let gap = try [
      night("2026-10-29", .completed, SeedID.alex),
      night("2026-11-12", .completed, SeedID.blair)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: gap, timeZone: "Asia/Jerusalem"), 1)
    XCTAssertEqual(TogetherStreak.weeks(nights: [try night("2026-11-12", .draft, SeedID.alex)], timeZone: "Asia/Jerusalem"), 0)
    let yearTurn = try [
      night("2026-12-31", .completed, SeedID.alex),
      night("2027-01-07", .completed, SeedID.blair)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: yearTurn, timeZone: "Asia/Jerusalem"), 2)
    let lines = [
      L10n.weeksInARow(1), L10n.weeksInARow(2), L10n.yourTurnToPlan,
      L10n.partnerTurn("Blair"), L10n.partnerPlanning("Blair")
    ]
    for line in lines {
      XCTAssertFalse(line.localizedCaseInsensitiveContains("miss"))
      XCTAssertFalse(line.localizedCaseInsensitiveContains("break"))
      XCTAssertFalse(line.localizedCaseInsensitiveContains("lose"))
      XCTAssertFalse(line.localizedCaseInsensitiveContains("only"))
    }
    XCTAssertEqual(L10n.weeksInARow(1), "One week together")
    XCTAssertEqual(L10n.weeksInARow(2), "2 weeks in a row")
  }

  private func night(_ day: String, _ status: DateStatus, _ planner: UUID) throws -> DatedNight {
    DatedNight(
      status: status,
      scheduledAt: try ZonedTime.zonedLocalToUtc(date: day, time: "20:30", timeZone: "Asia/Jerusalem"),
      plannerUserId: planner
    )
  }

  func testLiveTestsRefuseProductionHost() throws {
    guard ProcessInfo.processInfo.environment["JUSTUS_ALLOW_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Live tests stay off unless JUSTUS_ALLOW_LIVE_TESTS=1")
    }
    XCTAssertFalse(AppConfig.refusesProductionLiveTests, "Refusing the production Supabase project")
  }
}
