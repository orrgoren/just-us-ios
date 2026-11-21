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
    typeFocused(app.textFields["selfName"], "Nova", in: app)
    typeFocused(app.textFields["partnerName"], "Rio", in: app)
    tapReady(app.buttons["createCouple"], in: app)
    XCTAssertTrue(app.buttons["shareInvite"].waitForExistence(timeout: 8))
    let appLink = app.staticTexts["appInviteLink"]
    XCTAssertTrue(appLink.waitForExistence(timeout: 4))
    XCTAssertTrue(appLink.label.hasPrefix("justus://invite/"))
  }

  func testInviteFailuresAndReplace() {
    let invalid = launch()
    XCTAssertTrue(invalid.buttons["haveInvite"].waitForExistence(timeout: 12))
    invalid.buttons["haveInvite"].tap()
    XCTAssertTrue(invalid.buttons["inviteBack"].waitForExistence(timeout: 4))
    XCTAssertTrue(invalid.textFields["inviteToken"].waitForExistence(timeout: 4))
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
    openUs(app)
    let signOut = app.buttons["signOut"]
    reveal(signOut, in: app)
    signOut.tap()
    XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 8))
  }

  func testDeleteRequiresWord() {
    let app = launch()
    signIn(app, email: "demo@justus.app", code: "424242", expectHome: true)
    openUs(app)
    let delete = app.buttons["deleteAccount"]
    reveal(delete, in: app)
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

  /// Scrolls until the field can be tapped, then waits until that field has keyboard focus.
  private func typeFocused(_ field: XCUIElement, _ text: String, in app: XCUIApplication) {
    XCTAssertTrue(field.waitForExistence(timeout: 8))
    let focused = NSPredicate(format: "hasKeyboardFocus == true AND isHittable == true")
    for _ in 0..<6 {
      if !field.isHittable {
        app.scrollViews.firstMatch.swipeUp()
      }
      field.tap()
      let ready = XCTNSPredicateExpectation(predicate: focused, object: field)
      if XCTWaiter().wait(for: [ready], timeout: 3) == .completed {
        field.typeText(text)
        return
      }
      app.scrollViews.firstMatch.swipeUp()
    }
    XCTFail("Field did not take keyboard focus")
  }

  private func tapReady(_ element: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(element.waitForExistence(timeout: 8))
    dismissKeyboard(app)
    let scroll = app.scrollViews["mainContent"]
    for _ in 0..<8 {
      if shows(element, in: app) {
        element.tap()
        return
      }
      drag(scroll)
    }
    XCTAssertTrue(shows(element, in: app))
    element.tap()
  }

  /// `isHittable` fails the test when a scrolled-away frame has no activation point.
  private func shows(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    guard element.exists else { return false }
    let frame = element.frame
    guard frame.isNull == false, frame.isInfinite == false, frame.width > 2, frame.height > 2 else {
      return false
    }
    let screen = app.windows.firstMatch.frame.insetBy(dx: 1, dy: 24)
    return screen.contains(CGPoint(x: frame.midX, y: frame.midY))
  }

  /// The keyboard pins the focused field, so Create stays below it until the keyboard closes.
  private func dismissKeyboard(_ app: XCUIApplication) {
    let done = app.buttons["dismissKeyboard"]
    if done.waitForExistence(timeout: 2), done.isHittable {
      done.tap()
    } else {
      drag(app.scrollViews["mainContent"])
    }
    let gone = NSPredicate(format: "exists == false")
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: gone, object: app.keyboards.firstMatch)],
      timeout: 3
    )
  }

  private func drag(_ scroll: XCUIElement) {
    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
    let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  private func openUs(_ app: XCUIApplication) {
    let scroll = app.scrollViews["mainContent"]
    if scroll.exists { scroll.swipeDown() }
    let us = app.buttons["Us"]
    XCTAssertTrue(us.waitForExistence(timeout: 4))
    us.tap()
  }

  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<4 where !element.exists || !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.waitForExistence(timeout: 4))
  }

  func launch(_ extra: [String] = []) -> XCUIApplication {
    UITestLaunch.make(extra)
  }

  func signIn(_ app: XCUIApplication, email: String, code: String, expectHome: Bool) {
    let field = app.textFields["emailField"]
    XCTAssertTrue(field.waitForExistence(timeout: 12))
    field.tap()
    field.typeText(email)
    tapAboveKeyboard("sendCode", in: app, record: true)
    let codeField = app.textFields["codeField"]
    XCTAssertTrue(codeField.waitForExistence(timeout: 8))
    typeCode(code, into: codeField, in: app)
    tapAboveKeyboard("verifyCode", in: app, record: false)
    if expectHome {
      XCTAssertTrue(app.buttons["Us"].waitForExistence(timeout: 8))
    }
  }

  /// The email keyboard is often still closing when the code field appears.
  /// A number pad also ignores `typeText` until the field actually has focus.
  private func typeCode(_ code: String, into field: XCUIElement, in app: XCUIApplication) {
    let gone = NSPredicate(format: "exists == false")
    _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.keyboards.firstMatch)], timeout: 3)
    let focused = NSPredicate(format: "hasKeyboardFocus == true")
    for _ in 0..<4 {
      field.tap()
      let ready = XCTNSPredicateExpectation(predicate: focused, object: field)
      guard XCTWaiter().wait(for: [ready], timeout: 2) == .completed else { continue }
      let zero = app.keyboards.keys["0"]
      if zero.waitForExistence(timeout: 1) {
        for character in code {
          app.keyboards.keys[String(character)].tap()
        }
      } else {
        field.typeText(code)
      }
      return
    }
    field.typeText(code)
  }

  private static var recordedKeyboard = false

  /// The send and verify buttons have to sit above the keyboard. The first
  /// one keeps a screenshot so the SE job shows the keyboard-up layout.
  private func tapAboveKeyboard(_ identifier: String, in app: XCUIApplication, record: Bool) {
    let button = app.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 4))
    let keyboard = app.keyboards.firstMatch
    guard keyboard.waitForExistence(timeout: 2), keyboard.frame.height > 20 else {
      button.tap()
      return
    }
    let above = NSPredicate { _, _ in
      let frame = button.frame
      return frame.height > 2 && frame.midY > 12 && frame.midY <= keyboard.frame.minY
    }
    let ready = XCTNSPredicateExpectation(predicate: above, object: nil)
    XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 8), .completed)
    if record && !Self.recordedKeyboard {
      Self.recordedKeyboard = true
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "se-keyboard-login"
      shot.lifetime = .keepAlways
      add(shot)
    }
    button.tap()
  }
}
