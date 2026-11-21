import Foundation
import UserNotifications

/// A send shows up before the server answers. A later row with the same id replaces it.
enum ChatThread {
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

/// A chat insert is one row. A delete, an update, a bad payload, or a reconnect reloads.
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
    case reload
  }

  static func step(_ event: Event) -> Step {
    event == .insert ? .append : .reload
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
