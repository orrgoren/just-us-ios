import Foundation
import UserNotifications

/// A send shows up before the server answers. A later row with the same id replaces it.
enum ChatThread {
  /// A reload must not throw away a send that the server has not stored yet.
  static func keepingPending(_ remote: [ChatLine], local: [ChatLine]) -> [ChatLine] {
    let stored = Set(remote.map(\.id))
    let pending = local.filter { line in
      (line.delivery == .sending || line.delivery == .failed) && stored.contains(line.id) == false
    }
    return ChatWindow.chronological(remote + pending)
  }

  static func merge(_ lines: [ChatLine], _ incoming: ChatLine) -> [ChatLine] {
    if let index = lines.firstIndex(where: { $0.id == incoming.id }) {
      var next = lines
      var line = incoming
      if line.previewJPEG == nil {
        line.previewJPEG = lines[index].previewJPEG
      }
      line.delivery = incoming.delivery == .failed ? .failed : .sent
      next[index] = line
      return ChatWindow.chronological(next)
    }
    return ChatWindow.chronological(lines + [incoming])
  }
}

/// A quiet day line between messages. Today and Yesterday come from the locale, and so does the weekday.
enum ChatDay {
  enum Row: Identifiable, Equatable {
    case divider(id: String, label: String)
    case message(ChatLine)

    var id: String {
      switch self {
      case .divider(let id, _): return id
      case .message(let line): return line.id.uuidString
      }
    }
  }

  static func rows(_ lines: [ChatLine], now: Date = Date(), calendar: Calendar = .current) -> [Row] {
    var last: DateComponents?
    var rows: [Row] = []
    for line in ChatWindow.chronological(lines) {
      let day = calendar.dateComponents([.year, .month, .day], from: line.createdAt)
      let sameDay = last?.year == day.year && last?.month == day.month && last?.day == day.day
      if sameDay == false {
        last = day
        let stamp = "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        rows.append(.divider(id: "day-\(stamp)", label: label(line.createdAt, now: now, calendar: calendar)))
      }
      rows.append(.message(line))
    }
    return rows
  }

  static func label(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
      return relative(dayOffset: 0, calendar: calendar)
    }
    if let previous = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: previous) {
      return relative(dayOffset: -1, calendar: calendar)
    }
    let formatter = DateFormatter()
    formatter.locale = calendar.locale ?? .current
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
    return formatter.string(from: date)
  }

  /// "Today" and "Yesterday" in the device language. A fixed English string would stay English in Hebrew.
  private static func relative(dayOffset: Int, calendar: Calendar) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = calendar.locale ?? .current
    formatter.calendar = calendar
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter.localizedString(from: DateComponents(day: dayOffset)).localizedCapitalized
  }
}

/// The clock in the corner of a bubble. The locale chooses 12-hour or 24-hour.
enum ChatTime {
  static func label(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return formatter.string(from: date)
  }
}

/// Follow the latest line only when the reader is already there. Otherwise offer a pill.
enum ChatScroll {
  static let bottom = "chat-bottom"

  enum Action: Equatable {
    case follow
    case pill
  }

  static func action(nearBottom: Bool) -> Action {
    nearBottom ? .follow : .pill
  }
}

/// The arrow sits in the composer only when there is something to send.
enum ChatComposer {
  static func showsSend(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
}

/// A chat insert is one row. An update patches that row. A delete, a bad payload, or a reconnect reloads.
enum ChatSocket {
  enum Event: Equatable {
    case insert
    case update
    case delete
    case reconnect
    case undecodable
  }

  enum Step: Equatable {
    case append
    case patch
    case reload
  }

  static func step(_ event: Event) -> Step {
    switch event {
    case .insert: return .append
    case .update: return .patch
    case .delete, .reconnect, .undecodable: return .reload
    }
  }
}

/// The first subscribe is the open. A later one, after a drop, is a reconnect.
struct ChatPresence: Equatable {
  var live = false
  var dropped = false

  mutating func receive(subscribed: Bool) -> Bool {
    if subscribed {
      let reload = live && dropped
      live = true
      dropped = false
      return reload
    }
    if live { dropped = true }
    return false
  }
}

/// A chat push in the foreground is not a system banner. Other tabs get an in-app line.
enum ChatPush {
  static func isChat(_ userInfo: [AnyHashable: Any]) -> Bool {
    if case .chat = DeepLinks.route(userInfo: userInfo) {
      let type = (userInfo["type"] as? String) ?? (userInfo["screen"] as? String) ?? ""
      return type.isEmpty == false
    }
    return false
  }

  static func presentation(_ userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
    isChat(userInfo) ? [] : [.banner, .sound]
  }

  static func showsBanner(chat: Bool, chatVisible: Bool) -> Bool {
    chat && chatVisible == false
  }
}

/// One retry when the cached device key was retired out from under this phone.
enum ChatSendRecovery {
  static func refreshKeys(_ error: Error) -> Bool {
    String(describing: error).lowercased().contains("unknown_sender_key")
  }
}

/// The active device-key ids. A different set means the cached ring is stale.
enum ChatKeyRing {
  static func matches(cached: Set<UUID>, fresh: Set<UUID>) -> Bool {
    cached == fresh
  }
}

/// A unique violation means this id is already stored. Retrying it is success.
enum ChatInsertGate {
  static func alreadyStored(_ error: Error) -> Bool {
    let blob = String(describing: error).lowercased()
    if blob.contains("23505") || blob.contains("duplicate key") { return true }
    return blob.contains("409")
  }
}
