import XCTest

final class PushUITests: XCTestCase {
  func testForegroundPushRoutesToReveal() {
    let app = UITestLaunch.make(["-JustUsPush", "plan_ready"])
    let email = app.textFields["emailField"]
    XCTAssertTrue(email.waitForExistence(timeout: 12))
    email.tap()
    email.typeText("blair@couple-a.test")
    app.buttons["sendCode"].tap()
    let code = app.textFields["codeField"]
    XCTAssertTrue(code.waitForExistence(timeout: 8))
    code.tap()
    code.typeText("000000")
    app.buttons["verifyCode"].tap()
    XCTAssertTrue(app.buttons["Us"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["A night is on the way"].waitForExistence(timeout: 10))
  }
}
