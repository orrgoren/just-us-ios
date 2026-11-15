import Foundation

/// Every user-facing string lives here, with English as the development language.
/// Add Hebrew later by filling Localizable.xcstrings. Do not put copy in views.
enum L10n {
  static var appName: String { text("brand.name", "Just Us") }
  static var tagline: String { text("brand.tagline", "One night. Every week. Just us.") }
  static var wordmark: String { text("brand.wordmark", "Just Us") }
  static var loginTitle: String { text("auth.loginTitle", "A night that is only yours") }
  static var loginBody: String { text("auth.loginBody", "Sign in with Apple, or with a link we email to this iPhone.") }
  static var emailLabel: String { text("auth.email", "Email") }
  static var emailPrompt: String { text("auth.emailPrompt", "you@example.com") }
  static var sendCode: String { text("auth.sendCode", "Email me a sign-in link") }
  static var newLink: String { text("auth.newLink", "Email me a new link") }
  static var apple: String { text("auth.apple", "Sign in with Apple") }
  static var haveInvite: String { text("auth.haveInvite", "I have an invite") }
  static var codeTitle: String { text("auth.codeTitle", "Check your email") }
  static var codeBody: String { text("auth.codeBody", "Check your email and tap the sign-in link on this iPhone.") }
  static var codeLabel: String { text("auth.code", "Code") }
  static var verify: String { text("auth.verify", "Continue") }
  static var resend: String { text("auth.resend", "Resend link") }
  static var useAnotherEmail: String { text("auth.another", "Use a different email") }
  static var setupTitle: String { text("setup.title", "Make it yours") }
  static var setupBody: String { text("setup.body", "Your name, their name, and the evening you want to keep.") }
  static var myName: String { text("setup.myName", "My name") }
  static var theirName: String { text("setup.theirName", "Their name") }
  static var ourDay: String { text("setup.day", "Our evening") }
  static var ourTime: String { text("setup.time", "Starts at") }
  static var timezone: String { text("setup.zone", "Time zone") }
  static var duration: String { text("setup.duration", "Length") }
  static var durationHelp: String { text("setup.durationHelp", "90 minutes is the usual evening. Change it if yours runs longer.") }
  static var setupNext: String { text("setup.next", "Your turn. Fill this in, then send them a link.") }
  static var setupNamesHelp: String { text("setup.namesHelp", "They'll see the name you chose when they join.") }
  static var settingUp: String { text("setup.settingUp", "Setting up your space…") }
  static var required: String { text("field.required", "Required") }
  static var dismissKeyboard: String { text("field.done", "Done") }
  static var optional: String { text("field.optional", "Optional") }
  static var yourTurn: String { text("role.yours", "Your turn") }
  static var waitingOnThem: String { text("role.waiting", "Waiting on them") }
  static var loginNext: String { text("auth.next", "Next: sign in. Then make a space, or join theirs.") }
  static var codeNext: String { text("auth.codeNext", "The link is the way in. The code is there if you already have it.") }
  static var inviteShareNext: String { text("invite.next", "Send the app link. It opens Just Us on their phone.") }
  static var appLinkLabel: String { text("invite.appLink", "Opens in the app") }
  static var joinNext: String { text("invite.joinNext", "Paste their code. You join their space, not a new one.") }
  static var spaceReady: String { text("celebrate.space", "Your space is ready.") }
  static var paired: String { text("celebrate.paired", "You're paired. The week is yours.") }
  static var nightSet: String { text("celebrate.night", "The night is set.") }
  static var waitForPartnerHelp: String { text("ritual.waitHelp", "Nothing else for you until they open the link.") }
  static var plannerHelp: String { text("ritual.plannerHelp", "You're planning. They see the hint, not the surprise, until you reveal it.") }
  static var partnerWaitPlan: String { text("ritual.partnerPlan", "They're planning. Pick your mood, then wait for the hint.") }
  static var moodHelp: String { text("ritual.moodHelp", "One mood. They'll see yours. The plan stays with the planner.") }
  static var memoriesNext: String { text("memories.next", "Optional. A line or a photo, once the night is done.") }
  static var settingsNext: String { text("settings.next", "Names are required. The nudges are optional.") }
  static var softNext: String { text("push.next", "Your turn. Say yes if you want a nudge when they join.") }
  static var createSpace: String { text("setup.create", "Create our space") }
  static var joinInstead: String { text("setup.join", "Join with a code instead") }
  static var inviteTitle: String { text("invite.title", "Bring them in") }
  static var inviteBody: String { text("invite.body", "Share a one-time link, or read them the code. It lasts seven days.") }
  static var shareInvite: String { text("invite.share", "Share invite") }
  static var copyCode: String { text("invite.showCode", "Show the code") }
  static var skipInvite: String { text("invite.skip", "I'll invite them later") }
  static var pasteCode: String { text("invite.paste", "Invite code or link") }
  static var join: String { text("invite.join", "Join this space") }
  static var replaceJoin: String { text("invite.replace", "Join and leave my empty space") }
  static var stay: String { text("invite.stay", "Stay where I am") }
  static var replaceBody: String { text("invite.replaceBody", "You already have an empty space, with no partner and no saved date. Joining removes that empty space and connects this account to the invite.") }
  static var joinBody: String { text("invite.joinBody", "This code works once. Joining connects this account to their space, and only theirs.") }
  static var keptBody: String { text("invite.keptBody", "This account already shares a space that has history. An invite can't replace it.") }
  static var softPromptTitle: String { text("push.softTitle", "Want a heads-up when they join?") }
  static var softPromptBody: String { text("push.softBody", "We'll only ask the system if you say yes. You can change this later.") }
  static var softYes: String { text("push.yes", "Yes, nudge me") }
  static var softNo: String { text("push.no", "Not now") }
  static var pushDenied: String { text("push.denied", "Notifications stay off. You can turn them on in Settings.") }
  static var tabWeek: String { text("tab.week", "This week") }
  static var tabMemories: String { text("tab.memories", "Memories") }
  static var tabUs: String { text("tab.us", "Us") }
  static var homeTitle: String { text("home.title", "This week, just us") }
  static var homeBody: String { text("home.body", "Pick a mood. Whoever is planning keeps the surprise.") }
  static var datesTogether: String { text("home.dates", "Dates together") }
  static var rhythm: String { text("home.rhythm", "Three in, one out") }
  static var plannerLabel: String { text("home.planner", "Planning") }
  static var yourMood: String { text("ritual.yourMood", "Your mood") }
  static var waitingChoice: String { text("ritual.waitingChoice", "Waiting for their pick") }
  static var waitingJoin: String { text("ritual.waitingJoin", "Waiting for them to join") }
  static var whereTitle: String { text("ritual.where", "Where this time?") }
  static var byTradition: String { text("ritual.tradition", "By tradition") }
  static var atHome: String { text("ritual.home", "At home") }
  static var out: String { text("ritual.out", "Out") }
  static var traditionHint: String { text("ritual.traditionHint", "Three evenings at home, then one out.") }
  static var overrideHint: String { text("ritual.override", "This choice steps off the rhythm.") }
  static var swap: String { text("ritual.swap", "Swap planner") }
  static var surprise: String { text("plan.surprise", "Surprise us") }
  static var anotherIdea: String { text("plan.another", "Another idea") }
  static var dateLabel: String { text("plan.date", "Date") }
  static var timeLabel: String { text("plan.time", "Time") }
  static var teaserLegend: String { text("plan.teaserLegend", "A hint they can see") }
  static var teaser: String { text("plan.teaser", "Hint") }
  static var outfit: String { text("plan.outfit", "What to wear") }
  static var privateNotes: String { text("plan.notes", "Private notes, only for the planner") }
  static var saveHint: String { text("plan.saveHint", "Save hint") }
  static var saveDate: String { text("plan.save", "Save our date") }
  static var skipWeek: String { text("plan.skip", "Skip this week") }
  static var presetHungry: String { text("plan.hungry", "Come hungry") }
  static var presetPajamas: String { text("plan.pajamas", "Pajamas") }
  static var presetDress: String { text("plan.dress", "Dress up") }
  static var sealedTitle: String { text("reveal.sealedTitle", "A night is on the way") }
  static var sealedBody: String { text("reveal.sealedBody", "You can see when, where, and the hint. Not the surprise.") }
  static var emptyPlanTitle: String { text("reveal.emptyTitle", "Your next night is waiting") }
  static var emptyPlanBody: String { text("reveal.emptyBody", "Pick moods, then ask for a surprise.") }
  static var ideaEyebrow: String { text("reveal.idea", "The idea") }
  static var savedEyebrow: String { text("reveal.saved", "Saved for both of you") }
  static var revealedEyebrow: String { text("reveal.open", "Revealed") }
  static var prep: String { text("reveal.prep", "Prepare") }
  static var twist: String { text("reveal.twist", "The small twist") }
  static var question: String { text("reveal.question", "A question to end on") }
  static var privateNotePrefix: String { text("reveal.private", "Private note") }
  static var revealButton: String { text("reveal.button", "Reveal the surprise") }
  static var reopen: String { text("reveal.reopen", "Back to draft") }
  static var move: String { text("reveal.move", "Move the time") }
  static var noHint: String { text("reveal.noHint", "No hint yet. The surprise is still cooking.") }
  static var noOutfit: String { text("reveal.noOutfit", "Nothing special to wear.") }
  static var afterTitle: String { text("after.title", "How was it?") }
  static var afterBody: String { text("after.body", "Keep one moment. The full idea stays hidden until the night is closed, unless it was revealed.") }
  static var moment: String { text("after.moment", "A moment to keep") }
  static var finish: String { text("after.finish", "We did it. Save the memory") }
  static var addCalendar: String { text("after.calendar", "Add to calendar") }
  static var openWeek: String { text("home.open", "Open this week") }
  static var noDate: String { text("home.noDate", "No evening is open. You can start the next one without losing memories.") }
  static var memoriesTitle: String { text("memories.title", "What we kept") }
  static var memoriesBody: String { text("memories.body", "One note, and one photo, for each night.") }
  static var memoriesEmpty: String { text("memories.empty", "Nothing saved yet. Your first night is on the way.") }
  static var addMoment: String { text("memories.add", "Add your moment") }
  static var saveMoment: String { text("memories.save", "Save") }
  static var editMoment: String { text("memories.edit", "Edit") }
  static var deleteMoment: String { text("memories.delete", "Delete this moment") }
  static var enough: String { text("memories.enough", "We were together. That is enough.") }
  static var addPhoto: String { text("memories.photo", "Add a photo") }
  static var retryPhoto: String { text("memories.retryPhoto", "Try the photo again") }
  static var photoFailed: String { text("memories.photoFailed", "The photo didn't save. The memory is unchanged.") }
  static var samplePhoto: String { text("memories.sample", "Use sample photo") }
  static var settingsTitle: String { text("settings.title", "The two of us") }
  static var settingsBody: String { text("settings.body", "Names, the weekly rhythm, invites, and notifications.") }
  static var saveSettings: String { text("settings.save", "Save") }
  static var notifications: String { text("settings.notifications", "Notifications") }
  static var notifyMood: String { text("settings.notifyMood", "When they pick a mood") }
  static var notifyPlan: String { text("settings.notifyPlan", "When a date is ready to reveal") }
  static var notifyInvite: String { text("settings.notifyInvite", "When they join") }
  static var notifyWeek: String { text("settings.notifyWeek", "The weekly reminder") }
  static var partnerHere: String { text("settings.partnerHere", "They're already here. No new link is needed.") }
  static var newInvite: String { text("settings.newInvite", "Create an invite link") }
  static var exportMemories: String { text("settings.export", "Export memories") }
  static var importLegacy: String { text("settings.import", "Import an older backup") }
  static var unlink: String { text("settings.unlink", "Unlink me") }
  static var unlinkBody: String {
    text("settings.unlinkBody", "This closes the space for both of you, including the nights and memories.")
  }
  static var deleteAccount: String { text("settings.delete", "Delete my account") }
  static var deleteBody: String {
    text(
      "settings.deleteBody",
      "This closes your shared space, including the nights and memories, and removes your login. Type delete to confirm."
    )
  }
  static var spaceClosed: String { text("setup.spaceClosed", "Your space was closed") }
  static var deleteWord: String { text("settings.deleteWord", "delete") }
  static var confirmField: String { text("settings.confirm", "Confirmation") }
  static var privacy: String { text("settings.privacy", "Privacy policy") }
  static var support: String { text("settings.support", "Support") }
  static var signOut: String { text("settings.signOut", "Sign out") }
  static var offline: String { text("state.offline", "You're offline. Showing what we last saved. Nothing new will be lost or duplicated.") }
  static var retry: String { text("state.retry", "Try again") }
  static var discard: String { text("state.discard", "Discard unsynced changes") }
  static var continueOn: String { text("common.continue", "Continue") }
  static var loading: String { text("state.loading", "One moment") }
  static var emptyError: String { text("state.error", "Something went wrong.") }
  static var saved: String { text("state.saved", "Saved") }
  static var skipToContent: String { text("a11y.skip", "Skip to content") }
  static var monogram: String { text("a11y.monogram", "Your initials") }
  static var close: String { text("common.close", "Close") }
  static var cancel: String { text("common.cancel", "Cancel") }

  static func moodName(_ mood: MoodKey) -> String {
    switch mood {
    case .fun: return text("mood.fun", "Laughs")
    case .romance: return text("mood.romance", "Romance")
    case .deep: return text("mood.deep", "A real talk")
    case .intimacy: return text("mood.intimacy", "Closeness")
    case .adventure: return text("mood.adventure", "Something new")
    case .chill: return text("mood.chill", "Easy together")
    }
  }

  static func partnerMoodLine(_ name: String, _ mood: String) -> String {
    String(format: text("ritual.partnerMoodLine", "%1$@'s mood is %2$@"), locale: .current, name, mood)
  }

  static var back: String { text("invite.back", "Back") }
  static var signInFirst: String { text("invite.signInFirst", "Sign in before joining a space.") }
  static var unlinkConfirm: String { text("settings.unlinkConfirm", "Yes, unlink") }
  static var photo: String { text("memories.photo", "Photo from the night") }

  static func moodOf(_ name: String) -> String {
    String(format: text("ritual.moodOf", "%@'s mood"), locale: .current, name)
  }

  static func datesCount(_ count: Int) -> String {
    String(format: text("home.count", "%lld together"), locale: .current, count)
  }

  static func inviteShareText(app: String, web: String?, code: String) -> String {
    if let web, !web.isEmpty {
      return String(
        format: text(
          "invite.shareText",
          "Join me on Just Us. Open the app link, or paste the code.\n%@\n%@\n%@"
        ),
        locale: .current,
        app,
        web,
        code
      )
    }
    return String(
      format: text("invite.shareTextApp", "Join me on Just Us. Open the app link, or paste the code.\n%@\n%@"),
      locale: .current,
      app,
      code
    )
  }

  static func minutes(_ count: Int) -> String {
    String(format: text("setup.minutes", "%lld min"), locale: .current, count)
  }

  static func cooldown(_ seconds: Int) -> String {
    String(format: text("auth.cooldown", "You can resend in %lld seconds."), locale: .current, seconds)
  }

  static func memoryNumber(_ number: Int) -> String {
    String(format: text("memories.number", "Night %lld"), locale: .current, number)
  }

  static func message(for error: AppError) -> String {
    outcomeMessage(error)
  }

  private static func fieldMessage(_ issue: FieldIssue) -> String {
    switch issue {
    case .email: return text("err.email", "That email doesn't look right.")
    case .name: return text("err.name", "Names need 1 to 24 characters.")
    case .time: return text("err.time", "Check the time.")
    case .timezone: return text("err.zone", "That time zone isn't recognized.")
    case .weekday: return text("err.day", "Pick a day.")
    case .duration: return text("err.duration", "Length should be between 30 and 360 minutes.")
    case .note: return text("err.note", "That note is empty or too long.")
    case .teaser: return text("err.teaser", "That hint is too long.")
    case .date: return text("err.date", "Check the date.")
    case .code: return text("err.codeFormat", "Enter the digits from the email.")
    case .confirm: return text("err.confirm", "Type delete to confirm.")
    }
  }

  private static func outcomeMessage(_ error: AppError) -> String {
    switch error {
    case .offline: return offline
    case .timeout: return text("err.timeout", "That took too long. Nothing was marked as saved.")
    case .sessionExpired: return text("err.session", "Your session expired. Sign in again.")
    case .linkExpired: return text("err.link", "That link expired or was already used. Email yourself a new one.")
    case .invalid(let issue): return fieldMessage(issue)
    case .invalidCode: return text("err.badCode", "That code isn't valid.")
    case .expiredCode: return text("err.expiredCode", "That code has expired. Resend a new one.")
    case .cooldown(let seconds): return cooldown(seconds)
    case .alreadyInCouple: return text("err.already", "This account is already in a shared space.")
    case .soloNotEmpty: return text("err.solo", "Your space already has more than an empty draft, so an invite can't replace it.")
    case .invalidInvite: return text("err.invite", "That invite isn't valid.")
    case .revokedInvite: return text("err.revoked", "That invite was canceled.")
    case .usedInvite: return text("err.used", "That invite was already used.")
    case .expiredInvite: return text("err.inviteExpired", "That invite has expired.")
    case .coupleFull: return text("err.full", "That space already has two people.")
    case .selfRedeem: return text("err.self", "You can't redeem an invite you created.")
    case .notAuthenticated: return text("err.auth", "Sign in again.")
    case .notPlanner: return text("err.planner", "Only this week's planner can do that.")
    case .missingPlan: return text("err.plan", "Pick an idea first.")
    case .unavailable: return text("err.unavailable", "That needs a server update that isn't on yet. Nothing was changed.")
    case .saveFailed: return text("err.save", "We couldn't save. Nothing was marked as done.")
    case .rateLimited: return text("err.rate", "Too many tries. Wait a few minutes.")
    case .confirmationRequired: return text("err.needConfirm", "Confirm before adding to memories you already have.")
    case .unsyncedChanges: return text("err.unsynced", "You still have changes that aren't saved. Try again when you're online, or discard them.")
    case .server(let code): return String(format: text("err.server", "Something went wrong (%@)."), locale: .current, code)
    }
  }

  private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: value)
  }
}
