import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class SessionModel {
  enum Screen: Equatable {
    case loading, login, code, setup, inviteShare, softPrompt, invite, main
  }

  var screen: Screen = .loading
  var tab: AppTab = .week
  var email = ""
  var code = ""
  var draft = CoupleDraft(selfName: "", partnerName: "", weekday: 4, localTime: "20:30", timezone: TimeZone.current.identifier, durationMinutes: 90)
  var ritual: RitualSnapshot?
  var memories: [MemoryItem] = []
  var settings: SettingsSnapshot?
  var inviteToken: String?
  var inviteInput = ""
  var errorMessage: String?
  var offline = false
  var busy = false
  var pushDenied = false
  var showDelete = false
  var deleteConfirm = ""
  var confirmUnlink = false
  var signedIn = false
  var pendingReplace = false
  var blocked = false
  var noteDraft = ""
  var editingNote: UUID?
  var editingDate: UUID?
  var teaser = ""
  var outfit = ""
  var privateNotes = ""
  var planDay = ""
  var planTime = ""
  var momentDraft = ""
  var focusReveal = false
  let backend: any DateBackend
  private let apple = AppleSignInCoordinator()
  var outbox: [String: Pending] = [:]

  init(backend: (any DateBackend)? = nil) {
    if let backend {
      self.backend = backend
    } else if Launch.useFake {
      self.backend = FakeBackend()
    } else {
      self.backend = LiveBackend()
    }
  }

  func start() async {
    Telemetry.analytics.record(.appOpened)
    backend.onRemoteChange = { [weak self] in
      Task { await self?.refresh() }
    }
    if let name = Launch.screenshot {
      await applyScreenshot(name)
      return
    }
    PushRouter.shared.handler = { [weak self] route in
      Task { await self?.follow(route) }
    }
    await restoreOrLogin()
    await refreshPushRegistration()
    if let raw = Launch.argument(after: "-JustUsURL"), let url = URL(string: raw) {
      await open(url)
    }
    if let type = Launch.argument(after: "-JustUsPush") {
      let payload = ["type": type]
      PushRouter.shared.route(payload, id: "launch-\(type)")
      await follow(DeepLinks.route(userInfo: payload))
    }
  }

  func sendCode() async {
    await work {
      try await self.backend.sendCode(email: self.email)
      self.screen = .code
      self.errorMessage = nil
    }
  }

  func verify() async {
    await work {
      _ = try await self.backend.verify(email: self.email, code: self.code)
      Telemetry.analytics.record(.signedIn(method: "otp"))
      self.signedIn = true
      await self.refresh()
      self.screen = self.ritual == nil ? .setup : .main
    }
  }

  func completeApple(token: String, nonce: String) async {
    await work {
      _ = try await self.backend.signInWithApple(idToken: token, nonce: nonce)
      Telemetry.analytics.record(.signedIn(method: "apple"))
      self.signedIn = true
      await self.refresh()
      self.screen = self.ritual == nil ? .setup : .main
    }
  }

  func signInWithApple() async {
    await work {
      let result = try await self.apple.start()
      _ = try await self.backend.signInWithApple(idToken: result.token, nonce: result.nonce)
      Telemetry.analytics.record(.signedIn(method: "apple"))
      self.signedIn = true
      await self.refresh()
      self.screen = self.ritual == nil ? .setup : .main
    }
  }

  func createCouple() async {
    await work {
      try await self.backend.createCouple(self.draft)
      self.inviteToken = try await self.backend.createInvite()
      Telemetry.analytics.record(.inviteSent)
      await self.refresh()
      self.screen = .inviteShare
    }
  }

  func finishInvite(askPush: Bool) {
    screen = askPush ? .softPrompt : .main
  }

  func answerSoftPrompt(yes: Bool) async {
    if yes {
      await requestPush()
    }
    screen = .main
  }

  func redeem(replaceEmpty: Bool) async {
    await work {
      guard let token = InviteRules.token(from: self.inviteInput) else { throw AppError.invalidInvite }
      do {
        try await self.backend.redeem(token: token, replaceEmpty: replaceEmpty)
      } catch let error as AppError where error == .alreadyInCouple && !replaceEmpty {
        let kind = try await self.backend.membership()
        if InviteRules.landing(token: token, eligibility: kind).replaceEmpty {
          self.pendingReplace = true
          self.blocked = false
          return
        }
        throw error
      } catch let error as AppError where error == .soloNotEmpty {
        self.blocked = true
        self.pendingReplace = false
        throw error
      }
      Telemetry.analytics.record(.inviteRedeemed)
      self.pendingReplace = false
      self.blocked = false
      self.signedIn = true
      await self.refresh()
      self.screen = Launch.isUITest ? .main : .softPrompt
    }
  }

  func leaveInvite() {
    if signedIn {
      screen = ritual == nil ? .setup : .main
    } else {
      screen = .login
    }
  }

  func open(_ url: URL) async {
    if Launch.isUITest, url.host == "uitest" {
      await uitest(url)
      return
    }
    guard let route = DeepLinks.route(from: url) else { return }
    if case .invite(let token) = route {
      inviteInput = token
      screen = .invite
      return
    }
    await follow(route)
  }

  func retry() async {
    offline = false
    backend.setOffline(false)
    await flush()
    await refresh()
  }

  func discardAndSignOut() async {
    outbox = [:]
    await signOut()
  }

  func signOut() async {
    if !outbox.isEmpty {
      errorMessage = L10n.message(for: .unsyncedChanges)
      return
    }
    await backend.signOut()
    clearSession()
    screen = .login
    Telemetry.analytics.record(.signedOut)
  }

  func clearSession() {
    email = ""
    code = ""
    draft = CoupleDraft(selfName: "", partnerName: "", weekday: 4, localTime: "20:30", timezone: TimeZone.current.identifier, durationMinutes: 90)
    ritual = nil
    memories = []
    settings = nil
    inviteToken = nil
    inviteInput = ""
    teaser = ""
    outfit = ""
    privateNotes = ""
    planDay = ""
    planTime = ""
    noteDraft = ""
    momentDraft = ""
    deleteConfirm = ""
    editingNote = nil
    editingDate = nil
    outbox = [:]
    errorMessage = nil
    showDelete = false
    confirmUnlink = false
    pendingReplace = false
    blocked = false
    focusReveal = false
    signedIn = false
    tab = .week
  }

  private func restoreOrLogin() async {
    if let _ = try? await backend.restore() {
      signedIn = true
      await refresh()
      screen = ritual == nil ? .setup : .main
    } else {
      signedIn = false
      screen = .login
    }
  }

  private func work(_ body: () async throws -> Void) async {
    busy = true
    defer { busy = false }
    do {
      try await body()
      errorMessage = nil
    } catch {
      let appError = ErrorMap.app(error)
      if appError == .offline { offline = true }
      if appError == .sessionExpired { screen = .login }
      errorMessage = L10n.message(for: appError)
      Telemetry.crashes.record(appError)
    }
  }

  private func requestPush() async {
    UserDefaults.standard.set(true, forKey: "justus.push.asked")
    guard !Launch.isUITest else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .denied {
      pushDenied = true
      return
    }
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
      pushDenied = !granted
      if granted, AppConfig.pushEnabled {
        UIApplication.shared.registerForRemoteNotifications()
      }
    } catch {
      pushDenied = true
    }
  }

  private func refreshPushRegistration() async {
    guard !Launch.isUITest, signedIn else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .authorized, AppConfig.pushEnabled {
      UIApplication.shared.registerForRemoteNotifications()
      return
    }
    if settings.authorizationStatus == .notDetermined, !UserDefaults.standard.bool(forKey: "justus.push.asked"), screen == .main {
      screen = .softPrompt
    }
  }

  private func uitest(_ url: URL) async {
    switch url.lastPathComponent {
    case "offline":
      backend.setOffline(true)
      offline = true
    case "online":
      backend.setOffline(false)
      offline = false
      await flush()
    case "partner-mood":
      await backend.injectPartnerMood()
      await refresh()
    case "reveal":
      focusReveal = true
      tab = .week
    default:
      break
    }
  }

  private func follow(_ route: AppRoute) async {
    switch route {
    case .home:
      tab = .week
      focusReveal = false
    case .reveal:
      tab = .week
      focusReveal = true
    case .memories:
      tab = .memories
    case .settings:
      tab = .settings
    case .invite(let token):
      inviteInput = token
      screen = .invite
    }
    if screen == .loading { screen = .main }
  }
}

enum Pending: Equatable {
  case mood(MoodKey)
  case note(dateId: UUID, noteId: UUID?, text: String)
}
