import Foundation

enum MoodKey: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
  case fun, romance, deep, intimacy, adventure, chill
  var id: String { rawValue }
}

enum LocationKind: String, Codable, Equatable, Sendable {
  case home, out
}

enum PlaceChoice: String, Codable, Equatable, Sendable {
  case auto, home, out
}

enum DateStatus: String, Codable, Equatable, Sendable {
  case draft, scheduled, completed, skipped, canceled
}

struct DateIdea: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var loc: LocationKind
  var mood: MoodKey
  var title: String
  var emoji: String
  var duration: String
  var cost: String
  var summary: String
  var prep: String
  var twist: String
  var question: String
}

struct FullPlan: Codable, Equatable, Sendable {
  var ideaId: String
  var title: String
  var emoji: String
  var summary: String
  var prep: String
  var twist: String
  var question: String
  var durationLabel: String
  var costLabel: String
  var mood: MoodKey
  var location: LocationKind
  var privateNotes: String?
}

struct MemberRef: Codable, Equatable, Identifiable, Sendable {
  var userId: UUID
  var displayName: String
  var memberIndex: Int
  var id: UUID { userId }
}

struct MoodVote: Codable, Equatable, Sendable {
  var userId: UUID
  var mood: MoodKey
}

struct DateCard: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var status: DateStatus
  var scheduledAt: Date
  var scheduledDate: String
  var scheduledTime: String
  var durationMinutes: Int
  var location: LocationKind
  var locationIsOverride: Bool
  var suggestedLocation: LocationKind
  var publicTeaser: String?
  var outfitHint: String?
  var revealed: Bool
  var plannerUserId: UUID
  var plannerName: String
}

struct RitualSnapshot: Codable, Equatable, Sendable {
  var coupleId: UUID
  var selfMember: MemberRef
  var partner: MemberRef?
  var inviteeName: String
  var completedCount: Int
  var weekday: Int
  var localTime: String
  var timezone: String
  var durationMinutes: Int
  var date: DateCard?
  var moods: [MoodVote]
  var isPlanner: Bool
  var revealed: Bool
  var plan: FullPlan?
}

struct MemoryNote: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var authorUserId: UUID?
  var authorName: String
  var note: String
  var mine: Bool
}

struct MemoryItem: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var emoji: String
  var summary: String?
  var location: LocationKind
  var when: Date
  var number: Int
  var notes: [MemoryNote]
  var photoPath: String?
  var photoJPEG: Data?
  var photoState: PhotoState
}

enum PhotoState: String, Codable, Equatable, Sendable {
  case empty, uploading, saved, failed
}

struct CoupleDraft: Equatable, Sendable {
  var selfName: String
  var partnerName: String
  var weekday: Int
  var localTime: String
  var timezone: String
  var durationMinutes: Int
}

struct SettingsSnapshot: Equatable, Sendable {
  var coupleId: UUID
  var selfName: String
  var partnerName: String
  var partnerJoined: Bool
  var weekday: Int
  var localTime: String
  var timezone: String
  var durationMinutes: Int
  var pendingInviteExpires: Date?
  var preferences: PushPreferences
}

struct SessionUser: Equatable, Sendable {
  var id: UUID
  var email: String?
  var displayHint: String?
}

enum MembershipKind: Equatable, Sendable {
  case none, emptySolo, kept
}

enum FieldIssue: Equatable, Sendable {
  case email, name, time, timezone, weekday, duration, note, teaser, date, code, confirm
}

enum AppError: Error, Equatable, Sendable {
  case offline
  case timeout
  case sessionExpired
  case linkExpired
  case invalid(FieldIssue)
  case invalidCode
  case expiredCode
  case cooldown(seconds: Int)
  case alreadyInCouple
  case soloNotEmpty
  case invalidInvite
  case revokedInvite
  case usedInvite
  case expiredInvite
  case coupleFull
  case selfRedeem
  case notAuthenticated
  case notPlanner
  case missingPlan
  case unavailable
  case saveFailed
  case rateLimited
  case confirmationRequired
  case unsyncedChanges
  case server(code: String)
}

enum PushKind: String, Codable, Equatable, Sendable {
  case partnerMood
  case planReady
  case inviteAccepted
  case weeklyReminder
  case inviteNudge
}

struct PushPreferences: Codable, Equatable, Sendable {
  var partnerMood: Bool
  var planReady: Bool
  var inviteAccepted: Bool
  var weeklyReminder: Bool

  static let allOn = PushPreferences(partnerMood: true, planReady: true, inviteAccepted: true, weeklyReminder: true)

  func allows(_ kind: PushKind) -> Bool {
    switch kind {
    case .partnerMood: return partnerMood
    case .planReady: return planReady
    case .inviteAccepted: return inviteAccepted
    case .weeklyReminder, .inviteNudge: return weeklyReminder
    }
  }
}

struct PushRecord: Codable, Equatable, Sendable {
  var kind: PushKind
  var sentAt: Date
  var transactional: Bool
}

enum PushDecision: Equatable, Sendable {
  case send
  case suppress(String)
  case deferUntil(Date)
}

enum AnalyticsEvent: Equatable, Sendable {
  case appOpened
  case signedIn(method: String)
  case onboardingCompleted
  case inviteSent
  case inviteRedeemed
  case moodSet
  case planSaved
  case revealed
  case memoryAdded
  case signedOut
  case accountDeleted
}

enum AppTab: String, Equatable, Hashable, Sendable {
  case week, memories, settings
}

enum AppRoute: Equatable, Sendable {
  case home
  case reveal
  case memories
  case settings
  case invite(String)
}
