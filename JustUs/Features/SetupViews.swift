import SwiftUI

struct SetupScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.setupTitle).font(Theme.display)
      Text(L10n.setupBody)
      LabeledField(title: L10n.myName, text: $model.draft.selfName, identifier: A11y.selfName)
      LabeledField(title: L10n.theirName, text: $model.draft.partnerName, identifier: A11y.partnerName)
      Picker(L10n.ourDay, selection: $model.draft.weekday) {
        ForEach(0..<7, id: \.self) { day in
          Text(ZonedTime.weekdaySymbol(day)).tag(day)
        }
      }
      .accessibilityIdentifier(A11y.weekday)
      LabeledField(title: L10n.ourTime, text: $model.draft.localTime, identifier: A11y.timeField)
      LabeledField(title: L10n.timezone, text: $model.draft.timezone, identifier: A11y.zoneField)
      Stepper(value: $model.draft.durationMinutes, in: 30...360, step: 15) {
        Text(L10n.duration)
      }
      WineButton(title: L10n.createSpace, identifier: A11y.createCouple) { Task { await model.createCouple() } }
      Button(L10n.joinInstead) { model.screen = .invite }
        .accessibilityIdentifier(A11y.joinInstead)
        .frame(minHeight: 44)
    }
  }
}

struct InviteShareScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.inviteTitle).font(Theme.display)
      Text(L10n.inviteBody)
      if let url = inviteURL {
        ShareLink(item: url) { Text(L10n.shareInvite) }
          .accessibilityIdentifier(A11y.shareInvite)
          .frame(minHeight: 44)
      }
      if let token = model.inviteToken {
        Text(token).font(.body.monospaced()).textSelection(.enabled)
      }
      WineButton(title: L10n.continueOn, identifier: A11y.softYes) { model.finishInvite(askPush: true) }
      Button(L10n.skipInvite) { model.finishInvite(askPush: false) }
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
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.softPromptTitle).font(Theme.display)
      Text(L10n.softPromptBody)
      WineButton(title: L10n.softYes, identifier: A11y.softYes) { Task { await model.answerSoftPrompt(yes: true) } }
      Button(L10n.softNo) { Task { await model.answerSoftPrompt(yes: false) } }
        .accessibilityIdentifier(A11y.softNo)
        .frame(minHeight: 44)
    }
  }
}

struct InviteRedeemScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.inviteTitle).font(Theme.display)
      Text(bodyCopy)
      LabeledField(title: L10n.pasteCode, text: $model.inviteInput, identifier: A11y.inviteToken)
      if model.pendingReplace {
        WineButton(title: L10n.replaceJoin, identifier: A11y.replaceEmpty) {
          Task { await model.redeem(replaceEmpty: true) }
        }
        Button(L10n.stay) { model.pendingReplace = false }
          .accessibilityIdentifier(A11y.stay)
          .frame(minHeight: 44)
      } else if model.blocked {
        Text(L10n.keptBody)
      } else {
        WineButton(title: L10n.join, identifier: A11y.redeem) { Task { await model.redeem(replaceEmpty: false) } }
      }
    }
  }

  private var bodyCopy: String {
    if model.pendingReplace { return L10n.replaceBody }
    if model.blocked { return L10n.keptBody }
    return L10n.joinBody
  }
}
