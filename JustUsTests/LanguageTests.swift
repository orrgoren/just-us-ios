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
    XCTAssertEqual(hebrew.hourCycle, .zeroToTwentyThree)
    XCTAssertEqual(L10n.lookup("settings.title", "The two of us", locale: hebrew), "שנינו")
    XCTAssertEqual(L10n.lookup("chat.arrived", "New message", locale: hebrew), "הודעה חדשה")
    XCTAssertEqual(L10n.lookup("field.done", "Done", locale: hebrew), "סיום")
    XCTAssertEqual(L10n.lookup("home.twoWeeks", "2 weeks in a row", locale: hebrew), "שבועיים ברצף")
    XCTAssertEqual(L10n.lookup("auth.cooldownOne", "You can resend in 1 second.", locale: hebrew), "אפשר לשלוח שוב בעוד שנייה.")
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
}
