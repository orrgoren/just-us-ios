import PhotosUI
import SwiftUI
import UIKit

struct MainScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      Picker(L10n.tabWeek, selection: $model.tab) {
        Text(L10n.tabWeek).tag(AppTab.week)
        Text(L10n.tabMemories).tag(AppTab.memories)
        Text(L10n.tabUs).tag(AppTab.settings)
      }
      .pickerStyle(.segmented)
      if let banner = model.chatBanner, model.chatPresented == false {
        Button(banner) {
          model.presentChat()
        }
        .buttonStyle(JustButtonStyle(kind: .secondary))
        .accessibilityIdentifier(A11y.chatBanner)
      }
      if !coupleIsLinked {
        ActionButton(title: L10n.haveInvite, identifier: A11y.haveInvite, kind: .link) {
          model.screen = .invite
        }
      }
      switch model.tab {
      case .week:
        RitualScreen(model: model)
      case .chat:
        RitualScreen(model: model)
      case .memories:
        MemoriesScreen(model: model)
      case .settings:
        SettingsScreen(model: model)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear {
      guard model.tab == .chat else { return }
      model.tab = .week
      model.presentChat()
    }
  }

  private var coupleIsLinked: Bool {
    model.ritual?.partner != nil || model.settings?.partnerJoined == true
  }
}

struct ChatBubble: View {
  var unread: Int
  var action: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: action) {
        Image(systemName: "message.fill")
          .font(.title2)
          .foregroundStyle(bubbleInk)
          .frame(width: 56, height: 56)
          .background(bubbleFill, in: Circle())
      }
      .accessibilityIdentifier(A11y.chatBubble)
      .accessibilityLabel(L10n.chatOpen)
      if unread > 0 {
        Text(badge)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Theme.ink)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Theme.canvas(scheme), in: Capsule())
          .accessibilityIdentifier(A11y.chatBadge)
          .allowsHitTesting(false)
      }
    }
  }

  private var badge: String {
    unread > 9 ? "9+" : String(unread)
  }

  private var bubbleFill: Color {
    scheme == .dark ? Theme.color(Palette.accentOnDark) : Theme.wine
  }

  private var bubbleInk: Color {
    scheme == .dark ? Theme.ink : Theme.canvas
  }
}

struct RitualScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      if let ritual = model.ritual {
        header(ritual)
        if ritual.partner == nil {
          RoleLine(waiting: true, text: L10n.waitingOnThem)
          Text(L10n.waitingJoin)
          HelperText(text: L10n.waitForPartnerHelp)
        } else if ritual.isPlanner {
          RoleLine(waiting: false, text: L10n.yourTurnToPlan)
          HelperText(text: L10n.plannerHelp)
        } else {
          let name = ritual.date?.plannerName ?? ritual.partner?.displayName ?? ""
          RoleLine(waiting: false, text: L10n.partnerTurn(name))
          HelperText(text: L10n.partnerPlanning(name))
        }
        moods(ritual)
        if ritual.isPlanner, ritual.date?.status == .scheduled, ritual.revealed == false {
          hintEditor(ritual)
        } else if ritual.isPlanner, ritual.date?.status == .draft {
          planner(ritual)
        }
        reveal(ritual)
      } else {
        RoleLine(waiting: false, text: L10n.yourTurnToPlan)
        Text(L10n.noDate)
        WineButton(title: L10n.openWeek, identifier: A11y.homeRoot, busy: model.busy, busyTitle: L10n.loading) {
          Task { await model.openNextWeek() }
        }
      }
    }
  }

  private func header(_ ritual: RitualSnapshot) -> some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        MonogramView(names: [ritual.selfMember.displayName, ritual.partner?.displayName ?? ritual.inviteeName])
        Text(L10n.homeTitle).font(Theme.display).accessibilityIdentifier(A11y.homeRoot)
        Text(L10n.datesCount(ritual.completedCount))
        if ritual.streakWeeks > 0 {
          Text(L10n.weeksInARow(ritual.streakWeeks)).accessibilityIdentifier(A11y.streak)
        }
        Text(L10n.rhythm)
        if let date = ritual.date {
          Text(ZonedTime.formatWhen(date.scheduledAt, timeZone: ritual.timezone))
          Text(date.publicTeaser ?? L10n.noHint)
          Text(date.outfitHint ?? L10n.noOutfit)
        }
      }
    }
  }

  private func moods(_ ritual: RitualSnapshot) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.stack) {
      Text(L10n.yourMood).font(Theme.title)
      HelperText(text: L10n.moodHelp)
      let editable = MoodChips.isEnabled(status: ritual.date?.status, revealed: ritual.revealed)
      ForEach(MoodKey.allCases) { mood in
        let selected = ritual.moods.first { $0.userId == ritual.selfMember.userId }?.mood == mood
        MoodChip(mood: mood, selected: selected, enabled: editable) {
          Task { await model.choose(mood: mood) }
        }
      }
      if let partner = ritual.partner {
        let mood = ritual.moods.first { $0.userId == partner.userId }?.mood
        Text(mood.map { L10n.partnerMoodLine(partner.displayName, L10n.moodName($0)) } ?? L10n.waitingChoice)
          .accessibilityIdentifier(A11y.partnerMood)
      }
    }
  }

  private func hintEditor(_ ritual: RitualSnapshot) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.stack) {
      HelperText(text: L10n.editHintHelp)
      if let plan = ritual.plan {
        Text(plan.title).font(Theme.title).accessibilityIdentifier(A11y.planTitle)
        Text(plan.summary)
      }
      LabeledField(title: L10n.teaser, text: $model.teaser, identifier: A11y.teaser, need: .optional)
      LabeledField(title: L10n.outfit, text: $model.outfit, identifier: A11y.outfit, need: .optional)
      LabeledField(title: L10n.privateNotes, text: $model.privateNotes, identifier: A11y.notes, need: .optional)
      WineButton(title: L10n.saveHint, identifier: A11y.saveHint, busy: model.activity == .saveHint, busyTitle: L10n.loading) {
        Task { await model.saveHint() }
      }
    }
  }

  private func planner(_ ritual: RitualSnapshot) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.stack) {
      Text(L10n.whereTitle).font(Theme.title)
      ActionButton(title: L10n.byTradition, identifier: A11y.place(.auto)) { Task { await model.choose(place: .auto) } }
      ActionButton(title: L10n.atHome, identifier: A11y.place(.home)) { Task { await model.choose(place: .home) } }
      ActionButton(title: L10n.out, identifier: A11y.place(.out)) { Task { await model.choose(place: .out) } }
      Text(ritual.date?.locationIsOverride == true ? L10n.overrideHint : L10n.traditionHint)
      ActionButton(title: L10n.swap, identifier: A11y.swap) { Task { await model.swap() } }
      ActionButton(title: L10n.surprise, identifier: A11y.surprise) { Task { await model.surprise() } }
      if let plan = ritual.plan {
        Text(plan.title).font(Theme.title).accessibilityIdentifier(A11y.planTitle)
        Text(plan.summary)
      }
      LabeledField(title: L10n.teaser, text: $model.teaser, identifier: A11y.teaser, need: .optional)
      LabeledField(title: L10n.outfit, text: $model.outfit, identifier: A11y.outfit, need: .optional)
      LabeledField(title: L10n.privateNotes, text: $model.privateNotes, identifier: A11y.notes, need: .optional)
      LabeledField(title: L10n.dateLabel, text: $model.planDay, identifier: A11y.dayField)
      LabeledField(title: L10n.timeLabel, text: $model.planTime, identifier: A11y.timeField)
      WineButton(title: L10n.saveDate, identifier: A11y.saveDate, busy: model.activity == .saveDate, busyTitle: L10n.loading) {
        Task { await model.saveDate() }
      }
      ActionButton(title: L10n.skipWeek, identifier: A11y.skipWeek) { Task { await model.skip() } }
    }
  }

  @ViewBuilder private func reveal(_ ritual: RitualSnapshot) -> some View {
    if model.focusReveal || ritual.revealed || ritual.date?.status == .scheduled {
      VStack(alignment: .leading, spacing: Theme.Space.stack) {
        Text(ritual.plan == nil ? L10n.sealedTitle : L10n.revealedEyebrow).font(Theme.title)
        Text(ritual.plan == nil ? L10n.sealedBody : (ritual.plan?.summary ?? ""))
        if ritual.date?.status == .scheduled && ritual.revealed == false && ritual.isPlanner {
          WineButton(title: L10n.revealButton, identifier: A11y.reveal, busy: model.activity == .reveal, busyTitle: L10n.loading) {
            Task { await model.revealPlan() }
          }
        }
        if ritual.isPlanner && ritual.date?.status == .scheduled {
          ActionButton(title: L10n.skipWeek, identifier: A11y.skipWeek) { Task { await model.skip() } }
        }
        ActionButton(title: L10n.addCalendar) { Task { await model.addCalendar() } }
        LabeledField(title: L10n.moment, text: $model.momentDraft, identifier: A11y.memoryNote, need: .optional)
        WineButton(title: L10n.finish, identifier: A11y.saveNote, busy: model.activity == .finish, busyTitle: L10n.loading) {
          Task { await model.finishNight() }
        }
      }
    }
  }
}

struct MemoriesScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      Text(L10n.memoriesTitle).font(Theme.display).accessibilityIdentifier(A11y.memoriesRoot)
      Text(L10n.memoriesBody)
      HelperText(text: L10n.memoriesNext)
      if model.memories.isEmpty {
        Text(L10n.memoriesEmpty).accessibilityIdentifier(A11y.memoriesEmpty)
      }
      ForEach(model.memories) { memory in
        DateMemoryCard(model: model, memory: memory)
      }
      if model.editingDate != nil {
        LabeledField(title: L10n.moment, text: $model.noteDraft, identifier: A11y.memoryNoteField, need: .optional)
        WineButton(title: L10n.saveMoment, identifier: A11y.memorySave, busy: model.activity == .moment, busyTitle: L10n.loading) {
          Task { await model.saveMoment() }
        }
        ActionButton(title: L10n.deleteMoment, kind: .destructive) { Task { await model.deleteMoment() } }
      }
    }
  }
}

private struct DateMemoryCard: View {
  @Bindable var model: SessionModel
  let memory: MemoryItem
  @State private var photo: PhotosPickerItem?

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Space.stack) {
      Capsule()
        .fill(Theme.wine)
        .frame(width: 3)
      GlassCard {
        VStack(alignment: .leading, spacing: 8) {
          Text(memory.when.formatted(date: .abbreviated, time: .omitted))
            .font(Theme.caption)
          Text(L10n.memoryNumber(memory.number))
          Text(memory.title).font(Theme.title)
          photoView
          ForEach(memory.notes) { note in
            Text(note.note)
            if note.mine {
              ActionButton(title: L10n.editMoment) {
                model.editingDate = memory.id
                model.editingNote = note.id
                model.noteDraft = note.note
              }
            }
          }
          ActionButton(title: L10n.addMoment) { model.editingDate = memory.id }
          PhotosPicker(selection: $photo, matching: .images) { Text(L10n.addPhoto) }
            .buttonStyle(JustButtonStyle(kind: .secondary))
          if Launch.isUITest {
            ActionButton(title: L10n.samplePhoto, identifier: A11y.samplePhoto) {
              model.editingDate = memory.id
              Task { await model.useSamplePhoto() }
            }
          }
        }
      }
    }
    .onChange(of: photo) { _, item in
      guard let item else { return }
      Task { await store(item) }
    }
  }

  @ViewBuilder
  private var photoView: some View {
    if let data = memory.photoJPEG, let image = UIImage(data: data) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxHeight: 220)
        .accessibilityLabel(L10n.photo)
        .accessibilityIdentifier(A11y.memoryPhoto)
    } else if memory.photoState == .failed {
      Text(L10n.retryPhoto)
    }
  }

  private func store(_ item: PhotosPickerItem) async {
    guard let picked = try? await item.loadTransferable(type: PickedImage.self) else {
      model.errorMessage = L10n.photoFailed
      return
    }
    await model.savePhoto(picked.data, dateId: memory.id)
  }
}

struct SettingsScreen: View {
  @Bindable var model: SessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      Text(L10n.settingsTitle).font(Theme.display).accessibilityIdentifier(A11y.settingsRoot)
      Text(L10n.settingsBody)
      HelperText(text: L10n.settingsNext)
      if let settings = model.settings {
        Text(settings.selfName)
        Text(settings.partnerName)
        Toggle(L10n.notifyMood, isOn: moodBinding).accessibilityIdentifier(A11y.notifyMood)
        Toggle(L10n.notifyPlan, isOn: planBinding).accessibilityIdentifier(A11y.notifyPlan)
        Toggle(L10n.notifyInvite, isOn: inviteBinding).accessibilityIdentifier(A11y.notifyInvite)
        Toggle(L10n.notifyWeek, isOn: weekBinding).accessibilityIdentifier(A11y.notifyWeek)
        if settings.partnerJoined {
          Text(L10n.partnerHere)
          if model.confirmUnlink {
            Text(L10n.unlinkBody)
            WineButton(title: L10n.unlinkConfirm, identifier: A11y.unlinkConfirm) { Task { await model.unlinkPartner() } }
            ActionButton(title: L10n.stay) { model.confirmUnlink = false }
          } else {
            ActionButton(title: L10n.unlink, identifier: A11y.unlink, kind: .destructive) {
              model.confirmUnlink = true
            }
          }
        }
      }
      LabeledField(title: L10n.myName, text: $model.draft.selfName, identifier: A11y.selfName)
      LabeledField(title: L10n.ourTime, text: $model.draft.localTime, identifier: A11y.timeField)
      WineButton(title: L10n.saveSettings, identifier: A11y.saveSettings, busy: model.activity == .settings, busyTitle: L10n.loading) {
        Task { await model.saveSettings() }
      }
      if let privacy = URL(string: AppConfig.privacyURL) {
        AccentLink(title: L10n.privacy, destination: privacy)
      }
      if let support = URL(string: AppConfig.supportURL) {
        AccentLink(title: L10n.support, destination: support)
      }
      ActionButton(title: L10n.signOut, identifier: A11y.signOut) { Task { await model.signOut() } }
      ActionButton(title: L10n.deleteAccount, identifier: A11y.deleteAccount, kind: .destructive) {
        model.showDelete = true
      }
      if model.showDelete {
        Text(L10n.deleteBody)
        LabeledField(title: L10n.confirmField, text: $model.deleteConfirm, identifier: A11y.deleteConfirm)
        WineButton(title: L10n.deleteAccount, identifier: A11y.deleteSubmit, busy: model.busy, busyTitle: L10n.loading) {
          Task { await model.deleteAccount() }
        }
      }
    }
  }

  private var moodBinding: Binding<Bool> {
    Binding(get: { model.settings?.preferences.partnerMood ?? true }, set: { value in Task { await model.toggle(.partnerMood, on: value) } })
  }

  private var planBinding: Binding<Bool> {
    Binding(get: { model.settings?.preferences.planReady ?? true }, set: { value in Task { await model.toggle(.planReady, on: value) } })
  }

  private var inviteBinding: Binding<Bool> {
    Binding(get: { model.settings?.preferences.inviteAccepted ?? true }, set: { value in Task { await model.toggle(.inviteAccepted, on: value) } })
  }

  private var weekBinding: Binding<Bool> {
    Binding(get: { model.settings?.preferences.weeklyReminder ?? true }, set: { value in Task { await model.toggle(.weeklyReminder, on: value) } })
  }
}
