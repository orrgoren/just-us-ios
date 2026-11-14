import Foundation

enum Recommendation {
  static func suggestedLocation(completedCount: Int) throws -> LocationKind {
    guard completedCount >= 0 else { throw AppError.validationCount }
    return completedCount % 4 == 3 ? .out : .home
  }

  static func defaultPlannerIndex(completedCount: Int) throws -> Int {
    guard completedCount >= 0 else { throw AppError.validationCount }
    return completedCount % 2 == 0 ? 0 : 1
  }

  static func resolve(completedCount: Int, choice: PlaceChoice) throws -> (location: LocationKind, suggested: LocationKind, isOverride: Bool) {
    let suggested = try suggestedLocation(completedCount: completedCount)
    let location: LocationKind
    switch choice {
    case .auto: location = suggested
    case .home: location = .home
    case .out: location = .out
    }
    return (location, suggested, location != suggested)
  }

  static func candidates(ideas: [DateIdea], location: LocationKind, moods: [MoodKey], recentIdeaIds: [String], excludeIds: [String] = []) -> [DateIdea] {
    let available = ideas.filter { $0.loc == location }
    guard !available.isEmpty else { return [] }
    var moodKeys: [MoodKey] = []
    for mood in moods where !moodKeys.contains(mood) {
      moodKeys.append(mood)
    }
    let recent = Set(recentIdeaIds.prefix(3))
    let excluded = Set(excludeIds)
    let notRecent: (DateIdea) -> Bool = { !recent.contains($0.id) && !excluded.contains($0.id) }
    let notExcluded: (DateIdea) -> Bool = { !excluded.contains($0.id) }
    if moodKeys.isEmpty {
      let fresh = available.filter(notRecent)
      if !fresh.isEmpty { return fresh }
      let besides = available.filter(notExcluded)
      return besides.isEmpty ? available : besides
    }
    let intersection: [MoodKey] = moodKeys.count >= 2 && moodKeys[0] != moodKeys[1] ? [] : moodKeys
    let matches: (DateIdea, [MoodKey]) -> Bool = { idea, moods in !moods.isEmpty && moods.contains(idea.mood) }
    let pools: [[DateIdea]] = [
      available.filter { matches($0, intersection) && notRecent($0) },
      available.filter { matches($0, moodKeys) && notRecent($0) },
      available.filter { matches($0, moodKeys) && notExcluded($0) },
      available.filter { matches($0, moodKeys) },
      available.filter(notRecent),
      available.filter(notExcluded),
      available
    ]
    return pools.first { !$0.isEmpty } ?? []
  }

  static func pick(ideas: [DateIdea], location: LocationKind, moods: [MoodKey], recentIdeaIds: [String], excludeIds: [String] = [], random: () -> Double = { Double.random(in: 0..<1) }) -> DateIdea? {
    let pool = candidates(ideas: ideas, location: location, moods: moods, recentIdeaIds: recentIdeaIds, excludeIds: excludeIds)
    guard !pool.isEmpty else { return nil }
    let raw = random()
    let index = min(pool.count - 1, max(0, Int(raw * Double(pool.count))))
    return pool[index]
  }
}

extension AppError {
  static var validationCount: AppError { .server(code: "invalid_completed_count") }
}
