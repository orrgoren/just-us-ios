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
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = SessionModel()

  var body: some View {
    RootView(model: model)
      .task { await model.start() }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        Task { await model.becameActive() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .justUsDeviceToken)) { note in
        guard let token = note.object as? String else { return }
        Task { await model.backend.registerDevice(token: token) }
      }
  }
}
