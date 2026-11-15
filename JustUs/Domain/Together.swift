import Foundation

struct DatedNight: Equatable, Sendable {
  var status: DateStatus
  var scheduledAt: Date
  var plannerUserId: UUID
}

enum PlannerTurn {
  /// The person who plans the next draft. A scheduled or completed night hands
  /// the following one to the other member. A skip leaves the turn where it is.
  static func nextPlanner(nights: [DatedNight], members: [MemberRef]) -> UUID? {
    let ordered = members.sorted { $0.memberIndex < $1.memberIndex }
    guard let first = ordered.first else { return nil }
    let history = nights
      .filter { $0.status == .completed || $0.status == .scheduled }
      .sorted { $0.scheduledAt < $1.scheduledAt }
    guard let last = history.last else { return first.userId }
    return ordered.first { $0.userId != last.plannerUserId }?.userId ?? last.plannerUserId
  }
}

enum TogetherStreak {
  /// Completed weeks in a row. One skipped week in a calendar month keeps the
  /// run going and does not add to it. A second skip that month, or a week
  /// with neither, ends the run.
  static func weeks(nights: [DatedNight], timeZone: String) -> Int {
    guard let zone = TimeZone(identifier: timeZone) else { return 0 }
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = zone
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
    var count = 0
    var skips: [String: Int] = [:]
    var later: Date?
    for bucket in buckets.values.sorted(by: { $0.start > $1.start }) {
      if let later {
        let days = calendar.dateComponents([.day], from: bucket.start, to: later).day ?? 0
        if days > 8 { break }
      }
      later = bucket.start
      if bucket.completed {
        count += 1
        continue
      }
      guard bucket.skipped, let month = bucket.skipMonth, skips[month, default: 0] < 1 else { break }
      skips[month, default: 0] += 1
    }
    return count
  }
}
