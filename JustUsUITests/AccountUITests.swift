import XCTest

final class AccountUITests: XCTestCase {
  func testSuccessfulRedeem() {
    let app = UITestLaunch.make()
    let field = app.textFields["emailField"]
    XCTAssertTrue(field.waitForExistence(timeout: 12))
    field.tap()
    field.typeText("new@redeem.test")
    app.buttons["sendCode"].tap()
    let codeField = app.textFields["codeField"]
    XCTAssertTrue(codeField.waitForExistence(timeout: 8))
    codeField.tap()
    codeField.typeText("000000")
    app.buttons["verifyCode"].tap()
    XCTAssertTrue(app.buttons["joinInstead"].waitForExistence(timeout: 8))
    app.buttons["joinInstead"].tap()
    let token = app.textFields["inviteToken"]
    XCTAssertTrue(token.waitForExistence(timeout: 4))
    token.tap()
    token.typeText(String(repeating: "a", count: 43))
    app.buttons["redeemInvite"].tap()
    XCTAssertTrue(app.buttons["Us"].waitForExistence(timeout: 8))
  }

  func testSuccessfulDeletion() {
    let app = UITestLaunch.make()
    signIn(app, email: "demo@justus.app", code: "424242")
    app.buttons["Us"].tap()
    app.buttons["deleteAccount"].tap()
    let confirm = app.textFields["deleteConfirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 4))
    confirm.tap()
    confirm.typeText("delete")
    app.buttons["deleteSubmit"].tap()
    let email = app.textFields["emailField"]
    XCTAssertTrue(email.waitForExistence(timeout: 8))
    XCTAssertFalse((email.value as? String)?.contains("demo@") == true)
  }

  func testSignOutClearsDraft() {
    let app = UITestLaunch.make()
    signIn(app, email: "alex@couple-a.test")
    app.buttons["Us"].tap()
    app.buttons["signOut"].tap()
    let email = app.textFields["emailField"]
    XCTAssertTrue(email.waitForExistence(timeout: 8))
    XCTAssertFalse((email.value as? String)?.contains("alex@") == true)
    signIn(app, email: "sam@solo.test")
    XCTAssertFalse(app.staticTexts["Come hungry"].exists)
  }

  func testMemoriesShowPhoto() {
    let app = UITestLaunch.make()
    signIn(app, email: "riley@busy.test")
    app.buttons["Memories"].tap()
    let photo = app.descendants(matching: .any)["memoryPhoto"]
    XCTAssertTrue(photo.waitForExistence(timeout: 8))
  }

  func testSavingSettings() {
    let app = UITestLaunch.make()
    signIn(app, email: "alex@couple-a.test")
    app.buttons["Us"].tap()
    var name = app.textFields["selfName"]
    for _ in 0..<4 where name.isHittable == false {
      app.swipeUp()
      name = app.textFields["selfName"]
    }
    XCTAssertTrue(name.waitForExistence(timeout: 4))
    name.tap()
    if let existing = name.value as? String, existing != "My name" {
      name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
    }
    name.typeText("Alexandra")
    let save = app.buttons["saveSettings"]
    if save.isHittable == false { app.swipeUp() }
    XCTAssertTrue(save.waitForExistence(timeout: 4))
    save.tap()
    XCTAssertTrue(app.staticTexts["Alexandra"].waitForExistence(timeout: 8))
  }

  func testUnlinkAsksFirst() {
    let app = UITestLaunch.make()
    signIn(app, email: "alex@couple-a.test")
    app.buttons["Us"].tap()
    let unlink = app.buttons["unlink"]
    if !unlink.waitForExistence(timeout: 2) {
      app.swipeUp()
    }
    XCTAssertTrue(unlink.waitForExistence(timeout: 4))
    unlink.tap()
    XCTAssertTrue(app.buttons["unlinkConfirm"].waitForExistence(timeout: 4))
    app.buttons["unlinkConfirm"].tap()
    XCTAssertTrue(app.textFields["selfName"].waitForExistence(timeout: 8))
  }

  func testOfflineRetry() {
    let app = UITestLaunch.make()
    signIn(app, email: "alex@couple-a.test")
    guard let url = URL(string: "justus://uitest/offline") else {
      XCTFail("Missing test URL")
      return
    }
    app.open(url)
    XCTAssertTrue(app.staticTexts["offlineBanner"].waitForExistence(timeout: 8))
    app.buttons["retryButton"].tap()
    XCTAssertTrue(app.buttons["Us"].waitForExistence(timeout: 8))
  }

  private func signIn(_ app: XCUIApplication, email: String, code: String = "000000") {
    let field = app.textFields["emailField"]
    XCTAssertTrue(field.waitForExistence(timeout: 12))
    field.tap()
    field.typeText(email)
    app.buttons["sendCode"].tap()
    let codeField = app.textFields["codeField"]
    XCTAssertTrue(codeField.waitForExistence(timeout: 8))
    codeField.tap()
    codeField.typeText(code)
    app.buttons["verifyCode"].tap()
    XCTAssertTrue(app.buttons["Us"].waitForExistence(timeout: 8))
  }
}
