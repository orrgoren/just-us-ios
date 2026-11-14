import AuthenticationServices
import SwiftUI

struct RootView: View {
  @Bindable var model: SessionModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    JustScreen {
      ScrollView {
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
      }
      .accessibilityIdentifier(A11y.content)
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
      Button(L10n.haveInvite) { model.screen = .invite }
        .accessibilityIdentifier(A11y.haveInvite)
        .frame(minHeight: 44)
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
      Button(L10n.resend) { Task { await model.sendCode() } }
        .accessibilityIdentifier(A11y.resend)
        .frame(minHeight: 44)
      Button(L10n.useAnotherEmail) { model.screen = .login }
        .frame(minHeight: 44)
    }
  }
}

enum FieldNeed {
  case required, optional
}

struct LabeledField: View {
  @Environment(\.colorScheme) private var scheme
  var title: String
  @Binding var text: String
  var identifier: String
  var need: FieldNeed = .required

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.field) {
      HStack(spacing: 8) {
        Text(title).font(Theme.caption)
        Text(need == .required ? L10n.required : L10n.optional)
          .font(Theme.caption)
          .foregroundStyle(Theme.muted(scheme))
      }
      TextField(title, text: $text)
        .textFieldStyle(.plain)
        .foregroundStyle(Theme.ink)
        .padding(12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier(identifier)
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
