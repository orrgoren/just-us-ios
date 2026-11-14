import Foundation

enum Validation {
  static func email(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (3...320).contains(value.count) else { return nil }
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else {
      return nil
    }
    return value
  }

  static func displayName(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...24).contains(value.count) else { return nil }
    return value
  }

  static func time(_ raw: String) -> String? {
    guard raw.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
    return raw
  }

  static func weekday(_ value: Int) -> Bool { (0...6).contains(value) }

  static func duration(_ value: Int) -> Bool { (30...360).contains(value) }

  static func teaser(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count <= 160 else { return nil }
    return value
  }

  static func note(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count <= 2000 else { return nil }
    return value
  }

  static func day(_ raw: String) -> Bool {
    raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
  }

  static func code(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(of: #"^\d{6,10}$"#, options: .regularExpression) != nil else { return nil }
    return value
  }

  static func couple(_ draft: CoupleDraft) -> AppError? {
    guard displayName(draft.selfName) != nil, displayName(draft.partnerName) != nil else { return .invalid(.name) }
    guard weekday(draft.weekday) else { return .invalid(.weekday) }
    guard time(draft.localTime) != nil else { return .invalid(.time) }
    guard ZonedTime.isValidZone(draft.timezone) else { return .invalid(.timezone) }
    guard duration(draft.durationMinutes) else { return .invalid(.duration) }
    return nil
  }
}
