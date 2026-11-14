import XCTest

enum UITestLaunch {
  static func make(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uitest"] + extra
    app.launch()
    record(app)
    return app
  }

  static func record(_ app: XCUIApplication) {
    XCTContext.runActivity(named: "Launch hierarchy") { activity in
      let tree = app.debugDescription
      print(tree)
      let hierarchy = XCTAttachment(string: tree)
      hierarchy.name = "launch-hierarchy"
      hierarchy.lifetime = .keepAlways
      activity.add(hierarchy)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "launch-screen"
      shot.lifetime = .keepAlways
      activity.add(shot)
    }
  }
}
