import SwiftUI

struct SetupScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      if model.spaceClosed {
        StatusBanner(message: L10n.spaceClosed, identifier: A11y.spaceClosed)
      }
      VStack(alignment: .leading, spacing: Theme.Space.stack) {
        RoleLine(waiting: false, text: L10n.yourTurn)
        Text(L10n.setupTitle).font(Theme.display)
        Text(L10n.setupBody)
        HelperText(text: L10n.setupNext)
      }
      VStack(alignment: .leading, spacing: Theme.Space.stack) {
        LabeledField(title: L10n.myName, text: $model.draft.selfName, identifier: A11y.selfName)
        LabeledField(title: L10n.theirName, text: $model.draft.partnerName, identifier: A11y.partnerName)
        HelperText(text: L10n.setupNamesHelp)
      }
      VStack(alignment: .leading, spacing: Theme.Space.stack) {
        Picker(L10n.ourDay, selection: $model.draft.weekday) {
          ForEach(0..<7, id: \.self) { day in
            Text(ZonedTime.weekdaySymbol(day)).tag(day)
          }
        }
        .accessibilityIdentifier(A11y.weekday)
        LabeledField(title: L10n.ourTime, text: $model.draft.localTime, identifier: A11y.timeField)
        LabeledField(title: L10n.timezone, text: $model.draft.timezone, identifier: A11y.zoneField)
        GlassCard {
          VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text(L10n.duration).font(Theme.caption)
            Stepper(value: $model.draft.durationMinutes, in: 30...360, step: 15) {
              Text(L10n.minutes(model.draft.durationMinutes))
                .font(Theme.title)
                .accessibilityIdentifier(A11y.durationValue)
            }
            .accessibilityValue(L10n.minutes(model.draft.durationMinutes))
            HelperText(text: L10n.durationHelp)
          }
        }
      }
      VStack(alignment: .leading, spacing: Theme.Space.stack) {
        WineButton(
          title: L10n.createSpace,
          identifier: A11y.createCouple,
          busy: model.activity == .create,
          busyTitle: L10n.settingUp
        ) { Task { await model.createCouple() } }
        Button(L10n.joinInstead) { model.screen = .invite }
          .accessibilityIdentifier(A11y.joinInstead)
          .frame(minHeight: 44)
          .disabled(model.busy)
      }
    }
  }
}

struct InviteShareScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      InviteBackButton { model.leaveInvite() }
      RoleLine(waiting: false, text: L10n.yourTurn)
      Text(L10n.inviteTitle).font(Theme.display)
      Text(L10n.inviteBody)
      HelperText(text: L10n.inviteShareNext)
      if let url = inviteURL {
        ShareLink(item: url) { Text(L10n.shareInvite) }
          .accessibilityIdentifier(A11y.shareInvite)
          .frame(minHeight: 44)
      }
      if let token = model.inviteToken {
        Text(token).font(.body.monospaced()).textSelection(.enabled)
      }
      WineButton(title: L10n.continueOn, identifier: A11y.continueInvite) { model.finishInvite(askPush: true) }
      Button(L10n.skipInvite) { model.finishInvite(askPush: true) }
        .accessibilityIdentifier(A11y.skipInvite)
        .frame(minHeight: 44)
    }
  }

  private var inviteURL: URL? {
    guard let token = model.inviteToken else { return nil }
    return URL(string: AppConfig.webURL + "/invite/" + token)
  }
}

struct SoftPromptScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      RoleLine(waiting: false, text: L10n.yourTurn)
      Text(L10n.softPromptTitle).font(Theme.display)
      Text(L10n.softPromptBody)
      HelperText(text: L10n.softNext)
      WineButton(title: L10n.softYes, identifier: A11y.softYes) { Task { await model.answerSoftPrompt(yes: true) } }
      Button(L10n.softNo) { Task { await model.answerSoftPrompt(yes: false) } }
        .accessibilityIdentifier(A11y.softNo)
        .frame(minHeight: 44)
    }
  }
}

struct InviteRedeemScreen: View {
  @Bindable var model: SessionModel
  @Environment(\.keyboardOverlap) private var keyboardOverlap

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      InviteBackButton { model.leaveInvite() }
      RoleLine(waiting: !model.signedIn, text: model.signedIn ? L10n.yourTurn : L10n.waitingOnThem)
      Text(L10n.inviteTitle).font(Theme.display)
      Text(bodyCopy)
      if model.signedIn {
        HelperText(text: L10n.joinNext)
        LabeledField(title: L10n.pasteCode, text: $model.inviteInput, identifier: A11y.inviteToken)
      }
      if model.signedIn && model.pendingReplace && keyboardOverlap == 0 {
        WineButton(title: L10n.replaceJoin, identifier: A11y.replaceEmpty, busy: model.activity == .redeem, busyTitle: L10n.loading) {
          Task { await model.redeem(replaceEmpty: true) }
        }
        Button(L10n.stay) { model.pendingReplace = false }
          .accessibilityIdentifier(A11y.stay)
          .frame(minHeight: 44)
      } else if model.signedIn && !model.blocked && !model.pendingReplace {
        WineButton(title: L10n.join, identifier: A11y.redeem, busy: model.activity == .redeem, busyTitle: L10n.loading) {
          Task { await model.redeem(replaceEmpty: false) }
        }
      }
    }
  }

  private var bodyCopy: String {
    if !model.signedIn { return L10n.signInFirst }
    if model.pendingReplace { return L10n.replaceBody }
    if model.blocked { return L10n.keptBody }
    return L10n.joinBody
  }
}

struct InviteBackButton: View {
  @Environment(\.colorScheme) private var scheme
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.backward")
          .accessibilityHidden(true)
        Text(L10n.back)
      }
      .font(Theme.body.weight(.semibold))
      .foregroundStyle(Theme.ink(scheme))
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
    .accessibilityIdentifier(A11y.inviteBack)
  }
}
