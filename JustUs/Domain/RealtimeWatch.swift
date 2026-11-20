import Foundation

/// Decides whether a Realtime channel should stay, rejoin, or be replaced.
///
/// supabase-swift reuses a channel with the same topic and ignores
/// `postgresChange` callbacks registered after that channel has joined.
/// A reload has to keep the live channel. A new join has to remove the old one first.
enum RealtimeWatch {
  struct Plan: Equatable {
    var subscribe: Bool
    var removeCurrent: Bool
  }

  /// `subscribing` counts as live so an in-flight join is not started again.
  enum Presence: Equatable {
    case subscribed
    case subscribing
    case down
  }

  static func plan(current: UUID?, requested: UUID, presence: Presence) -> Plan {
    let live = presence == .subscribed || presence == .subscribing
    if current == requested, live {
      return Plan(subscribe: false, removeCurrent: false)
    }
    return Plan(subscribe: true, removeCurrent: current != nil)
  }
}
