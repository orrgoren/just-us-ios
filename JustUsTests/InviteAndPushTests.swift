import UserNotifications
import XCTest
@testable import JustUs

@MainActor
final class InviteAndPushTests: XCTestCase {
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

  private var token: String { String(repeating: "a", count: 43) }

  private func signedIn(_ email: String, backend: FakeBackend? = nil) async -> (SessionModel, FakeBackend) {
    let backend = backend ?? FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = email
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    return (model, backend)
  }

  func testShareTextLeadsWithTheAppLink() throws {
    let token = String(repeating: "a", count: 43)
    let body = try XCTUnwrap(InviteLinks.shareText(token: token, webBase: "https://just-us-six-gray.vercel.app"))
    let app = "justus://invite/\(token)"
    let web = "https://just-us-six-gray.vercel.app/invite/\(token)"
    XCTAssertTrue(body.contains(app))
    XCTAssertTrue(body.contains(web))
    XCTAssertTrue(body.contains(token))
    XCTAssertLessThan(body.range(of: app)?.lowerBound ?? body.endIndex, body.range(of: web)?.lowerBound ?? body.startIndex)
    XCTAssertNil(InviteLinks.shareText(token: "short", webBase: "https://example.com"))
    XCTAssertEqual(InviteLinks.appURL(token: token)?.absoluteString, app)
    let bare = try XCTUnwrap(InviteLinks.shareText(token: token, webBase: "just-us.example"))
    XCTAssertTrue(bare.contains("https://just-us.example/invite/\(token)"))
    let otherScheme = try XCTUnwrap(InviteLinks.shareText(token: token, webBase: "ftp://files.example"))
    XCTAssertTrue(otherScheme.contains("https://files.example/invite/\(token)"))
  }

  func testDeepLinkBeforeSignInOpensJoinWithTheCode() async throws {
    let token = SeedID.validToken
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.screen = .login
    let link = try XCTUnwrap(URL(string: "justus://invite/\(token)"))
    await model.open(link)
    XCTAssertEqual(model.screen, .invite)
    XCTAssertEqual(model.inviteInput, token)
    XCTAssertEqual(PendingInviteStore.current(), token)

    model.email = "guest-join@example.com"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    XCTAssertEqual(model.screen, .invite)
    XCTAssertEqual(model.inviteInput, token)
    XCTAssertNotEqual(model.screen, .setup)
    XCTAssertNotEqual(model.screen, .main)

    await model.redeem(replaceEmpty: false)
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertEqual(model.screen, .softPrompt)
    XCTAssertNil(model.errorMessage)
  }

  func testPastedLinkSurvivesSignInUntilItIsRejected() async throws {
    let token = SeedID.usedToken
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.screen = .login
    model.inviteInput = "justus://invite/\(token)"
    XCTAssertEqual(PendingInviteStore.current(), token)

    model.email = "guest-used@example.com"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    XCTAssertEqual(model.screen, .invite)
    XCTAssertEqual(model.inviteInput, token)

    await model.redeem(replaceEmpty: false)
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertEqual(model.errorMessage, L10n.message(for: .usedInvite))
    XCTAssertEqual(model.screen, .invite)
  }

  func testOfflineRedeemKeepsThePendingCode() async {
    let token = SeedID.validToken
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.inviteInput = token
    model.email = "guest-offline@example.com"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    backend.setOffline(true)
    await model.redeem(replaceEmpty: false)
    XCTAssertEqual(PendingInviteStore.current(), token)
    XCTAssertEqual(model.screen, .invite)
    XCTAssertEqual(model.errorMessage, L10n.message(for: .offline))
  }

  func testWebsiteInviteURLPrefillsTheJoinScreen() async throws {
    let token = String(repeating: "e", count: 43)
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.screen = .login
    let link = try XCTUnwrap(URL(string: "https://just-us-six-gray.vercel.app/invite/\(token)"))
    await model.open(link)
    XCTAssertEqual(model.screen, .invite)
    XCTAssertEqual(model.inviteInput, token)
    XCTAssertEqual(PendingInviteStore.current(), token)
  }

  func testAppleSignInKeepsThePendingInvite() async {
    let token = SeedID.validToken
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.screen = .login
    model.inviteInput = token
    await model.completeApple(token: "token", nonce: "nonce")
    XCTAssertTrue(model.signedIn)
    XCTAssertEqual(model.screen, .invite)
    XCTAssertEqual(model.inviteInput, token)
  }

  func testStayingClearsThePendingInvite() async {
    let token = SeedID.validToken
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "sam@solo.test"
    await model.sendCode()
    model.code = "000000"
    await model.verify()
    model.inviteInput = token
    model.pendingReplace = true
    model.screen = .invite
    model.declineInvite()
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertFalse(model.pendingReplace)
  }

  func testPushRegistersWhenAlreadyAuthorizedOrProvisional() {
    XCTAssertTrue(PushRegistration.shouldRegister(.authorized))
    XCTAssertTrue(PushRegistration.shouldRegister(.provisional))
    XCTAssertFalse(PushRegistration.shouldRegister(.notDetermined))
    XCTAssertFalse(PushRegistration.shouldRegister(.denied))
    XCTAssertFalse(PushRegistration.shouldRegister(.ephemeral))
    XCTAssertEqual(
      PushRegistration.action(status: .authorized, pushEnabled: true, alreadyAsked: true),
      .register
    )
    XCTAssertEqual(
      PushRegistration.action(status: .provisional, pushEnabled: true, alreadyAsked: false),
      .register
    )
    XCTAssertEqual(
      PushRegistration.action(status: .authorized, pushEnabled: false, alreadyAsked: false),
      .none
    )
    XCTAssertEqual(
      PushRegistration.action(status: .notDetermined, pushEnabled: true, alreadyAsked: false),
      .offerPrompt
    )
    XCTAssertEqual(
      PushRegistration.action(status: .notDetermined, pushEnabled: true, alreadyAsked: true),
      .none
    )
    XCTAssertEqual(
      PushRegistration.action(status: .denied, pushEnabled: true, alreadyAsked: true),
      .none
    )
  }

  func testDeviceTokenStaysPendingUntilTheSaveSucceeds() {
    var record = DeviceTokenRecord(token: nil, awaitingSave: false)
    record.received("abc123")
    XCTAssertEqual(record.token, "abc123")
    XCTAssertTrue(record.awaitingSave)
    DeviceTokenStore.save(record)
    var loaded = DeviceTokenStore.load()
    XCTAssertEqual(loaded, record)
    loaded.saved()
    DeviceTokenStore.save(loaded)
    XCTAssertFalse(DeviceTokenStore.load().awaitingSave)
    XCTAssertEqual(DeviceTokenStore.load().token, "abc123")
    var again = DeviceTokenStore.load()
    again.removedFromAccount()
    XCTAssertTrue(again.awaitingSave)
    XCTAssertEqual(again.token, "abc123")
    XCTAssertTrue(InviteOutcome.rejects(.usedInvite))
    XCTAssertFalse(InviteOutcome.rejects(.offline))
  }

  func testTokenShapeRejectsATrailingNewline() {
    XCTAssertTrue(InviteRules.isTokenShape(token))
    XCTAssertFalse(InviteRules.isTokenShape(token + "\n"))
  }

  func testMalformedInviteLinkIsIgnored() async throws {
    let short = try XCTUnwrap(URL(string: "justus://invite/short"))
    let empty = try XCTUnwrap(URL(string: "justus://invite/"))
    XCTAssertNil(DeepLinks.route(from: short))
    XCTAssertNil(DeepLinks.route(from: empty))
    let model = SessionModel(backend: FakeBackend())
    model.screen = .login
    await model.open(short)
    XCTAssertEqual(model.screen, .login)
  }

  func testSignOutClearsAPendingInvite() async {
    let (model, _) = await signedIn("sam@solo.test")
    model.inviteInput = token
    XCTAssertEqual(PendingInviteStore.current(), token)
    await model.signOut()
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertEqual(model.inviteInput, "")
    XCTAssertEqual(model.screen, .login)
  }

  func testEmptyInviteFieldClearsAStoredCode() {
    let model = SessionModel(backend: FakeBackend())
    model.inviteInput = token
    model.inviteInput = ""
    XCTAssertNil(PendingInviteStore.current())
    model.inviteInput = token
    model.inviteInput = " \n"
    XCTAssertNil(PendingInviteStore.current())
  }

  func testBackClearsAPendingInvite() {
    let model = SessionModel(backend: FakeBackend())
    model.screen = .login
    model.inviteInput = token
    model.leaveInvite()
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertEqual(model.inviteInput, "")
    XCTAssertEqual(model.screen, .login)
  }

  func testAccountSwitchDropsThePreviousInvite() async {
    let (model, _) = await signedIn("alex@couple-a.test")
    model.inviteInput = token
    XCTAssertEqual(PendingInviteStore.current(), token)
    await model.completeApple(token: "apple-token", nonce: "nonce")
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertNotEqual(model.screen, .invite)
  }

  func testCreateCoupleClearsAPendingInvite() async {
    let (model, _) = await signedIn("newcomer@example.com")
    model.draft.selfName = "Nova"
    model.draft.partnerName = "Rio"
    model.draft.timezone = "America/New_York"
    model.inviteInput = token
    await model.createCouple()
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertEqual(model.screen, .inviteShare)
  }

  func testPairedSignInDropsAPendingCode() async {
    PendingInviteStore.save(token, account: nil)
    let (model, _) = await signedIn("alex@couple-a.test")
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertEqual(model.screen, .main)
  }

  func testPairedColdLaunchDropsAPendingCode() async {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let (signedIn, _) = await self.signedIn("alex@couple-a.test", backend: backend)
    signedIn.inviteInput = token
    XCTAssertEqual(PendingInviteStore.current(), token)

    let relaunched = SessionModel(backend: backend)
    relaunched.screen = .loading
    await relaunched.start()
    XCTAssertNotEqual(relaunched.screen, .invite)
    XCTAssertNil(PendingInviteStore.current())
    XCTAssertTrue(relaunched.signedIn)
  }

  func testColdLaunchDoesNotOpenJoin() async {
    PendingInviteStore.save(token, account: nil)
    let model = SessionModel(backend: FakeBackend())
    model.screen = .loading
    await model.start()
    XCTAssertEqual(model.screen, .login)
    XCTAssertEqual(PendingInviteStore.current(), token)
  }

  func testDeletingTheAccountClearsAPendingInvite() async {
    let (model, _) = await signedIn("sam@solo.test")
    model.inviteInput = token
    model.deleteConfirm = L10n.deleteWord
    await model.deleteAccount()
    XCTAssertNil(PendingInviteStore.current())
  }

  func testMissingColumnSaveFallsBackAndOtherFailuresDoNot() {
    struct Stub: Error, CustomStringConvertible {
      var description: String
    }
    let missing = Stub(description: "Could not find the 'environment' column of 'device_tokens' in the schema cache")
    let network = Stub(description: "network timeout")
    XCTAssertTrue(DeviceTokenSave.missingEnvironmentColumn(missing))
    XCTAssertFalse(DeviceTokenSave.missingEnvironmentColumn(network))
    XCTAssertEqual(DeviceTokenSave.afterFailure(missing, attemptedPlain: false), .upsertPlain)
    XCTAssertEqual(DeviceTokenSave.afterFailure(missing, attemptedPlain: true), .giveUp)
    XCTAssertEqual(DeviceTokenSave.afterFailure(network, attemptedPlain: false), .giveUp)
  }

  func testAFailedTokenDeleteStaysPendingUntilItSucceeds() {
    let older = PendingTokenDelete(userId: UUID(), token: "abc123")
    let newer = PendingTokenDelete(userId: UUID(), token: "def456")
    DeviceTokenStore.saveDelete(older)
    XCTAssertEqual(DeviceTokenStore.loadDelete(), older)
    let kept = PendingDelete.replacement(existing: older, retryCleared: false, failed: newer)
    XCTAssertEqual(kept, older)
    let replaced = PendingDelete.replacement(existing: older, retryCleared: true, failed: newer)
    XCTAssertEqual(replaced, newer)
    DeviceTokenStore.clearDelete()
    XCTAssertNil(DeviceTokenStore.loadDelete())
  }
}
