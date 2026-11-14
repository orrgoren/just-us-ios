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
    XCTAssertEqual(model.screen, .code)
    XCTAssertNotNil(model.errorMessage)

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
}
