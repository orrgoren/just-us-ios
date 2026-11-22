import XCTest

final class ScreenshotUITests: XCTestCase {
  func testNamedScreens() {
    let screens = [
      "login", "code", "setup", "inviteShare", "softPrompt", "inviteRedeem",
      "inviteReplace", "inviteBlocked", "homeSolo", "homePlanner", "homePartner",
      "reveal", "memories", "memoriesEmpty", "settings", "deleteAccount",
      "offline", "chat", "chatBadge",
      "chatPhoto", "chatPhotoChoice",
      "plannerTools", "settingsBottom", "photoMemory", "selectedMood", "revealedPlan", "editHint",
      "errorBanner", "unlinkConfirm", "postDeletion", "spaceClosed", "notificationTap", "signOut"
    ]
    let scrolled: Set<String> = [
      "homePlanner", "reveal", "memories", "settings", "deleteAccount",
      "plannerTools", "settingsBottom", "photoMemory", "revealedPlan", "editHint", "unlinkConfirm", "signOut",
      "chatPhoto"
    ]
    for screen in screens {
      capture(screen: screen, appearance: "light", size: nil, swipe: scrolled.contains(screen))
      capture(screen: screen, appearance: "dark", size: nil, swipe: scrolled.contains(screen))
    }
    for screen in ["login", "homePlanner", "settings"] {
      capture(screen: screen, appearance: "light", size: "UICTContentSizeCategoryXS")
      capture(screen: screen, appearance: "light", size: "UICTContentSizeCategoryAccessibilityXXXL")
    }
    capture(screen: "chat", appearance: "light", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-chat")
    capture(screen: "chatBadge", appearance: "light", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-chat-badge")
    capture(screen: "homePlanner", appearance: "light", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-home")
    capture(screen: "settings", appearance: "dark", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-settings")
    capture(screen: "memories", appearance: "light", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-memories")
    for screen in ["login", "homePlanner", "settings", "chat", "memories"] {
      capture(screen: screen, appearance: "light", size: nil, extra: ["-JustUsLanguage", "he"], name: "he-\(screen)")
      capture(screen: screen, appearance: "dark", size: nil, extra: ["-JustUsLanguage", "he"], name: "he-\(screen)")
    }
  }

  private func capture(
    screen: String,
    appearance: String,
    size: String?,
    swipe: Bool = false,
    extra: [String] = [],
    name: String? = nil
  ) {
    let app = XCUIApplication()
    var arguments = ["-uitest", "-JustUsScreen", screen, "-JustUsAppearance", appearance] + extra
    if let size {
      arguments += ["-UIPreferredContentSizeCategoryName", size]
    }
    app.launchArguments = arguments
    app.launch()
    if screen == "login" || screen == "postDeletion" {
      _ = app.textFields["emailField"].waitForExistence(timeout: 10)
    } else if screen == "spaceClosed" {
      XCTAssertTrue(app.staticTexts["spaceClosed"].waitForExistence(timeout: 10))
    } else if screen == "chat" || screen == "chatPhoto" || screen == "chatPhotoChoice" {
      _ = app.buttons["chatClose"].waitForExistence(timeout: 10)
    } else {
      _ = app.staticTexts["Just Us"].waitForExistence(timeout: 10)
    }
    if screen == "homePlanner" || screen == "homePartner" || screen == "settings" {
      XCTAssertFalse(app.buttons["Chat"].exists)
      XCTAssertTrue(app.buttons["chatBubble"].waitForExistence(timeout: 4))
      XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chatBadge").count, 0)
    }
    if screen == "homeSolo" || screen == "memoriesEmpty" {
      XCTAssertFalse(app.buttons["chatBubble"].exists)
    }
    if screen == "chatBadge" {
      XCTAssertFalse(app.buttons["Chat"].exists)
      XCTAssertTrue(app.buttons["chatBubble"].waitForExistence(timeout: 4))
      XCTAssertTrue(app.descendants(matching: .any)["chatBadge"].waitForExistence(timeout: 4))
    }
    if screen == "chat" || screen == "chatPhoto" {
      let field = app.descendants(matching: .any)["chatField"]
      XCTAssertTrue(field.waitForExistence(timeout: 8))
      XCTAssertTrue(app.buttons["chatAttach"].exists)
      XCTAssertFalse(app.buttons["chatSend"].exists)
    }
    if screen == "chat" {
      let days = app.descendants(matching: .any).matching(identifier: "chatDay")
      XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 8))
      XCTAssertGreaterThanOrEqual(days.count, 2)
    }
    let label = name ?? screen
    addShot(app, screen: label, appearance: appearance, size: size, suffix: nil)
    if swipe {
      app.swipeUp()
      addShot(app, screen: label, appearance: appearance, size: size, suffix: "scrolled")
    }
    if screen == "chat", appearance == "light", size == nil, extra.isEmpty, name == nil {
      app.buttons["chatAttach"].tap()
      let library = app.buttons["Photo library"]
      XCTAssertTrue(library.waitForExistence(timeout: 4))
      XCTAssertTrue(app.buttons["Camera"].exists)
      XCTAssertTrue(app.buttons["chatPhoto"].waitForExistence(timeout: 4))
      XCTAssertTrue(app.buttons["Send a sample photo"].exists)
      dismissAttachMenu(app, library: library)
      let field = app.descendants(matching: .any)["chatField"]
      field.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
      field.typeText("hi")
      XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 4))
      addShot(app, screen: label, appearance: appearance, size: size, suffix: "keyboard")
      let done = app.buttons["dismissKeyboard"]
      XCTAssertTrue(done.waitForExistence(timeout: 4))
      XCTAssertEqual(done.label, "Done")
      done.tap()
      let gone = NSPredicate(format: "exists == false")
      XCTAssertEqual(
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.keyboards.firstMatch)], timeout: 4),
        .completed
      )
      addShot(app, screen: label, appearance: appearance, size: size, suffix: "dismissed")
    }
    app.terminate()
  }

  /// The system Cancel on a confirmation dialog is outside this app's button list.
  private func dismissAttachMenu(_ app: XCUIApplication, library: XCUIElement) {
    if app.buttons["Cancel"].exists {
      app.buttons["Cancel"].tap()
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    }
    let gone = NSPredicate(format: "exists == false")
    let dismissed = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: library)], timeout: 2)
    guard dismissed != .completed else { return }
    app.swipeDown()
    _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: library)], timeout: 2)
  }

  private func addShot(_ app: XCUIApplication, screen: String, appearance: String, size: String?, suffix: String?) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    let prefix = screenshotPrefix()
    let sizeName = size == nil ? "default" : (size?.contains("Accessibility") == true ? "ax" : "xs")
    var parts = [prefix, screen, appearance, sizeName]
    if let suffix { parts.append(suffix) }
    shot.name = parts.joined(separator: "-")
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func screenshotPrefix() -> String {
    let environment = ProcessInfo.processInfo.environment
    if let value = environment["TEST_RUNNER_SCREENSHOT_PREFIX"], !value.isEmpty { return value }
    if let value = environment["SCREENSHOT_PREFIX"], !value.isEmpty { return value }
    let file = URL(fileURLWithPath: "/tmp/justus-screenshot-prefix.txt")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return "device"
  }
}
