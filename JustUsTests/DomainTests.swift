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
      .send
    )
    XCTAssertEqual(
      PushPolicy.decide(kind: .planReady, now: noon.addingTimeInterval(60), timeZone: zone, history: [prior], preferences: .allOn),
      .suppress("daily_non_transactional")
    )
    XCTAssertEqual(
      PushPolicy.decide(kind: .chatMessage, now: late, timeZone: zone, history: [prior], preferences: .allOn),
      .send
    )
    let secret = "The tea is in the blue tin"
    let body = PushPolicy.body(kind: .chatMessage, partnerName: "Blair")
    XCTAssertEqual(body, "New message")
    XCTAssertTrue(ChatPushCopy.isQuiet(body))
    XCTAssertFalse(body.localizedCaseInsensitiveContains("Blair"))
    XCTAssertTrue(PushPolicy.forbiddenFragments(in: body, secrets: [secret]).isEmpty)
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

  func testChatRoundTripHidesTheText() throws {
    let aliceUser = UUID()
    let blairUser = UUID()
    let alice = ChatIdentity.generate()
    let blair = ChatIdentity.generate()
    let messageId = UUID()
    let secret = "xylophone-harbor"
    let envelopes = try sealed(secret, messageId: messageId, alice: alice, aliceUser: aliceUser, blair: blair, blairUser: blairUser)
    let stored = envelopes.map(\.box).reduce(into: Data()) { $0.append($1) }
    XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains(secret))
    XCTAssertEqual(try open(envelopes, messageId: messageId, identity: blair, sender: alice, senderUser: aliceUser, recipientUser: blairUser), secret)
    XCTAssertEqual(try open(envelopes, messageId: messageId, identity: alice, sender: alice, senderUser: aliceUser, recipientUser: aliceUser), secret)
    let stranger = ChatIdentity.generate()
    XCTAssertThrowsError(try open(envelopes, messageId: messageId, identity: stranger, sender: alice, senderUser: aliceUser, recipientUser: blairUser))
  }

  func testChatRejectsTamperForgeryReflectionAndReplay() throws {
    let aliceUser = UUID()
    let blairUser = UUID()
    let alice = ChatIdentity.generate()
    let blair = ChatIdentity.generate()
    let messageId = UUID()
    let envelopes = try sealed("tea", messageId: messageId, alice: alice, aliceUser: aliceUser, blair: blair, blairUser: blairUser)
    var tampered = envelopes
    tampered[0].box[tampered[0].box.count - 1] ^= 0xff
    XCTAssertThrowsError(try open(tampered, messageId: messageId, identity: blair, sender: alice, senderUser: aliceUser, recipientUser: blairUser))

    let forged = ChatIdentity.generate()
    XCTAssertThrowsError(try open(envelopes, messageId: messageId, identity: blair, sender: forged, senderUser: aliceUser, recipientUser: blairUser))
    XCTAssertFalse(SenderKey.trusted(
      sender: forged.publicKey, senderUserId: aliceUser,
      keys: [(userId: aliceUser, publicKey: alice.publicKey)]
    ))
    XCTAssertTrue(SenderKey.trusted(
      sender: alice.publicKey, senderUserId: aliceUser,
      keys: [(userId: aliceUser, publicKey: alice.publicKey)]
    ))

    XCTAssertThrowsError(try open(envelopes, messageId: messageId, identity: blair, sender: alice, senderUser: blairUser, recipientUser: aliceUser))
    let reflected = [ChatEnvelope(keyId: alice.id, box: envelopes.first { $0.keyId == blair.id }?.box ?? Data())]
    XCTAssertThrowsError(try open(reflected, messageId: messageId, identity: alice, sender: blair, senderUser: blairUser, recipientUser: aliceUser))

    XCTAssertThrowsError(try open(envelopes, messageId: UUID(), identity: blair, sender: alice, senderUser: aliceUser, recipientUser: blairUser))
  }

  func testChatLengthIsByteAccurate() throws {
    XCTAssertThrowsError(try ChatText.normalized("   ")) { error in
      XCTAssertEqual(error as? AppError, .invalid(.note))
    }
    XCTAssertEqual(try ChatText.normalized(String(repeating: "a", count: 1000)).count, 1000)
    XCTAssertEqual(try ChatText.normalized(String(repeating: "🙂", count: 1000)).count, 1000)
    XCTAssertThrowsError(try ChatText.normalized(String(repeating: "a", count: 1001))) { error in
      XCTAssertEqual(error as? AppError, .chatTooLong)
    }
    let family = String(repeating: "👨‍👩‍👧‍👦", count: 1000)
    XCTAssertEqual(family.count, 1000)
    XCTAssertGreaterThan(family.utf8.count, ChatText.maxBytes)
    XCTAssertThrowsError(try ChatText.normalized(family)) { error in
      XCTAssertEqual(error as? AppError, .chatTooLong)
    }
    let heavy = "e" + String(repeating: "\u{0301}", count: ChatText.maxBytes)
    XCTAssertEqual(heavy.count, 1)
    XCTAssertGreaterThan(heavy.utf8.count, ChatText.maxBytes)
    XCTAssertThrowsError(try ChatText.normalized(heavy)) { error in
      XCTAssertEqual(error as? AppError, .chatTooLong)
    }
    XCTAssertEqual(L10n.message(for: .chatTooLong), L10n.chatTooLong)
    XCTAssertTrue(L10n.chatTooLong.contains("1,000"))
    XCTAssertTrue(L10n.chatTooLong.contains("5,600"))
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.ink, Palette.canvas), 4.5)
    XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.inkDark, Palette.canvasDark), 4.5)
  }

  func testChatKeepsTheCurrentKeyAndTheNewestPartnerKeys() {
    let sender = UUID()
    let partner = UUID()
    let current = UUID()
    let older = Date(timeIntervalSince1970: 1)
    let keys = (0..<5).map { index in
      (
        id: UUID(), userId: sender, publicKey: Data([UInt8(index)]),
        createdAt: older.addingTimeInterval(TimeInterval(index)), retired: false
      )
    }
    let currentKey = (id: current, userId: sender, publicKey: Data([9]), createdAt: older, retired: false)
    let partnerKeys = (0..<4).map { index in
      (
        id: UUID(), userId: partner, publicKey: Data([UInt8(20 + index)]),
        createdAt: older.addingTimeInterval(TimeInterval(index)), retired: false
      )
    }
    let retiredPartner = (
      id: UUID(), userId: partner, publicKey: Data([99]),
      createdAt: older.addingTimeInterval(50), retired: true
    )
    let chosen = ChatRecipients.choose(
      senderUserId: sender, senderKeyId: current, keys: [currentKey, retiredPartner] + keys + partnerKeys
    )
    let own = chosen.filter { $0.userId == sender }
    XCTAssertEqual(own.count, 3)
    XCTAssertEqual(own.first?.keyId, current)
    XCTAssertEqual(chosen.filter { $0.userId == partner }.count, 3)
    XCTAssertFalse(chosen.contains { $0.keyId == retiredPartner.id })
  }

  func testMaxBytesStillFitInEightEnvelopes() throws {
    let sender = ChatIdentity.generate()
    let senderUser = UUID()
    let targets = (0..<8).map { _ -> ChatTarget in
      let key = ChatIdentity.generate()
      return ChatTarget(keyId: key.id, userId: UUID(), publicKey: key.publicKey)
    }
    let envelopes = try ChatCrypto.seal(
      text: String(repeating: "a", count: ChatText.maxBytes),
      messageId: UUID(), senderUserId: senderUser, from: sender, to: targets
    )
    let wires = envelopes.map { EnvelopeWire(keyId: $0.keyId, box: ChatCoding.text($0.box)) }
    let data = try JSONEncoder().encode(wires)
    XCTAssertLessThanOrEqual(data.count, 65_536)
  }

  func testSignOutRetiresOnlyAfterTheTokenDelete() async throws {
    var events: [String] = []
    do {
      try await ChatSignOut.perform(
        deleteToken: { events.append("delete"); throw AppError.signOutBlocked },
        retire: { events.append("retire") },
        authSignOut: { events.append("auth") }
      )
      XCTFail("expected the token delete to stop sign-out")
    } catch let error as AppError {
      XCTAssertEqual(error, .signOutBlocked)
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertEqual(events, ["delete"])

    events = []
    try await ChatSignOut.perform(
      deleteToken: { events.append("delete") },
      retire: { events.append("retire") },
      authSignOut: { events.append("auth") }
    )
    XCTAssertEqual(events, ["delete", "retire", "auth"])

    events = []
    try await ChatSignOut.perform(
      deleteToken: { events.append("delete") },
      retire: { events.append("retire"); throw AppError.sessionExpired },
      authSignOut: { events.append("auth") }
    )
    XCTAssertEqual(events, ["delete", "retire", "auth"])

    events = []
    do {
      try await ChatSignOut.perform(
        deleteToken: { events.append("delete") },
        retire: { events.append("retire"); throw AppError.offline },
        authSignOut: { events.append("auth") }
      )
      XCTFail("expected a network failure to keep the session")
    } catch let error as AppError {
      XCTAssertEqual(error, .offline)
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertEqual(events, ["delete", "retire"])
    XCTAssertTrue(ChatSignOut.continues(after: AppError.notAuthenticated))
    XCTAssertTrue(ChatSignOut.continues(after: AppError.server(code: "PGRST116")))
    XCTAssertFalse(ChatSignOut.continues(after: AppError.offline))
    XCTAssertFalse(ChatSignOut.continues(after: AppError.server(code: "14042")))
  }

  func testChatWindowShowsTheNewestHundred() {
    let lines = (0..<105).map { index in
      ChatLine(
        id: UUID(), senderUserId: UUID(), text: "\(index)",
        createdAt: Date(timeIntervalSince1970: TimeInterval(index)), mine: false, unreadable: false
      )
    }
    let shown = ChatWindow.chronological(lines)
    XCTAssertEqual(shown.count, 100)
    XCTAssertEqual(shown.first?.text, "5")
    XCTAssertEqual(shown.last?.text, "104")
  }

  func testAPartnerKeyChangeIsNotTheFirstSighting() {
    let first = ["a"]
    XCTAssertFalse(PartnerKeyMemory.changed(previous: [String](), current: first))
    XCTAssertFalse(PartnerKeyMemory.changed(previous: first, current: first))
    XCTAssertTrue(PartnerKeyMemory.changed(previous: first, current: ["a", "b"]))
  }

  func testNotifyFailureIsVisibleToTests() {
    final class Notes: @unchecked Sendable {
      var values: [String] = []
    }
    let notes = Notes()
    PushFailureLog.handler = { notes.values.append($0) }
    defer { PushFailureLog.handler = nil }
    PushFailureLog.record(AppError.saveFailed)
    XCTAssertEqual(notes.values, ["send-push failed"])
  }

  private func sealed(
    _ text: String, messageId: UUID, alice: ChatIdentity, aliceUser: UUID, blair: ChatIdentity, blairUser: UUID
  ) throws -> [ChatEnvelope] {
    try ChatCrypto.seal(
      text: text, messageId: messageId, senderUserId: aliceUser, from: alice,
      to: [
        ChatTarget(keyId: blair.id, userId: blairUser, publicKey: blair.publicKey),
        ChatTarget(keyId: alice.id, userId: aliceUser, publicKey: alice.publicKey)
      ]
    )
  }

  private func open(
    _ envelopes: [ChatEnvelope], messageId: UUID, identity: ChatIdentity, sender: ChatIdentity,
    senderUser: UUID, recipientUser: UUID
  ) throws -> String {
    try ChatCrypto.open(
      envelopes: envelopes, identity: identity, messageId: messageId,
      senderUserId: senderUser, recipientUserId: recipientUser, senderPublic: sender.publicKey
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
    let swapped = try night("2026-11-19", .skipped, SeedID.blair)
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [finished, swapped], members: members), SeedID.blair)
    let scheduled = try night("2026-11-19", .scheduled, SeedID.alex)
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [finished, scheduled], members: members), SeedID.blair)
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [finished], members: [alex]), SeedID.alex)
    let sameSlot = try jerusalem("2026-11-12", "20:30")
    let earlier = DatedNight(
      status: .scheduled, scheduledAt: sameSlot, createdAt: sameSlot.addingTimeInterval(-60), plannerUserId: SeedID.alex
    )
    let later = DatedNight(
      status: .completed, scheduledAt: sameSlot, createdAt: sameSlot, plannerUserId: SeedID.blair
    )
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [earlier, later], members: members), SeedID.alex)
    XCTAssertEqual(PlannerTurn.nextPlanner(nights: [later, earlier], members: members), SeedID.alex)
  }

  func testOneSkipAMonthKeepsTheWeeksTogether() throws {
    let now = try jerusalem("2026-11-16", "12:00")
    let kept = try [
      night("2026-10-29", .completed, SeedID.alex),
      night("2026-11-05", .skipped, SeedID.blair),
      night("2026-11-12", .completed, SeedID.blair)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: kept, timeZone: "Asia/Jerusalem", now: now), 2)
    let secondSkip = try [
      night("2026-11-05", .completed, SeedID.alex),
      night("2026-11-12", .skipped, SeedID.blair),
      night("2026-11-19", .skipped, SeedID.alex)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: secondSkip, timeZone: "Asia/Jerusalem", now: now), 0)
    let gap = try [
      night("2026-10-29", .completed, SeedID.alex),
      night("2026-11-12", .completed, SeedID.blair)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: gap, timeZone: "Asia/Jerusalem", now: now), 1)
    XCTAssertEqual(
      TogetherStreak.weeks(nights: [try night("2026-11-12", .draft, SeedID.alex)], timeZone: "Asia/Jerusalem", now: now),
      0
    )
    let yearTurn = try [
      night("2026-12-31", .completed, SeedID.alex),
      night("2027-01-07", .completed, SeedID.blair)
    ]
    XCTAssertEqual(
      TogetherStreak.weeks(nights: yearTurn, timeZone: "Asia/Jerusalem", now: try jerusalem("2027-01-07", "21:00")),
      2
    )
    let lastWeekOnly = try [night("2026-11-12", .completed, SeedID.alex)]
    XCTAssertEqual(TogetherStreak.weeks(nights: lastWeekOnly, timeZone: "Asia/Jerusalem", now: now), 1)
    let olderThanLastWeek = try [night("2026-11-05", .completed, SeedID.alex)]
    XCTAssertEqual(TogetherStreak.weeks(nights: olderThanLastWeek, timeZone: "Asia/Jerusalem", now: now), 0)
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

  func testARunOlderThanLastWeekEnds() throws {
    let august = try [
      night("2026-08-06", .completed, SeedID.alex),
      night("2026-08-13", .completed, SeedID.blair),
      night("2026-08-20", .completed, SeedID.alex)
    ]
    XCTAssertEqual(
      TogetherStreak.weeks(nights: august, timeZone: "Asia/Jerusalem", now: try jerusalem("2026-11-16", "12:00")),
      0
    )
    XCTAssertEqual(
      TogetherStreak.weeks(nights: august, timeZone: "Asia/Jerusalem", now: try jerusalem("2026-08-20", "21:00")),
      3
    )
  }

  func testSundayWeekKeepsSundayWithMonday() throws {
    let saturdayAndSunday = try [
      night("2026-11-14", "23:30", .completed, SeedID.alex),
      night("2026-11-15", "00:30", .completed, SeedID.blair)
    ]
    XCTAssertEqual(
      TogetherStreak.weeks(
        nights: saturdayAndSunday, timeZone: "Asia/Jerusalem", now: try jerusalem("2026-11-15", "12:00")
      ),
      2
    )
    let sundayAndMonday = try [
      night("2026-11-15", "20:30", .completed, SeedID.alex),
      night("2026-11-16", "00:30", .completed, SeedID.blair)
    ]
    XCTAssertEqual(
      TogetherStreak.weeks(
        nights: sundayAndMonday, timeZone: "Asia/Jerusalem", now: try jerusalem("2026-11-16", "12:00")
      ),
      1
    )
  }

  func testJerusalemDSTDoesNotMergeSaturdayIntoSunday() throws {
    let boundary = try [
      night("2026-10-24", "23:30", .completed, SeedID.alex),
      night("2026-10-25", "00:30", .completed, SeedID.blair)
    ]
    XCTAssertEqual(
      TogetherStreak.weeks(
        nights: boundary, timeZone: "Asia/Jerusalem", now: try jerusalem("2026-10-25", "12:00")
      ),
      2
    )
    let afterTheFallback = try [
      night("2026-10-25", "00:30", .completed, SeedID.alex),
      night("2026-10-25", "02:30", .completed, SeedID.blair)
    ]
    XCTAssertEqual(
      TogetherStreak.weeks(
        nights: afterTheFallback, timeZone: "Asia/Jerusalem", now: try jerusalem("2026-10-25", "12:00")
      ),
      1
    )
  }

  func testTwoSkipsInARowEndTheStreak() throws {
    let acrossMonths = try [
      night("2026-01-22", .completed, SeedID.alex),
      night("2026-01-29", .skipped, SeedID.blair),
      night("2026-02-05", .skipped, SeedID.alex)
    ]
    let february = try jerusalem("2026-02-05", "21:00")
    XCTAssertEqual(TogetherStreak.weeks(nights: acrossMonths, timeZone: "Asia/Jerusalem", now: february), 0)
    let separated = try [
      night("2026-01-15", .completed, SeedID.alex),
      night("2026-01-22", .skipped, SeedID.blair),
      night("2026-01-29", .completed, SeedID.alex),
      night("2026-02-05", .skipped, SeedID.blair)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: separated, timeZone: "Asia/Jerusalem", now: february), 2)
    let newerThanThePair = try [
      night("2026-01-15", .completed, SeedID.alex),
      night("2026-01-22", .skipped, SeedID.blair),
      night("2026-01-29", .skipped, SeedID.alex),
      night("2026-02-05", .completed, SeedID.blair)
    ]
    XCTAssertEqual(TogetherStreak.weeks(nights: newerThanThePair, timeZone: "Asia/Jerusalem", now: february), 1)
  }

  private func jerusalem(_ day: String, _ time: String) throws -> Date {
    try ZonedTime.zonedLocalToUtc(date: day, time: time, timeZone: "Asia/Jerusalem")
  }

  private func night(_ day: String, _ status: DateStatus, _ planner: UUID) throws -> DatedNight {
    try night(day, "20:30", status, planner)
  }

  private func night(_ day: String, _ time: String, _ status: DateStatus, _ planner: UUID) throws -> DatedNight {
    let when = try jerusalem(day, time)
    return DatedNight(status: status, scheduledAt: when, createdAt: when, plannerUserId: planner)
  }

  func testLiveTestsRefuseProductionHost() throws {
    guard ProcessInfo.processInfo.environment["JUSTUS_ALLOW_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Live tests stay off unless JUSTUS_ALLOW_LIVE_TESTS=1")
    }
    XCTAssertFalse(AppConfig.refusesProductionLiveTests, "Refusing the production Supabase project")
  }
}
