import XCTest

final class ScreenshotUITests: XCTestCase {
  func testNamedScreens() {
    let screens = [
      "login", "code", "setup", "inviteShare", "softPrompt", "inviteRedeem",
      "inviteReplace", "inviteBlocked", "homeSolo", "homePlanner", "homePartner",
      "reveal", "memories", "memoriesEmpty", "settings", "deleteAccount", "offline", "chat",
      "plannerTools", "settingsBottom", "photoMemory", "selectedMood", "revealedPlan", "editHint",
      "errorBanner", "unlinkConfirm", "postDeletion", "spaceClosed", "notificationTap", "signOut"
    ]
    let scrolled: Set<String> = [
      "homePlanner", "reveal", "memories", "settings", "deleteAccount",
      "plannerTools", "settingsBottom", "photoMemory", "revealedPlan", "editHint", "unlinkConfirm", "signOut"
    ]
    for screen in screens {
      capture(screen: screen, appearance: "light", size: nil, swipe: scrolled.contains(screen))
      capture(screen: screen, appearance: "dark", size: nil, swipe: scrolled.contains(screen))
    }
    for screen in ["login", "homePlanner", "settings"] {
      capture(screen: screen, appearance: "light", size: "UICTContentSizeCategoryXS")
      capture(screen: screen, appearance: "light", size: "UICTContentSizeCategoryAccessibilityXXXL")
    }
    capture(screen: "homePlanner", appearance: "light", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-home")
    capture(screen: "settings", appearance: "dark", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-settings")
    capture(screen: "memories", appearance: "light", size: nil, extra: ["-NSForceRightToLeftWritingDirection", "YES"], name: "rtl-memories")
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
    } else {
      _ = app.staticTexts["Just Us"].waitForExistence(timeout: 10)
    }
    let label = name ?? screen
    addShot(app, screen: label, appearance: appearance, size: size, suffix: nil)
    if swipe {
      app.swipeUp()
      addShot(app, screen: label, appearance: appearance, size: size, suffix: "scrolled")
    }
    app.terminate()
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
