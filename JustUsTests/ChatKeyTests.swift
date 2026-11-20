import Supabase
import XCTest
@testable import JustUs

final class ChatKeyTests: XCTestCase {

  func testAFullSetDoesNotRotateOnRefresh() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let retiredAt = now.addingTimeInterval(-5)
    XCTAssertEqual(
      KeyRotation.step(hasRow: false, retired: false, activeCount: 3, retiredAt: nil, now: now, reason: .refresh),
      .publish
    )
    XCTAssertEqual(
      KeyRotation.step(hasRow: true, retired: false, activeCount: 3, retiredAt: nil, now: now, reason: .refresh),
      .keep
    )
    XCTAssertEqual(
      KeyRotation.step(hasRow: true, retired: true, activeCount: 2, retiredAt: retiredAt, now: now, reason: .refresh),
      .publish
    )
    XCTAssertEqual(
      KeyRotation.step(hasRow: true, retired: true, activeCount: 3, retiredAt: retiredAt, now: now, reason: .refresh),
      .hold
    )
    XCTAssertEqual(
      KeyRotation.step(hasRow: true, retired: true, activeCount: 3, retiredAt: retiredAt, now: now, reason: .send),
      .hold
    )
    let later = retiredAt.addingTimeInterval(KeyRotation.backoff + 1)
    XCTAssertEqual(
      KeyRotation.step(hasRow: true, retired: true, activeCount: 3, retiredAt: retiredAt, now: later, reason: .send),
      .publish
    )
    XCTAssertEqual(
      KeyRotation.step(hasRow: true, retired: true, activeCount: 3, retiredAt: retiredAt, now: later, reason: .refresh),
      .hold
    )
    XCTAssertThrowsError(try KeyRotation.enforce(.hold, reason: .send)) { error in
      XCTAssertEqual(error as? AppError, .rateLimited)
    }
  }

  func testSignOutUsesTheStatusOrCodeRatherThanTheMessage() throws {
    XCTAssertTrue(ChatSignOut.continues(after: PostgrestError(
      code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned"
    )))
    XCTAssertFalse(ChatSignOut.continues(after: PostgrestError(
      code: "23514", message: "room 404 was not found and the client saw a 401"
    )))
    XCTAssertTrue(ChatSignOut.continues(after: AppError.server(code: "PGRST301")))
    let url = try XCTUnwrap(URL(string: "https://example.test/rest"))
    let missing = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
    XCTAssertTrue(ChatSignOut.continues(after: HTTPError(data: Data("nope".utf8), response: missing)))
    let other = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil))
    XCTAssertFalse(ChatSignOut.continues(after: HTTPError(data: Data("404 401 not found".utf8), response: other)))
    let unauthorized = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
    let auth = AuthError.api(
      message: "room 404", errorCode: ErrorCode("validation_failed"),
      underlyingData: Data(), underlyingResponse: unauthorized
    )
    XCTAssertTrue(ChatSignOut.continues(after: auth))
    struct TextFailure: Error, CustomStringConvertible { var description: String }
    XCTAssertFalse(ChatSignOut.continues(after: TextFailure(description: "status 404 and 401 not found")))
  }

  func testADeadSessionSignsOutAndAFailedRetireRestoresTheToken() async throws {
    var events: [String] = []
    try await ChatSignOut.perform(
      deleteToken: { events.append("delete"); throw AppError.sessionExpired },
      retire: { events.append("retire") },
      authSignOut: { events.append("auth") },
      recoverToken: { events.append("recover") }
    )
    XCTAssertEqual(events, ["delete", "auth"])

    events = []
    do {
      try await ChatSignOut.perform(
        deleteToken: { events.append("delete") },
        retire: { events.append("retire"); throw AppError.offline },
        authSignOut: { events.append("auth") },
        recoverToken: { events.append("recover") }
      )
      XCTFail("expected the session to stay signed in")
    } catch AppError.offline {
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertEqual(events, ["delete", "retire", "recover"])

    events = []
    struct TextFailure: Error, CustomStringConvertible { var description: String }
    do {
      try await ChatSignOut.perform(
        deleteToken: { events.append("delete"); throw TextFailure(description: "HTTP 404") },
        retire: { events.append("retire") },
        authSignOut: { events.append("auth") }
      )
      XCTFail("expected the message text to keep the session")
    } catch is TextFailure {
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertEqual(events, ["delete"])
  }

  func testFourPhonesSettleAndTheNoticeDoesNotRepeat() {
    struct Row {
      var id: UUID
      var created: Date
      var retiredAt: Date?
    }
    var rows: [Row] = []
    var phoneKey = [UUID?](repeating: nil, count: 4)
    var seen: [UUID] = []
    var notices = 0
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func refresh(at now: Date) {
      for phone in 0..<4 {
        let current = phoneKey[phone].flatMap { id in rows.first { $0.id == id } }
        let active = rows.filter { $0.retiredAt == nil }
        let step = KeyRotation.step(
          hasRow: current != nil, retired: current?.retiredAt != nil, activeCount: active.count,
          retiredAt: current?.retiredAt, now: now, reason: .refresh
        )
        guard step == .publish else { continue }
        let fresh = UUID()
        rows.append(Row(id: fresh, created: now, retiredAt: nil))
        phoneKey[phone] = fresh
        let excess = KeyCap.excessIds(rows.filter { $0.retiredAt == nil }.map { ($0.id, $0.created) })
        for id in excess {
          guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
          rows[index].retiredAt = now
        }
      }
      let activeIds = rows.filter { $0.retiredAt == nil }.map(\.id)
      if PartnerKeyMemory.changed(previous: seen, current: activeIds) { notices += 1 }
      seen = activeIds
    }
    for round in 0..<100 {
      refresh(at: start.addingTimeInterval(TimeInterval(round)))
    }
    XCTAssertEqual(rows.filter { $0.retiredAt == nil }.count, 3)
    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(notices, 0)
    for round in 0..<100 {
      refresh(at: start.addingTimeInterval(TimeInterval(100 + round)))
    }
    XCTAssertEqual(rows.count, 4)
    XCTAssertEqual(rows.filter { $0.retiredAt == nil }.count, 3)
    XCTAssertEqual(notices, 0)
    let displaced = (0..<4).compactMap { phone -> Row? in
      guard let id = phoneKey[phone] else { return nil }
      return rows.first { $0.id == id && $0.retiredAt != nil }
    }.first
    XCTAssertNotNil(displaced)
    let immediate = KeyRotation.step(
      hasRow: true, retired: true, activeCount: 3, retiredAt: displaced?.retiredAt,
      now: start.addingTimeInterval(1), reason: .send
    )
    XCTAssertEqual(immediate, .hold)
  }

  func testARetiredPrivateKeyStillOpensItsEnvelope() throws {
    let sender = ChatIdentity.generate()
    let oldPhone = ChatIdentity.generate()
    let newPhone = ChatIdentity.generate()
    let messageId = UUID()
    let senderUser = UUID()
    let recipient = UUID()
    let envelopes = try ChatCrypto.seal(
      text: "before-rotation", messageId: messageId, senderUserId: senderUser, from: sender,
      to: [
        ChatTarget(keyId: oldPhone.id, userId: recipient, publicKey: oldPhone.publicKey),
        ChatTarget(keyId: sender.id, userId: senderUser, publicKey: sender.publicKey)
      ]
    )
    let opened = ChatHistory.open(
      envelopes: envelopes, current: newPhone, retired: [oldPhone], messageId: messageId,
      senderUserId: senderUser, recipientUserId: recipient, senderPublic: sender.publicKey
    )
    XCTAssertEqual(opened, "before-rotation")
    let lost = ChatHistory.open(
      envelopes: envelopes, current: newPhone, retired: [], messageId: messageId,
      senderUserId: senderUser, recipientUserId: recipient, senderPublic: sender.publicKey
    )
    XCTAssertNil(lost)
  }

  func testARetiredPrivateKeyStaysOnTheRingAndOpens() throws {
    let box = MemoryDeviceKeychain()
    let user = UUID()
    let original = try DeviceKeyStore.loadOrCreate(userId: user, keychain: box)
    let fresh = ChatIdentity.generate()
    try DeviceKeyStore.commit(current: fresh, retiring: original, userId: user, keychain: box)
    XCTAssertEqual(try DeviceKeyStore.load(userId: user, keychain: box)?.id, fresh.id)
    let retired = DeviceKeyStore.retired(userId: user, keychain: box)
    XCTAssertEqual(retired.map(\.id), [original.id])
    XCTAssertEqual(try opened("kept", to: original, current: fresh, retired: retired, user: user), "kept")
    XCTAssertNil(try opened("lost", to: original, current: fresh, retired: [], user: user))
  }

  func testTheRingKeepsTheLatestFortyPrivateKeys() throws {
    let box = MemoryDeviceKeychain()
    let user = UUID()
    var current = try DeviceKeyStore.loadOrCreate(userId: user, keychain: box)
    let dropped = current
    var oldestKept: ChatIdentity?
    for index in 0..<41 {
      let next = ChatIdentity.generate()
      if index == 1 { oldestKept = current }
      try DeviceKeyStore.commit(current: next, retiring: current, userId: user, keychain: box)
      current = next
    }
    let kept = try XCTUnwrap(oldestKept)
    let retired = DeviceKeyStore.retired(userId: user, keychain: box)
    XCTAssertEqual(retired.count, 40)
    XCTAssertFalse(retired.contains { $0.id == dropped.id })
    XCTAssertTrue(retired.contains { $0.id == kept.id })
    XCTAssertEqual(try DeviceKeyStore.load(userId: user, keychain: box)?.id, current.id)
    XCTAssertEqual(try opened("still", to: kept, current: current, retired: retired, user: user), "still")
    XCTAssertNil(try opened("gone", to: dropped, current: current, retired: retired, user: user))
  }

  func testTheKeychainKeepsARetiredPrivateKey() throws {
    let user = UUID()
    defer { DeviceKeyStore.delete(userId: user) }
    let original: ChatIdentity
    do {
      original = try DeviceKeyStore.loadOrCreate(userId: user)
    } catch ChatCryptoError.unreadable {
      throw XCTSkip("The simulator test host has no usable Keychain")
    }
    let fresh = ChatIdentity.generate()
    try DeviceKeyStore.commit(current: fresh, retiring: original, userId: user)
    XCTAssertEqual(try DeviceKeyStore.load(userId: user)?.id, fresh.id)
    let retired = DeviceKeyStore.retired(userId: user)
    XCTAssertEqual(retired.map(\.id), [original.id])
    XCTAssertEqual(try opened("kept", to: original, current: fresh, retired: retired, user: user), "kept")
  }

  private func opened(
    _ text: String, to key: ChatIdentity, current: ChatIdentity, retired: [ChatIdentity], user: UUID
  ) throws -> String? {
    let sender = ChatIdentity.generate()
    let messageId = UUID()
    let envelopes = try ChatCrypto.seal(
      text: text, messageId: messageId, senderUserId: sender.id, from: sender,
      to: [ChatTarget(keyId: key.id, userId: user, publicKey: key.publicKey)]
    )
    return ChatHistory.open(
      envelopes: envelopes, current: current, retired: retired, messageId: messageId,
      senderUserId: sender.id, recipientUserId: user, senderPublic: sender.publicKey
    )
  }

  func testAFailedKeyInsertDoesNotCommitTheNewKey() async throws {
    var committed = false
    do {
      try await KeyPublish.stage(insert: { throw AppError.offline }, commit: { committed = true })
      XCTFail("expected the insert to fail")
    } catch AppError.offline {
      XCTAssertFalse(committed)
    } catch {
      XCTFail("unexpected \(error)")
    }
    var steps: [String] = []
    try await KeyPublish.stage(insert: { steps.append("insert") }, commit: { steps.append("commit") })
    XCTAssertEqual(steps, ["insert", "commit"])
  }

  func testASecondPublishWaitsUntilTheFirstFinishes() async throws {
    let gate = KeyPublishGate()
    final class Log: @unchecked Sendable {
      let lock = NSLock()
      var events: [String] = []
      var release: CheckedContinuation<Void, Never>?
      func add(_ value: String) {
        lock.lock()
        events.append(value)
        lock.unlock()
      }
      func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
      }
    }
    let log = Log()
    let entered = expectation(description: "first publish entered")
    let first = Task {
      try await gate.run {
        log.add("first-start")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          log.release = continuation
          entered.fulfill()
        }
        log.add("first-end")
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    let second = Task {
      try await gate.run { log.add("second") }
    }
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(log.snapshot(), ["first-start"])
    log.release?.resume()
    try await first.value
    try await second.value
    XCTAssertEqual(log.snapshot(), ["first-start", "first-end", "second"])
  }
}

private final class MemoryDeviceKeychain: DeviceKeychain, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]

  func load(account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return items[account]
  }

  func save(account: String, data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    items[account] = data
  }

  func remove(account: String) {
    lock.lock()
    defer { lock.unlock() }
    items[account] = nil
  }
}
