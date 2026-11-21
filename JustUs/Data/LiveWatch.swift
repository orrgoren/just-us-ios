import Foundation
import Supabase

/// One Realtime subscription. The channel and the id it watches stay put
/// until the id changes, the socket drops, or the session tears the watch down.
@MainActor
final class LiveWatch {
  private var channel: RealtimeChannelV2?
  private var watched: UUID?
  private var listen: Task<Void, Never>?
  private var subscribeJob: Task<Void, Never>?
  private var chain: Task<Void, Never>?
  private var generation = 0
  private var stopping = 0
  /// True from the moment a join is armed until its server ack lands.
  /// Status can still say `.unsubscribed` for that beat, and a second
  /// `ensure` must not tear the join down.
  private var awaitingAck = false
  private var onChange: (@MainActor (AnyAction) -> Void)?
  private var onReconnect: (@MainActor () -> Void)?
  private var statusJob: Task<Void, Never>?

  func ensure(
    id: UUID,
    client: SupabaseClient,
    topic: String,
    changes: @escaping (RealtimeChannelV2) -> AsyncStream<AnyAction>,
    onChange: @escaping @MainActor (AnyAction) -> Void,
    onReconnect: (@MainActor () -> Void)? = nil
  ) async {
    let token = generation
    guard stopping == 0 else { return }
    await enqueue { [weak self] in
      guard let self, self.generation == token, self.stopping == 0 else { return }
      await self.open(
        id: id, client: client, topic: topic, changes: changes, onChange: onChange, onReconnect: onReconnect
      )
    }
  }

  func stop(client: SupabaseClient?) async {
    stopping += 1
    defer { stopping -= 1 }
    generation += 1
    let token = generation
    await enqueue { [weak self] in
      guard let self, self.generation == token else { return }
      await self.tearDown(client)
    }
  }

  private func enqueue(_ body: @escaping @MainActor () async -> Void) async {
    let previous = chain
    let next = Task { @MainActor in
      await previous?.value
      await body()
    }
    chain = next
    await next.value
  }

  private func open(
    id: UUID,
    client: SupabaseClient,
    topic: String,
    changes: @escaping (RealtimeChannelV2) -> AsyncStream<AnyAction>,
    onChange: @escaping @MainActor (AnyAction) -> Void,
    onReconnect: (@MainActor () -> Void)? = nil
  ) async {
    let plan = RealtimeWatch.plan(current: watched, requested: id, presence: presence())
    guard plan.subscribe else { return }
    await join(
      id: id, client: client, topic: topic, changes: changes, onChange: onChange,
      onReconnect: onReconnect, removeCurrent: plan.removeCurrent
    )
  }

  private func join(
    id: UUID,
    client: SupabaseClient,
    topic: String,
    changes: @escaping (RealtimeChannelV2) -> AsyncStream<AnyAction>,
    onChange: @escaping @MainActor (AnyAction) -> Void,
    onReconnect: (@MainActor () -> Void)?,
    removeCurrent: Bool
  ) async {
    let token = generation
    if removeCurrent {
      await tearDown(client)
    }
    guard generation == token, stopping == 0 else { return }
    await RealtimeAuth.apply(client)
    guard generation == token, stopping == 0 else { return }
    let next = client.channel(topic)
    let stream = changes(next)
    guard generation == token, stopping == 0 else {
      await client.removeChannel(next)
      return
    }
    // The server ack retries for a while when the socket is down. Arm the
    // listener first so a reload is not stuck behind that ladder. A later
    // ensure sees `.subscribing` and leaves this join alone.
    channel = next
    watched = id
    awaitingAck = true
    self.onChange = onChange
    self.onReconnect = onReconnect
    listen = Task { @MainActor [weak self] in
      for await action in stream {
        if Task.isCancelled { break }
        self?.emit(action)
      }
    }
    watchStatus(next, token: token)
    subscribeJob = Task { @MainActor [weak self] in
      await self?.finish(next, client: client, token: token)
    }
  }

  private func finish(_ joined: RealtimeChannelV2, client: SupabaseClient, token: Int) async {
    let ok = await opened(joined)
    guard generation == token, channel === joined else { return }
    awaitingAck = false
    guard ok else {
      await tearDown(client)
      return
    }
  }

  private func opened(_ channel: RealtimeChannelV2) async -> Bool {
    do {
      try await channel.subscribeWithError()
      return true
    } catch {
      return false
    }
  }

  private func tearDown(_ client: SupabaseClient?) async {
    subscribeJob?.cancel()
    subscribeJob = nil
    listen?.cancel()
    listen = nil
    statusJob?.cancel()
    statusJob = nil
    let old = channel
    channel = nil
    watched = nil
    awaitingAck = false
    onChange = nil
    onReconnect = nil
    if let client, let old {
      await client.removeChannel(old)
    }
  }

  private func watchStatus(_ joined: RealtimeChannelV2, token: Int) {
    statusJob?.cancel()
    statusJob = Task { @MainActor [weak self] in
      var presence = ChatPresence()
      for await status in joined.statusChange {
        if Task.isCancelled { break }
        guard let self, self.generation == token else { break }
        if presence.receive(subscribed: status == .subscribed) {
          self.onReconnect?()
        }
      }
    }
  }

  private func emit(_ action: AnyAction) {
    onChange?(action)
  }

  private func presence() -> RealtimeWatch.Presence {
    switch channel?.status {
    case .subscribed:
      return .subscribed
    case .subscribing:
      return .subscribing
    default:
      return awaitingAck ? .subscribing : .down
    }
  }
}

enum RealtimeAuth {
  /// The default client already copies the session access token onto Realtime
  /// for `initialSession`, `signedIn`, and `tokenRefreshed`. Pushing it again
  /// before a join covers a reconnect that races that listener. `chat_messages`
  /// RLS drops events when the socket is still on the anon key.
  static func apply(_ client: SupabaseClient) async {
    guard let session = try? await client.auth.session else { return }
    await client.realtimeV2.setAuth(session.accessToken)
  }
}

extension LiveBackend {
  func watchChat(coupleId: UUID) async {
    // A Realtime DELETE carries the row id only, so the listener reloads.
    await watch(
      id: coupleId,
      topic: "chat-\(coupleId.uuidString)",
      table: "chat_messages",
      column: "couple_id",
      socket: chatSocket
    )
  }

  func watchMoods(dateId: UUID) async {
    await watch(
      id: dateId,
      topic: "mood-\(dateId.uuidString)",
      table: "mood_votes",
      column: "date_id",
      socket: moodSocket
    )
  }

  func stopSockets() async {
    await chatSocket.stop(client: client)
    await moodSocket.stop(client: client)
  }

  private func watch(
    id: UUID,
    topic: String,
    table: String,
    column: String,
    socket: LiveWatch
  ) async {
    guard let client else { return }
    await socket.ensure(
      id: id,
      client: client,
      topic: topic,
      changes: { channel in
        channel.postgresChange(
          AnyAction.self,
          schema: "public",
          table: table,
          filter: .eq(column, value: id.uuidString)
        )
      },
      onChange: { [weak self] action in
        if table == "chat_messages" {
          self?.deliverChat(action)
        } else {
          self?.onRemoteChange?()
        }
      },
      onReconnect: { [weak self] in
        guard table == "chat_messages" else { return }
        self?.reloadChat(.reconnect)
      }
    )
  }
}
