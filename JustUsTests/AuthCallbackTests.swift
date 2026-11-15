import XCTest
@testable import JustUs

@MainActor
final class AuthCallbackTests: XCTestCase {
  func testRedirectIsTheAllowListedCallback() throws {
    XCTAssertEqual(AuthCallback.redirect?.absoluteString, "justus://auth-callback")
    let pkce = URL(string: "justus://auth-callback?code=pkce-code")
    let implicit = URL(string: "justus://auth-callback#access_token=a&refresh_token=b")
    let invite = URL(string: "justus://invite/\(String(repeating: "a", count: 43))")
    XCTAssertTrue(AuthCallback.isCallback(try XCTUnwrap(pkce)))
    XCTAssertTrue(AuthCallback.isCallback(try XCTUnwrap(implicit)))
    XCTAssertFalse(AuthCallback.isCallback(try XCTUnwrap(invite)))
    XCTAssertNil(DeepLinks.route(from: try XCTUnwrap(pkce)))
    XCTAssertNil(DeepLinks.route(from: try XCTUnwrap(implicit)))
  }

  func testCallbackURLSignsInThePendingEmail() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    XCTAssertEqual(model.screen, .code)

    let pkce = try XCTUnwrap(URL(string: "justus://auth-callback?code=pkce-code"))
    await model.open(pkce)
    XCTAssertTrue(model.signedIn)
    XCTAssertEqual(model.screen, .main)
    XCTAssertNil(model.errorMessage)
    let restored = try await backend.restore()
    XCTAssertEqual(restored?.email, "alex@couple-a.test")
  }

  func testImplicitFragmentSignsInAndOtherLinksDoNot() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.screen = .code
    let fragment = try XCTUnwrap(URL(string: "justus://auth-callback#access_token=a&refresh_token=b"))
    await model.open(fragment)
    XCTAssertFalse(model.signedIn)
    XCTAssertEqual(model.screen, .login)
    XCTAssertTrue(model.offerNewLink)
    XCTAssertEqual(model.errorMessage, L10n.message(for: .linkExpired))

    model.email = "new@example.com"
    await model.sendCode()
    await model.open(fragment)
    XCTAssertTrue(model.signedIn)
    XCTAssertEqual(model.screen, .setup)

    let invite = try XCTUnwrap(URL(string: "justus://invite/\(String(repeating: "b", count: 43))"))
    let signedOut = SessionModel(backend: FakeBackend(store: FakeStore(inMemory: true), cooldown: 0))
    signedOut.screen = .login
    await signedOut.open(invite)
    XCTAssertFalse(signedOut.signedIn)
    XCTAssertEqual(signedOut.screen, .invite)
    XCTAssertEqual(signedOut.inviteInput, String(repeating: "b", count: 43))
  }

  func testSignOutThenExpiredLinkCanRequestANewOne() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    let model = SessionModel(backend: backend)
    model.email = "alex@couple-a.test"
    await model.sendCode()
    let link = try XCTUnwrap(URL(string: "justus://auth-callback?code=pkce-code"))
    await model.open(link)
    XCTAssertTrue(model.signedIn)

    await model.sendCode()
    XCTAssertNotNil(backend.codeVerifier)
    XCTAssertFalse(backend.store.world.otpSentAt.isEmpty)

    await model.signOut()
    XCTAssertFalse(model.signedIn)
    let restored = try await backend.restore()
    XCTAssertNil(restored)
    XCTAssertNil(backend.codeVerifier)
    XCTAssertTrue(backend.store.world.otpSentAt.isEmpty)
    XCTAssertEqual(model.screen, .login)
    XCTAssertEqual(model.email, "")
    XCTAssertFalse(model.offerNewLink)

    await model.open(link)
    XCTAssertFalse(model.signedIn)
    XCTAssertEqual(model.screen, .login)
    XCTAssertTrue(model.offerNewLink)
    XCTAssertEqual(model.email, "alex@couple-a.test")
    XCTAssertEqual(model.errorMessage, L10n.message(for: .linkExpired))
    XCTAssertEqual(model.retryKind, .sendCode)

    let expired = try XCTUnwrap(URL(
      string: "justus://auth-callback?error=access_denied&error_code=otp_expired&error_description=Email%20link%20is%20invalid%20or%20has%20expired"
    ))
    await model.open(expired)
    XCTAssertEqual(model.screen, .login)
    XCTAssertTrue(model.offerNewLink)
    XCTAssertEqual(model.email, "alex@couple-a.test")
    XCTAssertEqual(model.errorMessage, L10n.message(for: .linkExpired))

    await model.sendCode()
    XCTAssertEqual(model.screen, .code)
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.offerNewLink)
    XCTAssertNotNil(backend.codeVerifier)
    XCTAssertNotNil(backend.store.world.otpSentAt["alex@couple-a.test"])
  }
}
