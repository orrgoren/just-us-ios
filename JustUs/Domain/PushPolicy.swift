import Foundation

enum PushPolicy {
  static let quietStartHour = 22
  static let quietEndHour = 8

  static func isQuietHour(_ date: Date, timeZone: TimeZone) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let hour = calendar.component(.hour, from: date)
    return hour >= quietStartHour || hour < quietEndHour
  }

  static func nextQuietEnd(_ date: Date, timeZone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let hour = calendar.component(.hour, from: date)
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = quietEndHour
    components.minute = 0
    components.second = 0
    let today = calendar.date(from: components) ?? date
    if hour < quietEndHour { return today }
    return calendar.date(byAdding: .day, value: 1, to: today) ?? today
  }

  static func isTransactional(_ kind: PushKind) -> Bool {
    switch kind {
    case .planReady: return true
    case .partnerMood, .inviteAccepted, .weeklyReminder, .inviteNudge: return false
    }
  }

  static func decide(
    kind: PushKind,
    now: Date,
    timeZone: TimeZone,
    history: [PushRecord],
    preferences: PushPreferences,
    inviteAgeHours: Double? = nil
  ) -> PushDecision {
    guard preferences.allows(kind) else { return .suppress("preference") }
    if isQuietHour(now, timeZone: timeZone) {
      return .deferUntil(nextQuietEnd(now, timeZone: timeZone))
    }
    switch kind {
    case .partnerMood, .inviteAccepted:
      let recent = history.contains { $0.kind == kind && now.timeIntervalSince($0.sentAt) < 6 * 3600 }
      if recent { return .suppress("deduped_6h") }
    case .inviteNudge:
      guard let age = inviteAgeHours else { return .suppress("no_invite") }
      let inFirst = (23.5...24.5).contains(age)
      let inSecond = (71.5...72.5).contains(age)
      guard inFirst || inSecond else { return .suppress("outside_nudge_window") }
      if history.contains(where: { $0.kind == .inviteNudge && $0.sentAt.timeIntervalSince1970 > 0 && age >= 72 && now.timeIntervalSince($0.sentAt) > 3600 }) {
        return .suppress("nudges_finished")
      }
      let sentCount = history.filter { $0.kind == .inviteNudge }.count
      if sentCount >= 2 { return .suppress("nudges_finished") }
      if inSecond && !history.contains(where: { $0.kind == .inviteNudge }) {
        return sendOrDailyCap(kind: kind, now: now, timeZone: timeZone, history: history)
      }
    case .weeklyReminder, .planReady:
      break
    }
    return sendOrDailyCap(kind: kind, now: now, timeZone: timeZone, history: history)
  }

  private static func sendOrDailyCap(kind: PushKind, now: Date, timeZone: TimeZone, history: [PushRecord]) -> PushDecision {
    guard !isTransactional(kind) else { return .send }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let already = history.contains { record in
      !record.transactional && calendar.isDate(record.sentAt, inSameDayAs: now)
    }
    if already { return .suppress("daily_non_transactional") }
    return .send
  }

  static func body(kind: PushKind, partnerName: String, nudgeIndex: Int = 1) -> String {
    switch kind {
    case .partnerMood:
      return "\(partnerName) picked a mood for your night."
    case .planReady:
      return "Your date is ready to reveal."
    case .inviteAccepted:
      return "\(partnerName) is in. This night is officially both of yours."
    case .weeklyReminder:
      return "Tonight is yours, \(partnerName)."
    case .inviteNudge:
      if nudgeIndex >= 2 {
        return "We'll leave the invite here for \(partnerName). No more reminders."
      }
      return "Your invite for \(partnerName) is open whenever you both want it."
    }
  }

  static func forbiddenFragments(in body: String, secrets: [String]) -> [String] {
    secrets.filter { body.localizedCaseInsensitiveContains($0) }
  }
}
