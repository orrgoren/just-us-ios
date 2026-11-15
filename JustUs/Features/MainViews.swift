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
      if !coupleIsLinked {
        Button(L10n.haveInvite) { model.screen = .invite }
          .accessibilityIdentifier(A11y.haveInvite)
          .frame(minHeight: 44)
      }
      switch model.tab {
      case .week:
        RitualScreen(model: model)
      case .memories:
        MemoriesScreen(model: model)
      case .settings:
        SettingsScreen(model: model)
      }
    }
  }

  private var coupleIsLinked: Bool {
    model.ritual?.partner != nil || model.settings?.partnerJoined == true
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
          RoleLine(waiting: false, text: L10n.yourTurn)
          HelperText(text: L10n.plannerHelp)
        } else {
          RoleLine(waiting: true, text: L10n.waitingOnThem)
          HelperText(text: L10n.partnerWaitPlan)
        }
        moods(ritual)
        if ritual.isPlanner, ritual.date?.status == .scheduled, ritual.revealed == false {
          hintEditor(ritual)
        } else if ritual.isPlanner, ritual.date?.status == .draft {
          planner(ritual)
        }
        reveal(ritual)
      } else {
        RoleLine(waiting: false, text: L10n.yourTurn)
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
      ForEach(MoodKey.allCases) { mood in
        let selected = ritual.moods.first { $0.userId == ritual.selfMember.userId }?.mood == mood
        Button {
          Task { await model.choose(mood: mood) }
        } label: {
          HStack {
            Text(L10n.moodName(mood))
            if selected {
              Image(systemName: "checkmark")
                .accessibilityHidden(true)
            }
          }
        }
        .fontWeight(selected ? .semibold : .regular)
        .accessibilityIdentifier(A11y.mood(mood))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .frame(minHeight: 44)
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
      Button(L10n.byTradition) { Task { await model.choose(place: .auto) } }
        .accessibilityIdentifier(A11y.place(.auto)).frame(minHeight: 44)
      Button(L10n.atHome) { Task { await model.choose(place: .home) } }
        .accessibilityIdentifier(A11y.place(.home)).frame(minHeight: 44)
      Button(L10n.out) { Task { await model.choose(place: .out) } }
        .accessibilityIdentifier(A11y.place(.out)).frame(minHeight: 44)
      Text(ritual.date?.locationIsOverride == true ? L10n.overrideHint : L10n.traditionHint)
      Button(L10n.swap) { Task { await model.swap() } }
        .accessibilityIdentifier(A11y.swap).frame(minHeight: 44)
      Button(L10n.surprise) { Task { await model.surprise() } }
        .accessibilityIdentifier(A11y.surprise).frame(minHeight: 44)
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
      Button(L10n.skipWeek) { Task { await model.skip() } }
        .accessibilityIdentifier(A11y.skipWeek).frame(minHeight: 44)
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
          Button(L10n.skipWeek) { Task { await model.skip() } }
            .accessibilityIdentifier(A11y.skipWeek).frame(minHeight: 44)
        }
        Button(L10n.addCalendar) { Task { await model.addCalendar() } }.frame(minHeight: 44)
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
  @State private var photo: PhotosPickerItem?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.section) {
      Text(L10n.memoriesTitle).font(Theme.display).accessibilityIdentifier(A11y.memoriesRoot)
      Text(L10n.memoriesBody)
      HelperText(text: L10n.memoriesNext)
      if model.memories.isEmpty {
        Text(L10n.memoriesEmpty)
      }
      ForEach(model.memories) { memory in
        GlassCard {
          VStack(alignment: .leading, spacing: 8) {
            Text(L10n.memoryNumber(memory.number))
            Text(memory.title).font(Theme.title)
            if let data = memory.photoJPEG, let image = UIImage(data: data) {
              Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .accessibilityLabel(L10n.photo)
                .accessibilityIdentifier(A11y.memoryPhoto)
            }
            ForEach(memory.notes) { note in
              Text(note.note)
              if note.mine {
                Button(L10n.editMoment) {
                  model.editingDate = memory.id
                  model.editingNote = note.id
                  model.noteDraft = note.note
                }.frame(minHeight: 44)
              }
            }
            Button(L10n.addMoment) { model.editingDate = memory.id }.frame(minHeight: 44)
          }
        }
      }
      if model.editingDate != nil {
        LabeledField(title: L10n.moment, text: $model.noteDraft, identifier: A11y.memoryNoteField, need: .optional)
        WineButton(title: L10n.saveMoment, identifier: A11y.memorySave, busy: model.activity == .moment, busyTitle: L10n.loading) {
          Task { await model.saveMoment() }
        }
        Button(L10n.deleteMoment) { Task { await model.deleteMoment() } }.frame(minHeight: 44)
        PhotosPicker(selection: $photo, matching: .images) { Text(L10n.addPhoto) }
        if Launch.isUITest {
          Button(L10n.samplePhoto) { Task { await model.useSamplePhoto() } }
            .accessibilityIdentifier(A11y.samplePhoto)
            .frame(minHeight: 44)
        }
      }
    }
    .onChange(of: photo) { _, item in
      guard let item else { return }
      Task {
        if let data = try? await item.loadTransferable(type: Data.self) {
          await model.savePhoto(data)
        }
      }
    }
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
            Button(L10n.stay) { model.confirmUnlink = false }
              .frame(minHeight: 44)
          } else {
            Button(L10n.unlink) { model.confirmUnlink = true }
              .accessibilityIdentifier(A11y.unlink).frame(minHeight: 44)
          }
        }
      }
      LabeledField(title: L10n.myName, text: $model.draft.selfName, identifier: A11y.selfName)
      LabeledField(title: L10n.ourTime, text: $model.draft.localTime, identifier: A11y.timeField)
      WineButton(title: L10n.saveSettings, identifier: A11y.saveSettings, busy: model.activity == .settings, busyTitle: L10n.loading) {
        Task { await model.saveSettings() }
      }
      if let privacy = URL(string: AppConfig.privacyURL) {
        Link(L10n.privacy, destination: privacy)
      }
      if let support = URL(string: AppConfig.supportURL) {
        Link(L10n.support, destination: support)
      }
      Button(L10n.signOut) { Task { await model.signOut() } }
        .accessibilityIdentifier(A11y.signOut).frame(minHeight: 44)
      Button(L10n.deleteAccount) { model.showDelete = true }
        .accessibilityIdentifier(A11y.deleteAccount).frame(minHeight: 44)
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
