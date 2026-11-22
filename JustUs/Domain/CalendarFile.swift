import Foundation

enum CalendarFile {
  static var summary: String { L10n.calendarSummary }
  static var details: String { L10n.calendarDetails }

  static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\r\n", with: "\\n")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\n")
      .replacingOccurrences(of: ";", with: "\\;")
      .replacingOccurrences(of: ",", with: "\\,")
  }

  static func fold(_ line: String) -> String {
    let bytes = Array(line.utf8)
    guard bytes.count > 75 else { return line }
    var parts: [String] = []
    var offset = 0
    var limit = 75
    while offset < bytes.count {
      var end = min(offset + limit, bytes.count)
      while end > offset && end < bytes.count && (bytes[end] & 0xC0) == 0x80 {
        end -= 1
      }
      if end == offset { end = min(offset + limit, bytes.count) }
      let slice = Data(bytes[offset..<end])
      let text = String(decoding: slice, as: UTF8.self)
      parts.append(parts.isEmpty ? text : " \(text)")
      offset = end
      limit = 74
    }
    return parts.joined(separator: "\r\n")
  }

  static func build(coupleId: UUID, startDate: String, startTime: String, durationMinutes: Int, timeZone: String, now: Date = Date()) throws -> String {
    let end = try ZonedTime.addMinutes(date: startDate, time: startTime, minutes: durationMinutes)
    let lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Just Us//Weekly Date//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      timezoneBlock(timeZone),
      "BEGIN:VEVENT",
      "UID:just-us-\(coupleId.uuidString)@just-us",
      "DTSTAMP:\(stamp(now))",
      "SUMMARY:\(escape(summary))",
      "DTSTART;TZID=\(timeZone):\(compact(startDate, startTime))",
      "DTEND;TZID=\(timeZone):\(compact(end.date, end.time))",
      "RRULE:FREQ=WEEKLY",
      "DESCRIPTION:\(escape(details))",
      "END:VEVENT",
      "END:VCALENDAR"
    ]
    let folded = lines.flatMap { $0.components(separatedBy: "\r\n") }.map(fold)
    return folded.joined(separator: "\r\n") + "\r\n"
  }

  private static func compact(_ date: String, _ time: String) -> String {
    date.replacingOccurrences(of: "-", with: "") + "T" + time.replacingOccurrences(of: ":", with: "") + "00"
  }

  private static func stamp(_ instant: Date) -> String {
    let calendar = ZonedTime.utcCalendar()
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
    let year = parts.year ?? 0
    let month = parts.month ?? 0
    let day = parts.day ?? 0
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    let second = parts.second ?? 0
    return String(format: "%04d%02d%02dT%02d%02d%02dZ", year, month, day, hour, minute, second)
  }

  private static func timezoneBlock(_ name: String) -> String {
    guard let zone = TimeZone(identifier: name) else {
      return "BEGIN:VTIMEZONE\r\nTZID:\(name)\r\nEND:VTIMEZONE"
    }
    let winter = offset(zone, sample(year: 2026, month: 1, day: 15))
    let summer = offset(zone, sample(year: 2026, month: 7, day: 16))
    return [
      "BEGIN:VTIMEZONE",
      "TZID:\(name)",
      "BEGIN:STANDARD",
      "DTSTART:19700101T000000",
      "TZOFFSETFROM:\(winter)",
      "TZOFFSETTO:\(winter)",
      "TZNAME:STANDARD",
      "END:STANDARD",
      "BEGIN:DAYLIGHT",
      "DTSTART:19700301T000000",
      "TZOFFSETFROM:\(winter)",
      "TZOFFSETTO:\(summer)",
      "TZNAME:DAYLIGHT",
      "END:DAYLIGHT",
      "END:VTIMEZONE"
    ].joined(separator: "\r\n")
  }

  private static func sample(year: Int, month: Int, day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    if let utc = TimeZone(secondsFromGMT: 0) {
      calendar.timeZone = utc
    }
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
  }

  private static func offset(_ zone: TimeZone, _ date: Date) -> String {
    let minutes = zone.secondsFromGMT(for: date) / 60
    let sign = minutes >= 0 ? "+" : "-"
    let absolute = abs(minutes)
    return String(format: "%@%02d%02d", sign, absolute / 60, absolute % 60)
  }
}
