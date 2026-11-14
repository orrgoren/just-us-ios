import XCTest

final class PushUITests: XCTestCase {
  func testForegroundPushRoutesToReveal() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-uitest"]
    app.launch()
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
    let bundle = Bundle(for: PushUITests.self)
    let fixture = try XCTUnwrap(
      bundle.url(forResource: "plan-ready", withExtension: "apns")
        ?? bundle.url(forResource: "plan-ready", withExtension: "apns", subdirectory: "apns")
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "push", "booted", fixture.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertTrue(app.staticTexts["A night is on the way"].waitForExistence(timeout: 10))
  }
}
