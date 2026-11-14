import Foundation

enum ZonedTime {
  static func isValidZone(_ name: String) -> Bool {
    guard (1...80).contains(name.count) else { return false }
    guard name.range(of: "^[A-Za-z0-9_+\\-/]+$", options: .regularExpression) != nil else { return false }
    return TimeZone(identifier: name) != nil
  }

  static func offsetMinutes(at instant: Date, zone name: String) -> Int? {
    guard let zone = TimeZone(identifier: name) else { return nil }
    return zone.secondsFromGMT(for: instant) / 60
  }

  static func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    if let zone = TimeZone(secondsFromGMT: 0) {
      calendar.timeZone = zone
    }
    return calendar
  }

  static func parts(date: String, time: String) -> (Int, Int, Int, Int, Int)? {
    let dayParts = date.split(separator: "-")
    let timeParts = time.split(separator: ":")
    guard dayParts.count == 3, timeParts.count >= 2,
          let year = Int(dayParts[0]), let month = Int(dayParts[1]), let day = Int(dayParts[2]),
          let hour = Int(timeParts[0]), let minute = Int(timeParts[1]),
          (1...12).contains(month), (1...31).contains(day),
          (0...23).contains(hour), (0...59).contains(minute) else {
      return nil
    }
    return (year, month, day, hour, minute)
  }

  static func zonedLocalToUtc(date: String, time: String, timeZone: String) throws -> Date {
    guard let parts = parts(date: date, time: time), isValidZone(timeZone) else {
      throw AppError.invalid(.date)
    }
    let calendar = utcCalendar()
    var components = DateComponents()
    components.year = parts.0
    components.month = parts.1
    components.day = parts.2
    components.hour = parts.3
    components.minute = parts.4
    components.second = 0
    guard let target = calendar.date(from: components) else { throw AppError.invalid(.date) }
    var utc = target
    for _ in 0..<4 {
      guard let offset = offsetMinutes(at: utc, zone: timeZone) else { throw AppError.invalid(.timezone) }
      let next = target.addingTimeInterval(TimeInterval(-offset * 60))
      if next == utc { return next }
      utc = next
    }
    return utc
  }

  static func zonedParts(instant: Date, timeZone: String) throws -> (date: String, time: String, weekday: Int) {
    guard let zone = TimeZone(identifier: timeZone) else { throw AppError.invalid(.timezone) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: instant)
    guard let year = components.year, let month = components.month, let day = components.day,
          let hour = components.hour, let minute = components.minute, let weekday = components.weekday else {
      throw AppError.invalid(.date)
    }
    return (
      String(format: "%04d-%02d-%02d", year, month, day),
      String(format: "%02d:%02d", hour, minute),
      weekday - 1
    )
  }

  static func addDays(_ date: String, _ days: Int) throws -> String {
    guard let parts = parts(date: date, time: "00:00") else { throw AppError.invalid(.date) }
    let calendar = utcCalendar()
    var components = DateComponents()
    components.year = parts.0
    components.month = parts.1
    components.day = parts.2 + days
    guard let resolved = calendar.date(from: components) else { throw AppError.invalid(.date) }
    let out = calendar.dateComponents([.year, .month, .day], from: resolved)
    guard let year = out.year, let month = out.month, let day = out.day else { throw AppError.invalid(.date) }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  static func weekday(of date: String) throws -> Int {
    guard let parts = parts(date: date, time: "00:00") else { throw AppError.invalid(.date) }
    let calendar = utcCalendar()
    var components = DateComponents()
    components.year = parts.0
    components.month = parts.1
    components.day = parts.2
    guard let resolved = calendar.date(from: components) else { throw AppError.invalid(.date) }
    let weekday = calendar.component(.weekday, from: resolved)
    return weekday - 1
  }

  static func addMinutes(date: String, time: String, minutes: Int) throws -> (date: String, time: String) {
    guard let parts = parts(date: date, time: time) else { throw AppError.invalid(.date) }
    let total = parts.3 * 60 + parts.4 + minutes
    let dayShift = Int(floor(Double(total) / 1440.0))
    let wrapped = ((total % 1440) + 1440) % 1440
    return (
      try addDays(date, dayShift),
      String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    )
  }

  static func nextWeeklySlot(weekday: Int, time: String, timeZone: String, from: Date) throws -> Date {
    let start = try zonedParts(instant: from, timeZone: timeZone)
    for offset in 0...7 {
      let date = try addDays(start.date, offset)
      guard try Self.weekday(of: date) == weekday else { continue }
      let instant = try zonedLocalToUtc(date: date, time: time, timeZone: timeZone)
      if instant > from { return instant }
    }
    throw AppError.saveFailed
  }

  static func formatWhen(_ instant: Date, timeZone: String, locale: Locale = .current) -> String {
    guard let zone = TimeZone(identifier: timeZone) else { return "" }
    var style = Date.FormatStyle(date: .complete, time: .shortened)
    style.locale = locale
    style.timeZone = zone
    return instant.formatted(style)
  }

  static func formatDay(_ instant: Date, timeZone: String, locale: Locale = .current) -> String {
    guard let zone = TimeZone(identifier: timeZone) else { return "" }
    var style = Date.FormatStyle(date: .long, time: .omitted)
    style.locale = locale
    style.timeZone = zone
    return instant.formatted(style)
  }

  static func weekdaySymbol(_ index: Int, locale: Locale = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    let symbols = calendar.weekdaySymbols
    guard index >= 0, index < symbols.count else { return "" }
    return symbols[index]
  }
}
