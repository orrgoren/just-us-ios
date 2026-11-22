import SwiftUI
import XCTest
@testable import JustUs

final class LanguageTests: XCTestCase {
  func testSystemHebrewAndManualOverride() {
    XCTAssertEqual(AppLanguage.resolvedCode(choice: .system, preferred: ["he-IL", "en-US"]), "he")
    XCTAssertEqual(AppLanguage.resolvedCode(choice: .system, preferred: ["he", "en"]), "he")
    XCTAssertEqual(AppLanguage.resolvedCode(choice: .system, preferred: ["en-US"]), "en")
    XCTAssertEqual(AppLanguage.resolvedCode(choice: .system, preferred: ["fr-FR", "en-US"]), "en")
    XCTAssertEqual(AppLanguage.resolvedCode(choice: .en, preferred: ["he-IL"]), "en")
    XCTAssertEqual(AppLanguage.resolvedCode(choice: .he, preferred: ["en-US"]), "he")
  }

  func testHebrewPluralCategories() {
    XCTAssertEqual(AppLanguage.pluralCategory(1), .one)
    XCTAssertEqual(AppLanguage.pluralCategory(2), .two)
    XCTAssertEqual(AppLanguage.pluralCategory(0), .other)
    XCTAssertEqual(AppLanguage.pluralCategory(5), .other)
    XCTAssertEqual(AppLanguage.pluralCategory(11), .other)
    XCTAssertEqual(AppLanguage.pluralCategory(20), .many)
    XCTAssertEqual(AppLanguage.pluralCategory(30), .many)
  }

  func testHebrewCatalogAndPlurals() {
    let hebrew = AppLanguage.locale(for: .he, preferred: ["en-US"])
    XCTAssertEqual(hebrew.language.languageCode?.identifier, "he")
    XCTAssertEqual(AppLanguage.clockLocale(hebrew).hourCycle, .zeroToTwentyThree)
    XCTAssertEqual(L10n.lookup("settings.title", "The two of us", locale: hebrew), "שנינו")
    XCTAssertEqual(L10n.lookup("chat.arrived", "New message", locale: hebrew), "הודעה חדשה")
    XCTAssertEqual(L10n.lookup("field.done", "Done", locale: hebrew), "סיום")
    XCTAssertEqual(L10n.lookup("home.twoWeeks", "2 weeks in a row", locale: hebrew), "שבועיים ברצף")
    XCTAssertEqual(L10n.lookup("auth.cooldownOne", "You can resend in 1 second.", locale: hebrew), "אפשר לשלוח שוב בעוד שנייה.")
    XCTAssertEqual(L10n.lookup("chat.sending", "Sending", locale: hebrew), "שולח…")
    XCTAssertEqual(L10n.lookup("setup.join", "Join with a code instead", locale: hebrew), "יש לי קוד להצטרפות")
    XCTAssertEqual(L10n.lookup("role.yours", "Your turn", locale: hebrew), "תורכם")
    XCTAssertEqual(L10n.lookup("setup.namesHelp", "They'll see the name you chose when they join.", locale: hebrew), "הם יראו את השם שבחרתם כשיצטרפו.")
    XCTAssertEqual(L10n.lookup("invite.stay", "Stay where I am", locale: hebrew), "נישאר איפה שאנחנו")
    XCTAssertEqual(L10n.lookup("settings.notifyPlan", "When a date is ready to reveal", locale: hebrew), "כשהדייט מוכן לחשיפה")
    XCTAssertEqual(L10n.lookup("calendar.summary", "Just Us — our evening", locale: hebrew), "Just Us — הערב שלנו")
    XCTAssertEqual(
      L10n.lookup(
        "calendar.details",
        "A weekly date. Three at home, one out. Phones away.",
        locale: hebrew
      ),
      "דייט שבועי. שלושה בבית, אחד בחוץ. בלי טלפונים."
    )
    let english = AppLanguage.locale(for: .en, preferred: ["he-IL"])
    XCTAssertEqual(L10n.lookup("settings.title", "The two of us", locale: english), "The two of us")
  }

  func testManualChoiceIsStored() {
    let defaults = UserDefaults.standard
    let key = "justus.language"
    let stored = defaults.string(forKey: key)
    let previous = AppLanguage.shared.choice
    defer {
      AppLanguage.shared.choice = previous
      if let stored {
        defaults.set(stored, forKey: key)
      } else if previous == .system {
        defaults.removeObject(forKey: key)
      }
    }
    AppLanguage.shared.choice = .he
    XCTAssertEqual(defaults.string(forKey: key), "he")
    XCTAssertEqual(AppLanguage.shared.code, "he")
    XCTAssertEqual(AppLanguage.shared.direction, .rightToLeft)
    AppLanguage.shared.choice = .en
    XCTAssertEqual(defaults.string(forKey: key), "en")
    XCTAssertEqual(AppLanguage.shared.direction, .leftToRight)
  }

  func testMixedDirectionBubbleKeepsTheURL() throws {
    let raw = "ראו https://just.us/night הערב"
    let shown = ChatBidi.display(raw, rightToLeft: true)
    XCTAssertTrue(shown.hasPrefix("\u{200F}"))
    XCTAssertTrue(shown.contains("\u{2066}https://just.us/night\u{2069}"))
    let lead = try XCTUnwrap(shown.range(of: "ראו"))
    let url = try XCTUnwrap(shown.range(of: "https://just.us/night"))
    let tail = try XCTUnwrap(shown.range(of: "הערב"))
    XCTAssertLessThan(lead.lowerBound, url.lowerBound)
    XCTAssertLessThan(url.lowerBound, tail.lowerBound)
    XCTAssertEqual(ChatBidi.display(raw, rightToLeft: false), raw)
    let english = ChatBidi.display("Thursday still works.", rightToLeft: true)
    XCTAssertTrue(english.contains("\u{2066}Thursday still works.\u{2069}"))
    let phrase = ChatBidi.display("I'll bring tea.", rightToLeft: true)
    XCTAssertTrue(phrase.contains("\u{2066}I'll bring tea.\u{2069}"))
  }
}
