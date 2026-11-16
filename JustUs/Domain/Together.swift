import Foundation

struct DatedNight: Equatable, Sendable {
  var status: DateStatus
  var scheduledAt: Date
  var createdAt: Date
  var plannerUserId: UUID
}

enum PlannerTurn {
  /// The person who plans the next draft. A scheduled or completed night hands
  /// the following one to the other member. A skip leaves the turn where it is.
  /// The latest night is the one with the latest scheduled time, then the latest
  /// created time, matching `next_planner_user_id`.
  static func nextPlanner(nights: [DatedNight], members: [MemberRef]) -> UUID? {
    let ordered = members.sorted { $0.memberIndex < $1.memberIndex }
    guard let first = ordered.first else { return nil }
    let history = nights
      .filter { $0.status == .completed || $0.status == .scheduled }
      .sorted { lhs, rhs in
        if lhs.scheduledAt != rhs.scheduledAt { return lhs.scheduledAt > rhs.scheduledAt }
        return lhs.createdAt > rhs.createdAt
      }
    guard let last = history.first else { return first.userId }
    return ordered.first { $0.userId != last.plannerUserId }?.userId ?? last.plannerUserId
  }
}

enum TogetherStreak {
  /// Finished weeks in a row as of `now`, in the couple's time zone. Weeks start
  /// on Sunday. One skipped week in a calendar month keeps the run and does not
  /// add to it. Two skipped weeks in a row end it, including when they fall in
  /// different months. A second skip in the same month, a week with no night, or
  /// a newest week older than last week also ends it.
  static func weeks(nights: [DatedNight], timeZone: String, now: Date) -> Int {
    guard let calendar = sundayCalendar(timeZone) else { return 0 }
    struct Bucket {
      var start: Date
      var completed = false
      var skipped = false
      var skipMonth: String?
    }
    var buckets: [Date: Bucket] = [:]
    for night in nights where night.status == .completed || night.status == .skipped {
      guard let start = calendar.dateInterval(of: .weekOfYear, for: night.scheduledAt)?.start else { continue }
      var bucket = buckets[start] ?? Bucket(start: start)
      if night.status == .completed {
        bucket.completed = true
      } else {
        bucket.skipped = true
        if bucket.skipMonth == nil {
          let parts = calendar.dateComponents([.year, .month], from: night.scheduledAt)
          if let year = parts.year, let month = parts.month {
            bucket.skipMonth = String(format: "%04d-%02d", year, month)
          }
        }
      }
      buckets[start] = bucket
    }
    let ordered = buckets.values.sorted { $0.start > $1.start }
    guard let newest = ordered.first,
          let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
          let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek),
          newest.start >= lastWeek else { return 0 }
    var count = 0
    var skips: [String: Int] = [:]
    var later: Date?
    var newerWasSkip = false
    for bucket in ordered {
      if let later {
        guard let adjacent = calendar.date(byAdding: .weekOfYear, value: -1, to: later),
              bucket.start >= adjacent else { break }
      }
      later = bucket.start
      if bucket.completed {
        count += 1
        newerWasSkip = false
        continue
      }
      if newerWasSkip { break }
      guard bucket.skipped, let month = bucket.skipMonth, skips[month, default: 0] < 1 else { break }
      skips[month, default: 0] += 1
      newerWasSkip = true
    }
    return count
  }

  /// Israel weeks start on Sunday. `firstWeekday` 1 is Sunday.
  private static func sundayCalendar(_ timeZone: String) -> Calendar? {
    guard let zone = TimeZone(identifier: timeZone) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.firstWeekday = 1
    return calendar
  }
}
