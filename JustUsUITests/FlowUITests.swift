import XCTest

final class FlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testLaunchShowsLogin() {
    let app = launch()
    XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 12))
    XCTAssertTrue(app.staticTexts["loginRoot"].exists || app.otherElements["loginRoot"].exists)
  }

  func testInvalidEmailAndBadCodes() {
    let app = launch()
    let email = app.textFields["emailField"]
    XCTAssertTrue(email.waitForExistence(timeout: 12))
    email.tap()
    email.typeText("not-an-email")
    app.buttons["sendCode"].tap()
    XCTAssertTrue(app.staticTexts["errorBanner"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["loginRoot"].waitForExistence(timeout: 2) || app.otherElements["loginRoot"].exists)

    let wrong = launch()
    signIn(wrong, email: "alex@couple-a.test", code: "222222", expectHome: false)
    XCTAssertTrue(wrong.staticTexts["errorBanner"].waitForExistence(timeout: 5))
    let expired = launch()
    signIn(expired, email: "alex@couple-a.test", code: "111111", expectHome: false)
    XCTAssertTrue(expired.staticTexts["errorBanner"].waitForExistence(timeout: 5))
  }

  func testResendCooldown() {
    let app = launch()
    let email = app.textFields["emailField"]
    XCTAssertTrue(email.waitForExistence(timeout: 12))
    email.tap()
    email.typeText("alex@couple-a.test")
    app.buttons["sendCode"].tap()
    XCTAssertTrue(app.textFields["codeField"].waitForExistence(timeout: 8))
    app.buttons["resendCode"].tap()
    UITestLaunch.record(app)
    XCTAssertTrue(app.staticTexts["errorBanner"].waitForExistence(timeout: 5))
  }

  func testCreateCoupleAndInvite() {
    let app = launch()
    signIn(app, email: "newcomer@example.com", code: "000000", expectHome: false)
    let name = app.textFields["selfName"]
    XCTAssertTrue(name.waitForExistence(timeout: 8))
    name.tap()
    name.typeText("Nova")
    let partner = app.textFields["partnerName"]
    XCTAssertTrue(partner.waitForExistence(timeout: 4))
    // The keyboard covers the second field on SE. Scroll it clear before typing.
    app.scrollViews.firstMatch.swipeUp()
    partner.tap()
    partner.typeText("Rio")
    let create = app.buttons["createCouple"]
    if !create.isHittable { app.scrollViews.firstMatch.swipeUp() }
    create.tap()
    XCTAssertTrue(app.buttons["shareInvite"].waitForExistence(timeout: 8))
  }

  func testInviteFailuresAndReplace() {
    let invalid = launch()
    XCTAssertTrue(invalid.buttons["haveInvite"].waitForExistence(timeout: 12))
    invalid.buttons["haveInvite"].tap()
    XCTAssertTrue(invalid.buttons["inviteBack"].waitForExistence(timeout: 4))
    XCTAssertFalse(invalid.buttons["redeemInvite"].exists)

    let jordan = launch()
    signIn(jordan, email: "jordan@invite.test", code: "000000", expectHome: true)
    jordan.buttons["haveInvite"].tap()
    let own = jordan.textFields["inviteToken"]
    own.tap()
    own.typeText(String(repeating: "a", count: 43))
    jordan.buttons["redeemInvite"].tap()
    XCTAssertTrue(jordan.staticTexts["errorBanner"].waitForExistence(timeout: 5))

    let sam = launch()
    signIn(sam, email: "sam@solo.test", code: "000000", expectHome: true)
    sam.buttons["haveInvite"].tap()
    let token = sam.textFields["inviteToken"]
    XCTAssertTrue(token.waitForExistence(timeout: 4))
    token.tap()
    token.typeText(String(repeating: "a", count: 43))
    sam.buttons["redeemInvite"].tap()
    XCTAssertTrue(sam.buttons["replaceEmpty"].waitForExistence(timeout: 5))
    sam.buttons["replaceEmpty"].tap()
    XCTAssertTrue(sam.buttons["Us"].waitForExistence(timeout: 8))
  }

  func testPlanStaysHiddenFromPartner() {
    let app = launch()
    signIn(app, email: "blair@couple-a.test", code: "000000", expectHome: true)
    XCTAssertTrue(app.otherElements["homeRoot"].waitForExistence(timeout: 8) || app.staticTexts["homeRoot"].exists || app.scrollViews.firstMatch.exists)
    XCTAssertFalse(app.buttons["haveInvite"].exists)
    XCTAssertFalse(app.staticTexts["A table for two"].exists)
    XCTAssertFalse(app.staticTexts["Only the planner knows"].exists)
  }

  func testSignOutReturnsToLogin() {
    let app = launch()
    signIn(app, email: "alex@couple-a.test", code: "000000", expectHome: true)
    app.buttons["Us"].tap()
    let signOut = app.buttons["signOut"]
    if !signOut.waitForExistence(timeout: 2) { app.swipeUp() }
    XCTAssertTrue(signOut.waitForExistence(timeout: 4))
    signOut.tap()
    XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 8))
  }

  func testDeleteRequiresWord() {
    let app = launch()
    signIn(app, email: "demo@justus.app", code: "424242", expectHome: true)
    app.buttons["Us"].tap()
    let delete = app.buttons["deleteAccount"]
    if !delete.waitForExistence(timeout: 2) { app.swipeUp() }
    XCTAssertTrue(delete.waitForExistence(timeout: 4))
    delete.tap()
    app.buttons["deleteSubmit"].tap()
    XCTAssertTrue(app.staticTexts["errorBanner"].waitForExistence(timeout: 5))
  }

  func testAccessibilityAuditAndRTL() throws {
    let app = launch()
    XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 12))
    try app.performAccessibilityAudit()
    let rtl = launch(["-NSForceRightToLeftWritingDirection", "YES"])
    XCTAssertTrue(rtl.textFields["emailField"].waitForExistence(timeout: 12))
  }

  func testPartnerMoodDeepLink() {
    let app = launch()
    signIn(app, email: "alex@couple-a.test", code: "000000", expectHome: true)
    guard let url = URL(string: "justus://uitest/partner-mood") else {
      XCTFail("Missing test URL")
      return
    }
    app.open(url)
    UITestLaunch.record(app)
    let mood = app.staticTexts.matching(NSPredicate(format: "identifier == 'partnerMood' AND label CONTAINS %@", "Easy together")).firstMatch
    XCTAssertTrue(mood.waitForExistence(timeout: 8))
  }

  func launch(_ extra: [String] = []) -> XCUIApplication {
    UITestLaunch.make(extra)
  }

  func signIn(_ app: XCUIApplication, email: String, code: String, expectHome: Bool) {
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
    if expectHome {
      XCTAssertTrue(app.buttons["Us"].waitForExistence(timeout: 8))
    }
  }
}
