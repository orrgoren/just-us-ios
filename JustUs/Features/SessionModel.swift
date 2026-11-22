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

  enum Activity: Equatable {
    case generic, sendCode, verify, apple, create, redeem, saveDate, saveHint, reveal, finish, moment, settings, sendChat
  }

  enum Celebration: Equatable {
    case spaceReady, paired, nightSet
  }

  enum RetryKind: Equatable {
    case sendCode, verify, create, redeem(Bool), saveDate, saveHint, reveal, finish, moment, settings, openWeek, surprise, signOut, chat
  }

  var screen: Screen = .loading
  var tab: AppTab = .week
  var chatPresented = false
  var email = ""
  var code = ""
  var draft = CoupleDraft(selfName: "", partnerName: "", weekday: 4, localTime: "20:30", timezone: TimeZone.current.identifier, durationMinutes: 90)
  var ritual: RitualSnapshot?
  var memories: [MemoryItem] = []
  var settings: SettingsSnapshot?
  var inviteToken: String?
  var inviteInput = "" {
    didSet { rememberInviteDraft() }
  }
  var errorMessage: String?
  var offline = false
  var busy = false
  var activity: Activity?
  var celebration: Celebration?
  var retryKind: RetryKind?
  /// Set when a magic link is expired or already used, so login offers a new link instead of a dead end.
  var offerNewLink = false
  /// The partner's next launch, after the other person closed the shared space.
  var spaceClosed = false
  var pushDenied = false
  var showDelete = false
  var deleteConfirm = ""
  var confirmUnlink = false
  var signedIn = false
  private var authAccount: String?
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
  var chatDraft = ""
  var chatBanner: String?
  var stagedChatJPEG: Data?
  var chatRetention: ChatRetention = .viewOnce
  var openChatPhoto: UUID?
  var messages: [ChatLine] = []
  var sealedOpens: Set<UUID> = []
  var pendingConsumes: Set<UUID> = []
  var pendingPhotos: [UUID: PendingPhoto] = [:]
  var photoSending = false
  var lastShot: (UUID, Date)?
  var chatKeyNotice: String?
  var focusReveal = false

  var coupleIsLinked: Bool {
    ritual?.partner != nil || settings?.partnerJoined == true
  }

  var chatUnread: Int {
    guard chatPresented == false, let userId = ritual?.selfMember.userId else { return 0 }
    return ChatUnread.count(messages, seenThrough: ChatSeen.through(userId))
  }
  let backend: any DateBackend
  let pendingAppleNonce = AppleNonceBox()
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
    backend.onChatInsert = { [weak self] row in
      Task { await self?.appendIncoming(row) }
    }
    backend.onChatOpened = { [weak self] id in
      self?.sealOpen(id)
    }
    backend.onChatReload = { [weak self] in
      Task { await self?.loadMessages() }
    }
    NotificationCenter.default.addObserver(
      forName: .justUsForegroundChat, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.noteForegroundChat() }
    }
    if let name = Launch.screenshot {
      await applyScreenshot(name)
      return
    }
    PushRouter.shared.handler = { [weak self] route in
      Task { await self?.follow(route) }
    }
    await restoreOrLogin()
    if signedIn {
      await backend.retryClosedPhotos()
      await backend.syncLanguage(AppLanguage.shared.code)
    }
    await refreshPushRegistration(promptIfNeeded: true)
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
    await work(activity: .sendCode, retry: .sendCode) {
      try await self.backend.sendCode(email: self.email)
      self.rememberEmail()
      self.offerNewLink = false
      self.screen = .code
      self.errorMessage = nil
    }
  }

  func verify() async {
    await work(activity: .verify, retry: .verify) {
      let user = try await self.backend.verify(email: self.email, code: self.code)
      if let email = user.email, !email.isEmpty { self.email = email }
      self.rememberEmail()
      await self.finishEmailSignIn(userId: user.id)
    }
  }

  func completeEmailLink(_ url: URL) async {
    await work(retry: .sendCode) {
      let user = try await self.backend.session(from: url)
      if let email = user.email, !email.isEmpty { self.email = email }
      self.rememberEmail()
      await self.finishEmailSignIn(userId: user.id)
    }
  }

  func completeApple(token: String, nonce: String) async {
    await work(activity: .apple) {
      let user = try await self.backend.signInWithApple(idToken: token, nonce: nonce)
      if let email = user.email, !email.isEmpty { self.email = email }
      await self.finishSignIn(method: "apple", userId: user.id)
    }
  }

  func signInWithApple() async {
    let result: (token: String, nonce: String)
    do {
      result = try await apple.start()
    } catch {
      reportApple(error)
      return
    }
    await work {
      let user = try await self.backend.signInWithApple(idToken: result.token, nonce: result.nonce)
      if let email = user.email, !email.isEmpty { self.email = email }
      await self.finishSignIn(method: "apple", userId: user.id)
    }
  }

  func reportApple(_ error: Error) {
    guard !AppleSignInFailure.isCancellation(error) else { return }
    AppleSignInFailure.log(error)
    errorMessage = AppleSignInFailure.message(for: error)
  }

  func createCouple() async {
    await work(activity: .create, retry: .create) {
      try await self.backend.createCouple(self.draft)
      self.clearRememberedClosure()
      self.inviteToken = try await self.backend.createInvite()
      Telemetry.analytics.record(.inviteSent)
      self.dropPendingInvite()
      await self.refresh()
      self.screen = .inviteShare
      self.celebrate(.spaceReady)
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
    await work(activity: .redeem, retry: .redeem(replaceEmpty)) {
      guard let token = InviteRules.token(from: self.inviteInput) else {
        self.clearPendingInvite()
        throw AppError.invalidInvite
      }
      do {
        try await self.backend.redeem(token: token, replaceEmpty: replaceEmpty)
      } catch let error as AppError where error == .alreadyInCouple && !replaceEmpty {
        let kind = try await self.backend.membership()
        if InviteRules.landing(token: token, eligibility: kind).replaceEmpty {
          self.pendingReplace = true
          self.blocked = false
          return
        }
        self.clearPendingInvite()
        throw error
      } catch let error as AppError where error == .soloNotEmpty {
        self.blocked = true
        self.pendingReplace = false
        self.clearPendingInvite()
        throw error
      } catch {
        if let appError = error as? AppError, InviteOutcome.rejects(appError) {
          self.clearPendingInvite()
        }
        throw error
      }
      Telemetry.analytics.record(.inviteRedeemed)
      self.pendingReplace = false
      self.blocked = false
      self.clearPendingInvite()
      self.clearRememberedClosure()
      self.signedIn = true
      await self.refresh()
      self.screen = JoinLanding.screen()
      self.celebrate(.paired)
    }
  }

  func retryLast() async {
    guard let retryKind else { return }
    switch retryKind {
    case .sendCode: await sendCode()
    case .verify: await verify()
    case .create: await createCouple()
    case .redeem(let replace): await redeem(replaceEmpty: replace)
    case .saveDate: await saveDate()
    case .saveHint: await saveHint()
    case .reveal: await revealPlan()
    case .finish: await finishNight()
    case .moment: await saveMoment()
    case .settings: await saveSettings()
    case .openWeek: await openNextWeek()
    case .surprise: await surprise()
    case .signOut: await signOut()
    case .chat: await retryChat()
    }
  }

  func celebrate(_ kind: Celebration) {
    celebration = kind
    Haptics.success()
  }

  func leaveInvite() {
    dropPendingInvite()
    if signedIn {
      screen = ritual == nil ? .setup : .main
    } else {
      screen = .login
    }
  }

  func declineInvite() {
    pendingReplace = false
    clearPendingInvite()
  }

  func presentInvite(_ raw: String) {
    inviteInput = InviteRules.token(from: raw) ?? raw
    screen = .invite
  }

  func open(_ url: URL) async {
    if Launch.isUITest, url.host == "uitest" {
      await uitest(url)
      return
    }
    if AuthCallback.isCallback(url) {
      await completeEmailLink(url)
      return
    }
    guard let route = DeepLinks.route(from: url) else { return }
    if case .invite(let token) = route {
      presentInvite(token)
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

  func syncLanguage() async {
    guard signedIn else { return }
    await backend.syncLanguage(AppLanguage.shared.code)
  }

  func signOut() async {
    if !outbox.isEmpty {
      errorMessage = L10n.message(for: .unsyncedChanges)
      return
    }
    rememberEmail()
    do {
      try await backend.signOut()
    } catch {
      await applyFailure(error, retry: .signOut)
      return
    }
    clearSession()
    email = ""
    offerNewLink = false
    screen = .login
    Telemetry.analytics.record(.signedOut)
  }

  func clearSession() {
    code = ""
    draft = CoupleDraft(selfName: "", partnerName: "", weekday: 4, localTime: "20:30", timezone: TimeZone.current.identifier, durationMinutes: 90)
    ritual = nil
    memories = []
    settings = nil
    inviteToken = nil
    inviteInput = ""
    PendingInviteStore.clear()
    authAccount = nil
    teaser = ""
    outfit = ""
    privateNotes = ""
    planDay = ""
    planTime = ""
    noteDraft = ""
    momentDraft = ""
    chatDraft = ""
    messages = []
    chatKeyNotice = nil
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
    chatPresented = false
    chatBanner = nil
    signedIn = false
    offerNewLink = false
    spaceClosed = false
    tab = .week
  }

  func rememberEmail() {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    UserDefaults.standard.set(trimmed, forKey: Self.lastEmailKey)
  }

  func prefillEmail() {
    guard !Launch.isUITest else { return }
    guard email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard let saved = UserDefaults.standard.string(forKey: Self.lastEmailKey), !saved.isEmpty else { return }
    email = saved
  }

  /// Drops the live session and any pending magic-link verifier, then returns to a login that can send a new link.
  func recoverToLogin() async {
    rememberEmail()
    let typed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    await backend.dropExpiredSession()
    clearSession()
    email = typed.isEmpty ? rememberedEmail() : typed
    offerNewLink = true
    signedIn = false
    screen = .login
  }

  private func rememberedEmail() -> String {
    UserDefaults.standard.string(forKey: Self.lastEmailKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func applyFailure(_ error: Error, retry: RetryKind?) async {
    let appError = ErrorMap.app(error)
    if appError == .offline { offline = true }
    if appError == .sessionExpired || appError == .linkExpired {
      await recoverToLogin()
      errorMessage = L10n.message(for: appError)
      retryKind = .sendCode
    } else {
      errorMessage = L10n.message(for: appError)
      retryKind = retry
    }
    Telemetry.crashes.record(appError)
  }

  private static let lastEmailKey = "justus.lastEmail"

  static func closedSpaceKey(_ email: String) -> String {
    "justus.spaceClosed.\(email.lowercased())"
  }

  func rememberSpaceClosed() {
    spaceClosed = true
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    UserDefaults.standard.set(true, forKey: Self.closedSpaceKey(trimmed))
  }

  func clearRememberedClosure() {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      UserDefaults.standard.removeObject(forKey: Self.closedSpaceKey(trimmed))
    }
    spaceClosed = false
  }

  private func restoreOrLogin() async {
    if let user = try? await backend.restore() {
      if email.isEmpty, let restored = user.email, !restored.isEmpty { email = restored }
      rememberEmail()
      syncAccount(user.id.uuidString)
      signedIn = true
      let deciding = screen == .loading || screen == .login || screen == .code
      await refresh()
      if deciding {
        routeColdLaunch()
      }
    } else if !signedIn && screen == .loading {
      prefillEmail()
      screen = .login
    }
  }

  private func finishEmailSignIn(userId: UUID) async {
    offerNewLink = false
    await finishSignIn(method: "otp", userId: userId)
  }

  private func finishSignIn(method: String, userId: UUID) async {
    syncAccount(userId.uuidString)
    Telemetry.analytics.record(.signedIn(method: method))
    signedIn = true
    await refresh()
    routeAfterSignIn()
    await refreshPushRegistration(promptIfNeeded: false)
  }

  /// Sign-in can open join once. A cold launch never does, and a full couple goes home.
  private func routeAfterSignIn() {
    if paired {
      dropPendingInvite()
      screen = .main
      return
    }
    if let token = PendingInviteStore.current() {
      inviteInput = token
      screen = .invite
      return
    }
    screen = ritual == nil ? .setup : .main
  }

  private func routeColdLaunch() {
    if paired {
      dropPendingInvite()
      screen = .main
      return
    }
    screen = ritual == nil ? .setup : .main
  }

  private var paired: Bool { ritual?.partner != nil }

  private func syncAccount(_ raw: String?) {
    let next = Self.accountKey(raw)
    let switched = authAccount != nil && next != nil && authAccount != next
    if switched || (next != nil && !PendingInviteStore.belongs(to: next)) {
      dropPendingInvite()
    }
    if let next { authAccount = next }
  }

  private static func accountKey(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func dropPendingInvite() {
    inviteInput = ""
    PendingInviteStore.clear()
  }

  private func rememberInviteDraft() {
    if let token = InviteRules.token(from: inviteInput) {
      PendingInviteStore.save(token, account: authAccount)
      return
    }
    PendingInviteStore.clear()
  }

  private func clearPendingInvite() {
    PendingInviteStore.clear()
  }

  private func work(activity: Activity = .generic, retry: RetryKind? = nil, _ body: () async throws -> Void) async {
    self.activity = activity
    busy = true
    defer {
      busy = false
      self.activity = nil
    }
    do {
      try await body()
      errorMessage = nil
      retryKind = nil
    } catch {
      await applyFailure(error, retry: retry)
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

  private func refreshPushRegistration(promptIfNeeded: Bool) async {
    guard !Launch.isUITest, signedIn else { return }
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    let asked = UserDefaults.standard.bool(forKey: "justus.push.asked")
    let decision = PushRegistration.action(
      status: settings.authorizationStatus,
      pushEnabled: AppConfig.pushEnabled,
      alreadyAsked: asked
    )
    switch decision {
    case .register:
      UIApplication.shared.registerForRemoteNotifications()
    case .offerPrompt:
      if promptIfNeeded, screen == .main {
        screen = .softPrompt
      }
    case .none:
      break
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
    case .chat:
      presentChat()
    case .invite(let token):
      presentInvite(token)
    }
    if screen == .loading { screen = .main }
  }
}

enum Pending: Equatable {
  case mood(MoodKey)
  case note(dateId: UUID, noteId: UUID?, text: String)
}
