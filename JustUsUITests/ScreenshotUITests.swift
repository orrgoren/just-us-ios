import XCTest

final class ScreenshotUITests: XCTestCase {
  func testNamedScreens() {
    let screens = [
      "login", "code", "setup", "inviteShare", "softPrompt", "inviteRedeem",
      "inviteReplace", "inviteBlocked", "homeSolo", "homePlanner", "homePartner",
      "reveal", "memories", "memoriesEmpty", "settings", "deleteAccount", "offline"
    ]
    for screen in screens {
      capture(screen: screen, appearance: "light", size: nil)
      capture(screen: screen, appearance: "dark", size: nil)
    }
    for screen in ["login", "homePlanner", "settings"] {
      capture(screen: screen, appearance: "light", size: "UICTContentSizeCategoryXS")
      capture(screen: screen, appearance: "light", size: "UICTContentSizeCategoryAccessibilityXXXL")
    }
  }

  private func capture(screen: String, appearance: String, size: String?) {
    let app = XCUIApplication()
    var arguments = ["-uitest", "-JustUsScreen", screen, "-JustUsAppearance", appearance]
    if let size {
      arguments += ["-UIPreferredContentSizeCategoryName", size]
    }
    app.launchArguments = arguments
    app.launch()
    if screen == "login" {
      _ = app.textFields["emailField"].waitForExistence(timeout: 10)
    } else {
      _ = app.staticTexts["Just Us"].waitForExistence(timeout: 10)
    }
    let shot = XCTAttachment(screenshot: app.screenshot())
    let prefix = ProcessInfo.processInfo.environment["SCREENSHOT_PREFIX"] ?? "device"
    let sizeName = size == nil ? "default" : (size?.contains("Accessibility") == true ? "ax" : "xs")
    shot.name = "\(prefix)-\(screen)-\(appearance)-\(sizeName)"
    shot.lifetime = .keepAlways
    add(shot)
    app.terminate()
  }
}
