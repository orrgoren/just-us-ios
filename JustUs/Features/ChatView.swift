import SwiftUI

struct ChatScreen: View {
  @Bindable var model: SessionModel
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.stack) {
      Text(L10n.chatTitle).font(Theme.title).accessibilityIdentifier(A11y.chatRoot)
      HelperText(text: L10n.chatHelp)
      if let notice = model.chatKeyNotice {
        Text(notice)
          .font(Theme.body)
          .foregroundStyle(Theme.ink(scheme))
          .accessibilityIdentifier(A11y.chatKeyNotice)
      }
      if model.ritual?.partner == nil {
        Text(L10n.chatWaiting)
      } else if model.messages.isEmpty {
        Text(L10n.chatEmpty)
      } else {
        ForEach(model.messages) { line in
          bubble(line)
        }
      }
      if model.ritual?.partner != nil {
        LabeledField(title: L10n.chatField, text: $model.chatDraft, identifier: A11y.chatField, need: .labelOnly)
        WineButton(
          title: L10n.chatSend, identifier: A11y.chatSend,
          busy: model.activity == .sendChat, busyTitle: L10n.loading
        ) {
          Task { await model.sendChat() }
        }
      }
    }
  }

  private func bubble(_ line: ChatLine) -> some View {
    HStack {
      if line.mine { Spacer(minLength: 48) }
      Text(line.text)
        .font(Theme.body)
        .foregroundStyle(foreground(mine: line.mine))
        .padding(12)
        .background(fill(mine: line.mine), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier(A11y.chatLine)
      if line.mine == false { Spacer(minLength: 48) }
    }
  }

  private func foreground(mine: Bool) -> Color {
    mine ? Theme.canvas : Theme.ink
  }

  private func fill(mine: Bool) -> Color {
    mine ? Theme.wine : Theme.blush
  }
}
