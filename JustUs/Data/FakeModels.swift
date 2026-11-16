import Foundation

struct FakeUser: Codable, Equatable {
  var id: UUID
  var email: String
}

struct FakeCouple: Codable, Equatable {
  var id: UUID
  var inviteeName: String
  var weekday: Int
  var localTime: String
  var timezone: String
  var durationMinutes: Int
}

struct FakeMember: Codable, Equatable {
  var userId: UUID
  var coupleId: UUID
  var displayName: String
  var memberIndex: Int
}

struct FakeDate: Codable, Equatable {
  var id: UUID
  var coupleId: UUID
  var status: DateStatus
  var scheduledAt: Date
  var createdAt: Date
  var durationMinutes: Int
  var location: LocationKind
  var locationIsOverride: Bool
  var publicTeaser: String?
  var outfitHint: String?
  var revealedAt: Date?
  var plannerUserId: UUID
  var ideaId: String?
  var planTitle: String?
  var privateNotes: String?
  var photoJPEG: Data?
  var snapshotTitle: String?
  var snapshotEmoji: String?
  var snapshotSummary: String?
  var completedAt: Date?
}

struct FakeMood: Codable, Equatable {
  var dateId: UUID
  var userId: UUID
  var mood: MoodKey
}

struct FakeNote: Codable, Equatable {
  var id: UUID
  var dateId: UUID
  var authorUserId: UUID?
  var authorName: String
  var note: String
}

struct FakeDeviceKey: Codable, Equatable {
  var id: UUID
  var userId: UUID
  var publicKey: Data
  var privateKey: Data
}

struct FakeEnvelope: Codable, Equatable {
  var keyId: UUID
  var box: Data
}

struct FakeChat: Codable, Equatable {
  var id: UUID
  var coupleId: UUID
  var senderUserId: UUID
  var senderPublicKey: Data
  var createdAt: Date
  var envelopes: [FakeEnvelope]
}

struct FakeInvite: Codable, Equatable {
  var token: String
  var coupleId: UUID
  var inviterId: UUID
  var expires: Date
  var used: Bool
  var revoked: Bool
}

struct FakeWorld: Codable, Equatable {
  var users: [FakeUser]
  var couples: [FakeCouple]
  var members: [FakeMember]
  var dates: [FakeDate]
  var moods: [FakeMood]
  var notes: [FakeNote]
  var invites: [FakeInvite]
  var deviceKeys: [FakeDeviceKey]
  var chats: [FakeChat]
  var preferences: [String: PushPreferences]
  var sessionUserId: UUID?
  var otpSentAt: [String: Date]
  var offline: Bool

  static func seed(now: Date = Date()) -> FakeWorld {
    var world = FakeWorld(
      users: [], couples: [], members: [], dates: [], moods: [], notes: [],
      invites: [], deviceKeys: [], chats: [], preferences: [:], sessionUserId: nil, otpSentAt: [:], offline: false
    )
    SeedBuilder.build(&world, now: now)
    return world
  }
}

enum SeedID {
  static func uuid(_ value: String) -> UUID {
    UUID(uuidString: value) ?? UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID()
  }

  static let alex = uuid("11111111-1111-4111-8111-111111111111")
  static let blair = uuid("22222222-2222-4222-8222-222222222222")
  static let casey = uuid("33333333-3333-4333-8333-333333333333")
  static let drew = uuid("44444444-4444-4444-8444-444444444444")
  static let jordan = uuid("55555555-5555-4555-8555-555555555555")
  static let sam = uuid("66666666-6666-4666-8666-666666666666")
  static let riley = uuid("77777777-7777-4777-8777-777777777777")
  static let demo = uuid("88888888-8888-4888-8888-888888888888")
  static let demoPartner = uuid("99999999-9999-4999-8999-999999999999")
  static let coupleA = uuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
  static let coupleB = uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
  static let coupleJordan = uuid("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
  static let coupleSam = uuid("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
  static let coupleRiley = uuid("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
  static let coupleDemo = uuid("ffffffff-ffff-4fff-8fff-ffffffffffff")
  static let dateA = uuid("12121212-1212-4121-8121-121212121212")
  static let dateRiley = uuid("13131313-1313-4131-8131-131313131313")
  static let validToken = String(repeating: "a", count: 43)
  static let usedToken = String(repeating: "b", count: 43)
  static let fullToken = String(repeating: "c", count: 43)
  static let expiredToken = String(repeating: "d", count: 43)
}

enum SeedBuilder {
  static func build(_ world: inout FakeWorld, now: Date) {
    addCoupleA(&world, now: now)
    addCoupleB(&world, now: now)
    addJordan(&world, now: now)
    addSam(&world)
    addRiley(&world, now: now)
    addDemo(&world, now: now)
    world.invites.append(FakeInvite(
      token: SeedID.usedToken, coupleId: SeedID.coupleJordan, inviterId: SeedID.jordan,
      expires: now.addingTimeInterval(86_400), used: true, revoked: false
    ))
    world.invites.append(FakeInvite(
      token: SeedID.expiredToken, coupleId: SeedID.coupleJordan, inviterId: SeedID.jordan,
      expires: now.addingTimeInterval(-86_400), used: false, revoked: false
    ))
  }

  private static func addCoupleA(_ world: inout FakeWorld, now: Date) {
    addUser(&world, id: SeedID.alex, email: "alex@couple-a.test")
    addUser(&world, id: SeedID.blair, email: "blair@couple-a.test")
    addSpace(&world, id: SeedID.coupleA, invitee: "Blair", members: [
      (SeedID.alex, "Alex", 0), (SeedID.blair, "Blair", 1)
    ])
    let zone = "Asia/Jerusalem"
    let when = (try? ZonedTime.nextWeeklySlot(weekday: 4, time: "20:30", timeZone: zone, from: now)) ?? now
    world.dates.append(FakeDate(
      id: SeedID.dateA, coupleId: SeedID.coupleA, status: .draft, scheduledAt: when, createdAt: now,
      durationMinutes: 90, location: .home, locationIsOverride: false,
      publicTeaser: "Come hungry", outfitHint: "Cozy", revealedAt: nil,
      plannerUserId: SeedID.alex, ideaId: "h6", planTitle: "A table for two",
      privateNotes: "Only the planner knows", photoJPEG: nil,
      snapshotTitle: nil, snapshotEmoji: nil, snapshotSummary: nil, completedAt: nil
    ))
    world.moods.append(FakeMood(dateId: SeedID.dateA, userId: SeedID.alex, mood: .romance))
    // Blair planned the latest finished night, so this draft is Alex's turn.
    // One skipped week sits between two finished weeks, always just behind `now`.
    pastNight(
      &world, id: "15151515-1515-4151-8151-151515151515", status: .completed,
      at: weeksBefore(when, 3, zone), planner: SeedID.alex
    )
    pastNight(
      &world, id: "16161616-1616-4161-8161-161616161616", status: .skipped,
      at: weeksBefore(when, 2, zone), planner: SeedID.blair
    )
    pastNight(
      &world, id: "17171717-1717-4171-8171-171717171717", status: .completed,
      at: weeksBefore(when, 1, zone), planner: SeedID.blair
    )
  }

  private static func weeksBefore(_ instant: Date, _ weeks: Int, _ timeZone: String) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    calendar.firstWeekday = 1
    return calendar.date(byAdding: .weekOfYear, value: -weeks, to: instant) ?? instant
  }

  private static func pastNight(
    _ world: inout FakeWorld,
    id: String,
    status: DateStatus,
    at when: Date,
    planner: UUID
  ) {
    let finished = status == .completed
    world.dates.append(FakeDate(
      id: SeedID.uuid(id), coupleId: SeedID.coupleA, status: status, scheduledAt: when, createdAt: when,
      durationMinutes: 90, location: .home, locationIsOverride: false,
      publicTeaser: nil, outfitHint: nil, revealedAt: finished ? when : nil,
      plannerUserId: planner, ideaId: finished ? "h1" : nil, planTitle: nil,
      privateNotes: nil, photoJPEG: nil,
      snapshotTitle: finished ? "A week together" : nil, snapshotEmoji: finished ? "♥" : nil,
      snapshotSummary: nil, completedAt: finished ? when : nil
    ))
  }

  private static func addCoupleB(_ world: inout FakeWorld, now: Date) {
    addUser(&world, id: SeedID.casey, email: "casey@couple-b.test")
    addUser(&world, id: SeedID.drew, email: "drew@couple-b.test")
    addSpace(&world, id: SeedID.coupleB, invitee: "Drew", members: [
      (SeedID.casey, "Casey", 0), (SeedID.drew, "Drew", 1)
    ])
    world.invites.append(FakeInvite(
      token: SeedID.fullToken, coupleId: SeedID.coupleB, inviterId: SeedID.casey,
      expires: now.addingTimeInterval(7 * 86_400), used: false, revoked: false
    ))
  }

  private static func addJordan(_ world: inout FakeWorld, now: Date) {
    addUser(&world, id: SeedID.jordan, email: "jordan@invite.test")
    addSpace(&world, id: SeedID.coupleJordan, invitee: "Guest", members: [(SeedID.jordan, "Jordan", 0)])
    world.invites.append(FakeInvite(
      token: SeedID.validToken, coupleId: SeedID.coupleJordan, inviterId: SeedID.jordan,
      expires: now.addingTimeInterval(7 * 86_400), used: false, revoked: false
    ))
  }

  private static func addSam(_ world: inout FakeWorld) {
    addUser(&world, id: SeedID.sam, email: "sam@solo.test")
    addSpace(&world, id: SeedID.coupleSam, invitee: "Someone", members: [(SeedID.sam, "Sam", 0)])
  }

  private static func addRiley(_ world: inout FakeWorld, now: Date) {
    addUser(&world, id: SeedID.riley, email: "riley@busy.test")
    addSpace(&world, id: SeedID.coupleRiley, invitee: "Someone", members: [(SeedID.riley, "Riley", 0)])
    world.dates.append(FakeDate(
      id: SeedID.dateRiley, coupleId: SeedID.coupleRiley, status: .completed, scheduledAt: now, createdAt: now,
      durationMinutes: 90, location: .home, locationIsOverride: false,
      publicTeaser: nil, outfitHint: nil, revealedAt: now, plannerUserId: SeedID.riley,
      ideaId: "h1", planTitle: "Kept night", privateNotes: nil, photoJPEG: PhotoBytes.sample(),
      snapshotTitle: "Kept night", snapshotEmoji: "♥", snapshotSummary: "Together", completedAt: now
    ))
    world.notes.append(FakeNote(
      id: SeedID.uuid("14141414-1414-4141-8141-141414141414"),
      dateId: SeedID.dateRiley, authorUserId: SeedID.riley, authorName: "Riley", note: "We stayed in."
    ))
  }

  private static func addDemo(_ world: inout FakeWorld, now: Date) {
    addUser(&world, id: SeedID.demo, email: "demo@justus.app")
    addUser(&world, id: SeedID.demoPartner, email: "partner@justus.app")
    addSpace(&world, id: SeedID.coupleDemo, invitee: "Partner", members: [
      (SeedID.demo, "Demo", 0), (SeedID.demoPartner, "Partner", 1)
    ])
    _ = now
  }

  private static func addUser(_ world: inout FakeWorld, id: UUID, email: String) {
    world.users.append(FakeUser(id: id, email: email))
    world.preferences[id.uuidString] = .allOn
  }

  private static func addSpace(
    _ world: inout FakeWorld,
    id: UUID,
    invitee: String,
    members: [(UUID, String, Int)]
  ) {
    world.couples.append(FakeCouple(
      id: id, inviteeName: invitee, weekday: 4, localTime: "20:30",
      timezone: "Asia/Jerusalem", durationMinutes: 90
    ))
    for member in members {
      world.members.append(FakeMember(
        userId: member.0, coupleId: id, displayName: member.1, memberIndex: member.2
      ))
    }
  }
}
