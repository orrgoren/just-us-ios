import SwiftUI

struct RootView: View {
  @Bindable var model: SessionModel

  var body: some View {
    JustScreen {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
        Wordmark()
        if model.offline {
          StatusBanner(message: L10n.offline, identifier: A11y.offline)
          WineButton(title: L10n.retry, identifier: A11y.retry) { Task { await model.retry() } }
        }
        if let message = model.errorMessage {
          StatusBanner(message: message, identifier: A11y.errorBanner)
          if model.outbox.isEmpty == false {
            WineButton(title: L10n.discard, identifier: A11y.signOut) { Task { await model.discardAndSignOut() } }
          }
        }
        if model.pushDenied {
          StatusBanner(message: L10n.pushDenied, identifier: A11y.softNo)
        }
        content
        }
        .padding(24)
      }
      .accessibilityIdentifier(A11y.content)
    }
    .preferredColorScheme(Launch.preferredScheme)
    .onOpenURL { url in Task { await model.open(url) } }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.loginTitle).font(Theme.display).accessibilityIdentifier(A11y.loginRoot)
      Text(L10n.loginBody).font(Theme.body)
      LabeledField(title: L10n.emailLabel, text: $model.email, identifier: A11y.emailField)
        .textInputAutocapitalization(.never)
        .keyboardType(.emailAddress)
      WineButton(title: L10n.sendCode, identifier: A11y.sendCode) { Task { await model.sendCode() } }
      WineButton(title: L10n.apple, identifier: A11y.apple) { Task { await model.signInWithApple() } }
      Button(L10n.haveInvite) { model.screen = .invite }
        .accessibilityIdentifier(A11y.haveInvite)
        .frame(minHeight: 44)
    }
  }
}

struct CodeScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.codeTitle).font(Theme.display)
      Text(L10n.codeBody)
      LabeledField(title: L10n.codeLabel, text: $model.code, identifier: A11y.codeField)
        .keyboardType(.numberPad)
      WineButton(title: L10n.verify, identifier: A11y.verify) { Task { await model.verify() } }
      Button(L10n.resend) { Task { await model.sendCode() } }
        .accessibilityIdentifier(A11y.resend)
        .frame(minHeight: 44)
      Button(L10n.useAnotherEmail) { model.screen = .login }
        .frame(minHeight: 44)
    }
  }
}

struct LabeledField: View {
  var title: String
  @Binding var text: String
  var identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(Theme.caption)
      TextField(title, text: $text)
        .textFieldStyle(.plain)
        .padding(12)
        .background(Theme.blush.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier(identifier)
    }
  }
}
