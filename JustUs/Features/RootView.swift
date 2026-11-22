import AuthenticationServices
import SwiftUI
import UIKit

struct RootView: View {
  @Bindable var model: SessionModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var keyboardDismiss = 0
  @State private var keyboardOverlap: CGFloat = 0

  private var pinReplace: Bool {
    keyboardOverlap > 0 && model.screen == .invite && model.pendingReplace
  }

  private var showChatBubble: Bool {
    model.screen == .main && model.chatPresented == false && model.coupleIsLinked
  }

  var body: some View {
    JustScreen {
      ScrollViewReader { proxy in
      VStack(spacing: 0) {
        ScrollView { page }
          .scrollDismissesKeyboard(.immediately)
          .accessibilityIdentifier(A11y.content)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if showChatBubble {
          HStack {
            Spacer(minLength: 0)
            ChatBubble(unread: model.chatUnread) { model.presentChat() }
          }
          .padding(.horizontal, 20)
          .padding(.top, 4)
          .padding(.bottom, 8)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea(.keyboard, edges: .bottom)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if pinReplace {
          PinnedReplaceActions(model: model)
            .padding(.bottom, keyboardOverlap)
        }
      }
      .toolbar {
        // The chat sheet has its own Done. Two of them would both match the same identifier.
        if model.chatPresented == false {
          ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            ActionButton(title: L10n.dismissKeyboard, identifier: A11y.dismissKeyboard, kind: .link) {
              keyboardDismiss += 1
            }
          }
        }
      }
      .environment(\.scrollFieldIntoView) { id in
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.16))
        }
      }
      .onChange(of: model.screen) { _, newScreen in
        guard newScreen == .main else { return }
        Task { @MainActor in
          proxy.scrollTo("screenTop", anchor: .top)
        }
      }
      .environment(\.keyboardDismiss, keyboardDismiss)
      .environment(\.keyboardOverlap, keyboardOverlap)
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
        let next = KeyboardOverlap.height(from: note)
        guard abs(next - keyboardOverlap) > 1 else { return }
        keyboardOverlap = next
      }
      }
    }
    .environment(\.keyboardDismiss, keyboardDismiss)
    .sheet(isPresented: $model.chatPresented) {
      ChatSheet(model: model)
        .inAppLocale()
    }
    .preferredColorScheme(Launch.preferredScheme)
    .onOpenURL { url in Task { await model.open(url) } }
    .onChange(of: model.celebration) { _, value in
      guard value != nil else { return }
      Task {
        try? await Task.sleep(for: .seconds(2.6))
        if model.celebration == value { model.celebration = nil }
      }
    }
  }

  private var page: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      Wordmark()
      if let celebration = model.celebration {
        CelebrationBanner(kind: celebration)
      }
      if model.offline {
        StatusBanner(message: L10n.offline, identifier: A11y.offline)
        WineButton(title: L10n.retry, identifier: A11y.retry, busy: model.activity == .generic && model.busy) {
          Task { await model.retry() }
        }
      }
      if let message = model.errorMessage {
        StatusBanner(message: message, identifier: A11y.errorBanner)
        if model.retryKind != nil {
          WineButton(title: L10n.retry, identifier: A11y.actionRetry, busy: model.busy) {
            Task { await model.retryLast() }
          }
        }
        if model.outbox.isEmpty == false {
          WineButton(title: L10n.discard, identifier: A11y.discard) { Task { await model.discardAndSignOut() } }
        }
      }
      if model.pushDenied {
        StatusBanner(message: L10n.pushDenied, identifier: A11y.softNo)
      }
      content
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: model.screen)
    }
    .padding(Theme.Space.screen)
    .padding(.bottom, pinReplace ? 0 : keyboardOverlap)
    .id("screenTop")
  }

  @ViewBuilder private var content: some View {
    switch model.screen {
    case .loading:
      VStack(spacing: 12) {
        ProgressView()
        Text(L10n.loading)
      }
      .frame(maxWidth: .infinity, minHeight: 240)
    case .login:
      LoginScreen(model: model)
    case .code:
      CodeScreen(model: model)
    case .setup:
      SetupScreen(model: model)
    case .inviteShare:
      InviteShareScreen(model: model)
    case .softPrompt:
      SoftPromptScreen(model: model)
    case .invite:
      InviteRedeemScreen(model: model)
    case .main:
      MainScreen(model: model)
    }
  }
}

struct LoginScreen: View {
  @Bindable var model: SessionModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      Text(L10n.loginTitle).font(Theme.display).accessibilityIdentifier(A11y.loginRoot)
      Text(L10n.loginBody).font(Theme.body)
      HelperText(text: L10n.loginNext)
      LabeledField(title: L10n.emailLabel, text: $model.email, identifier: A11y.emailField)
        .textInputAutocapitalization(.never)
        .keyboardType(.emailAddress)
      WineButton(
        title: model.offerNewLink ? L10n.newLink : L10n.sendCode,
        identifier: A11y.sendCode,
        busy: model.activity == .sendCode,
        busyTitle: L10n.loading
      ) {
        Task { await model.sendCode() }
      }
      SignInWithAppleButton(.signIn) { request in
        let raw = AppleNonce.raw()
        model.pendingAppleNonce.raw = raw
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleNonce.hashed(raw)
      } onCompletion: { result in
        switch result {
        case .failure(let error):
          model.reportApple(error)
        case .success(let authorization):
          guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8) else {
            model.reportApple(ASAuthorizationError(.invalidResponse))
            return
          }
          let nonce = model.pendingAppleNonce.raw
          Task { await model.completeApple(token: token, nonce: nonce) }
        }
      }
      .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
      .frame(height: 48)
      .accessibilityIdentifier(A11y.apple)
      ActionButton(title: L10n.haveInvite, identifier: A11y.haveInvite, kind: .link) {
        model.screen = .invite
      }
    }
  }
}

struct CodeScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      Text(L10n.codeTitle).font(Theme.display)
      Text(L10n.codeBody)
      HelperText(text: L10n.codeNext)
      LabeledField(title: L10n.codeLabel, text: $model.code, identifier: A11y.codeField, need: .optional)
        .keyboardType(.numberPad)
      WineButton(title: L10n.verify, identifier: A11y.verify, busy: model.activity == .verify, busyTitle: L10n.loading) {
        Task { await model.verify() }
      }
      ActionButton(title: L10n.resend, identifier: A11y.resend, kind: .link) {
        Task { await model.sendCode() }
      }
      ActionButton(title: L10n.useAnotherEmail, kind: .link) { model.screen = .login }
    }
  }
}

enum FieldNeed {
  case required, optional, labelOnly
}

private struct ScrollFieldKey: EnvironmentKey {
  static let defaultValue: (String) -> Void = { _ in }
}

private struct KeyboardDismissKey: EnvironmentKey {
  static let defaultValue = 0
}

private struct KeyboardOverlapKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var scrollFieldIntoView: (String) -> Void {
    get { self[ScrollFieldKey.self] }
    set { self[ScrollFieldKey.self] = newValue }
  }

  var keyboardDismiss: Int {
    get { self[KeyboardDismissKey.self] }
    set { self[KeyboardDismissKey.self] = newValue }
  }

  var keyboardOverlap: CGFloat {
    get { self[KeyboardOverlapKey.self] }
    set { self[KeyboardOverlapKey.self] = newValue }
  }
}

private struct PinnedReplaceActions: View {
  @Bindable var model: SessionModel
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.stack) {
      WineButton(title: L10n.replaceJoin, identifier: A11y.replaceEmpty, busy: model.activity == .redeem, busyTitle: L10n.loading) {
        Task { await model.redeem(replaceEmpty: true) }
      }
      ActionButton(title: L10n.stay, identifier: A11y.stay) { model.pendingReplace = false }
    }
    .padding(.horizontal, Theme.Space.screen)
    .padding(.vertical, 12)
    .background(Theme.canvas(scheme))
  }
}

private enum KeyboardOverlap {
  /// Height of the keyboard over the screen. The frame comes from the
  /// notification, not from a background view that SwiftUI may have
  /// already lifted clear of the keyboard.
  static func height(from note: Notification) -> CGFloat {
    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return 0 }
    let screen = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }?
      .screen.bounds
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds
      ?? .zero
    guard screen.height > 1, frame.minY < screen.maxY else { return 0 }
    return min(max(0, screen.maxY - frame.minY), screen.height)
  }
}

struct LabeledField: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.scrollFieldIntoView) private var scrollFieldIntoView
  @Environment(\.keyboardDismiss) private var keyboardDismiss
  @Environment(\.keyboardOverlap) private var keyboardOverlap
  @FocusState private var focused: Bool
  var title: String
  @Binding var text: String
  var identifier: String
  var need: FieldNeed = .required
  var focusToken: Int = 0
  var submit: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.field) {
      HStack(spacing: 8) {
        Text(title).font(Theme.caption)
        if need != .labelOnly {
          Text(need == .required ? L10n.required : L10n.optional)
            .font(Theme.caption)
            .foregroundStyle(Theme.muted(scheme))
        }
      }
      TextField(title, text: $text, prompt: Text(title).foregroundStyle(Theme.muted))
        .focused($focused)
        .submitLabel(submit == nil ? .done : .send)
        .onSubmit { submit?() }
        .textFieldStyle(.plain)
        .foregroundStyle(Theme.ink)
        .padding(12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier(identifier)
    }
    .id(identifier)
    .onChange(of: focused) { _, isOn in
      guard isOn else { return }
      reveal()
    }
    .onChange(of: keyboardOverlap) { _, overlap in
      guard focused, overlap > 0 else { return }
      reveal()
    }
    .onChange(of: keyboardDismiss) { _, _ in focused = false }
    .onChange(of: focusToken) { _, token in
      guard token > 0 else { return }
      focused = true
    }
  }

  private func reveal() {
    scrollFieldIntoView(identifier)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(350))
      guard focused else { return }
      scrollFieldIntoView(identifier)
    }
  }
}

struct CelebrationBanner: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var kind: SessionModel.Celebration

  var body: some View {
    HStack(spacing: 12) {
      heart
      Text(title).font(Theme.title)
    }
    .padding(Theme.Space.stack)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder private var heart: some View {
    let image = Image(systemName: "heart.fill")
      .foregroundStyle(Theme.wine)
      .accessibilityHidden(true)
    if reduceMotion {
      image
    } else {
      image.symbolEffect(.bounce, value: kind)
    }
  }

  private var title: String {
    switch kind {
    case .spaceReady: L10n.spaceReady
    case .paired: L10n.paired
    case .nightSet: L10n.nightSet
    }
  }
}
