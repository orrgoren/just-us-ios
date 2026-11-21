import XCTest
@testable import JustUs

@MainActor
final class ChatPhotoTests: XCTestCase {
  func testEncryptAndDecryptRoundTrip() throws {
    let jpeg = PhotoBytes.sample()
    let alice = ChatIdentity.generate()
    let blair = ChatIdentity.generate()
    let messageId = UUID()
    let aliceUser = UUID()
    let blairUser = UUID()
    let targets = [
      ChatTarget(keyId: alice.id, userId: aliceUser, publicKey: alice.publicKey),
      ChatTarget(keyId: blair.id, userId: blairUser, publicKey: blair.publicKey)
    ]
    let packed = try ChatPhotoCipher.package(
      jpeg: jpeg, messageId: messageId, senderUserId: aliceUser, from: alice, to: targets
    )
    let opened = try ChatPhotoCipher.jpeg(
      object: packed.object, envelopes: packed.envelopes, current: blair, retired: [],
      messageId: messageId, senderUserId: aliceUser, recipientUserId: blairUser, senderPublic: alice.publicKey
    )
    XCTAssertEqual(opened, jpeg)
    XCTAssertNotEqual(packed.object, jpeg)
    XCTAssertFalse(ChatPhoto.fits(Data(count: ChatPhoto.byteLimit + 1)))
    XCTAssertEqual(ChatNotice.screenshot("Blair"), "Blair took a screenshot")
    XCTAssertTrue(ChatPushCopy.isQuiet(ChatPushCopy.body))
  }

  func testLongEdgeStaysAtMost2048() throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1200))
    let image = renderer.image { context in
      UIColor(red: 0.4, green: 0.1, blue: 0.2, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1200))
    }
    let raw = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    let scaled = try XCTUnwrap(PhotoBytes.jpeg(from: raw, maxEdge: ChatPhoto.maxEdge))
    let result = try XCTUnwrap(UIImage(data: scaled))
    XCTAssertLessThanOrEqual(max(result.size.width, result.size.height), ChatPhoto.maxEdge)
    XCTAssertTrue(ChatPhoto.fits(scaled))
  }
}

@MainActor
final class ChatPhotoFlowTests: XCTestCase {
  override nonisolated func setUp() {
    super.setUp()
    PendingInviteStore.clear()
    DeviceTokenStore.reset()
  }

  override nonisolated func tearDown() {
    PendingInviteStore.clear()
    DeviceTokenStore.reset()
    super.tearDown()
  }

  func testViewOnceIsDeletedAfterTheRecipientClosesIt() async throws {
    let backend = try await signedInAlex()
    let jpeg = PhotoBytes.sample()
    try await backend.sendPhoto(jpeg, retention: .viewOnce)
    let sent = try await backend.messages()
    let photo = try XCTUnwrap(sent.first { $0.photo == .viewOnce })
    XCTAssertNotNil(photo.photoPath)
    switchToBlair(backend)
    let opened = try await backend.chatPhoto(photo.id)
    XCTAssertEqual(opened, jpeg)
    try await backend.consumeViewOnce(photo.id)
    let stored = backend.store.world.chats.first { $0.id == photo.id }
    XCTAssertNil(stored?.objectBytes)
    XCTAssertNil(stored?.photoPath)
    let after = try await backend.messages()
    XCTAssertEqual(after.first { $0.id == photo.id }?.text, L10n.chatOpened)
    XCTAssertEqual(after.first { $0.id == photo.id }?.photo, .opened)
  }

  func testUnopenedViewOnceExpiresAfterSevenDays() async throws {
    let backend = try await signedInAlex()
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    backend.clock = { now }
    try await backend.sendPhoto(PhotoBytes.sample(), retention: .viewOnce)
    let listed = try await backend.messages()
    let photo = try XCTUnwrap(listed.first { $0.photo == .viewOnce })
    now = now.addingTimeInterval(ChatPhoto.lifetime + 60)
    let after = try await backend.messages()
    XCTAssertEqual(after.first { $0.id == photo.id }?.photo, .expired)
    XCTAssertEqual(after.first { $0.id == photo.id }?.text, L10n.chatExpired)
    XCTAssertNil(backend.store.world.chats.first { $0.id == photo.id }?.objectBytes)
  }

  func testKeptPhotoIsDeletedForEitherPartner() async throws {
    let backend = try await signedInAlex()
    try await backend.sendPhoto(PhotoBytes.sample(), retention: .keep)
    let listed = try await backend.messages()
    let photo = try XCTUnwrap(listed.first { $0.photo == .kept })
    XCTAssertNotNil(photo.previewJPEG)
    switchToBlair(backend)
    try await backend.deleteChatPhoto(photo.id)
    XCTAssertNil(backend.store.world.chats.first { $0.id == photo.id })
    let after = try await backend.messages()
    XCTAssertNil(after.first { $0.id == photo.id })
  }

  func testScreenshotLineAndOutsider() async throws {
    let backend = try await signedInAlex()
    try await backend.sendPhoto(PhotoBytes.sample(), retention: .keep)
    let listed = try await backend.messages()
    let photo = try XCTUnwrap(listed.first { $0.photo == .kept })
    switchToBlair(backend)
    try await backend.sendScreenshotNotice()
    switchToAlex(backend)
    let lines = try await backend.messages()
    let notice = try XCTUnwrap(lines.first { $0.notice })
    XCTAssertEqual(notice.text, "Blair took a screenshot")
    switchToCasey(backend)
    let hidden = try await backend.messages()
    XCTAssertNil(hidden.first { $0.id == photo.id })
    do {
      _ = try await backend.chatPhoto(photo.id)
      XCTFail("An outsider read the photo")
    } catch {
      XCTAssertEqual(ErrorMap.app(error), .notEditable)
    }
  }

  private func signedInAlex() async throws -> FakeBackend {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    _ = try await backend.sendCode(email: "alex@couple-a.test")
    _ = try await backend.verify(email: "alex@couple-a.test", code: "000000")
    _ = try backend.ensureKey(userId: SeedID.alex)
    _ = try backend.ensureKey(userId: SeedID.blair)
    return backend
  }

  private func switchToAlex(_ backend: FakeBackend) {
    backend.store.world.sessionUserId = SeedID.alex
  }

  private func switchToBlair(_ backend: FakeBackend) {
    backend.store.world.sessionUserId = SeedID.blair
  }

  private func switchToCasey(_ backend: FakeBackend) {
    backend.store.world.sessionUserId = SeedID.casey
  }
}
