import SwiftUI

@main
struct JustUsApp: App {
  @UIApplicationDelegateAdaptor(JustUsDelegate.self) private var delegate

  init() {
    Launch.prepare()
  }

  var body: some Scene {
    WindowGroup {
      AppRoot()
    }
  }
}

struct AppRoot: View {
  @State private var model = SessionModel()

  var body: some View {
    RootView(model: model)
      .task { await model.start() }
      .onReceive(NotificationCenter.default.publisher(for: .justUsDeviceToken)) { note in
        guard let token = note.object as? String else { return }
        Task { await model.backend.registerDevice(token: token) }
      }
  }
}
