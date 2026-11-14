import AuthenticationServices
import XCTest
@testable import JustUs

@MainActor
final class AppleSignInTests: XCTestCase {
  func testCanceledAppleSignInStaysQuiet() {
    let model = SessionModel(backend: FakeBackend(store: FakeStore(inMemory: true), cooldown: 0))
    model.screen = .login
    model.errorMessage = "existing"
    model.reportApple(ASAuthorizationError(.canceled))
    XCTAssertEqual(model.errorMessage, "existing")
    XCTAssertEqual(model.screen, .login)
    XCTAssertFalse(model.signedIn)
  }

  func testAuthorizationErrorShowsCodeAndDescription() {
    let model = SessionModel(backend: FakeBackend(store: FakeStore(inMemory: true), cooldown: 0))
    model.screen = .login
    let error = ASAuthorizationError(.unknown)
    model.reportApple(error)
    let message = AppleSignInFailure.message(for: error)
    XCTAssertEqual(model.errorMessage, message)
    XCTAssertTrue(message.contains(String(error.code.rawValue)))
    XCTAssertTrue(message.contains(error.localizedDescription))
    XCTAssertEqual(model.screen, .login)
    XCTAssertFalse(model.signedIn)
  }
}
