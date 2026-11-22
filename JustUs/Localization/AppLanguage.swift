import Foundation
import SwiftUI

/// The in-app language. System follows the phone, and only Hebrew and English have copy.
/// A manual choice is stored on the device and wins over the phone language.
@Observable
final class AppLanguage {
  static let shared = AppLanguage()

  enum Choice: String, CaseIterable, Hashable {
    case system
    case en
    case he
  }

  enum PluralCategory: Equatable {
    case one, two, many, other
  }

  private static let storageKey = "justus.language"

  var choice: Choice {
    didSet {
      guard choice != oldValue else { return }
      if persistChoice {
        UserDefaults.standard.set(choice.rawValue, forKey: Self.storageKey)
      }
      lastResolved = Self.resolvedCode(choice: choice, preferred: Locale.preferredLanguages)
      revision += 1
    }
  }

  /// Bumped on every change so the root view rebuilds strings and layout direction together.
  private(set) var revision = 0
  private var persistChoice: Bool
  private var lastResolved: String

  private init() {
    let launch = Launch.argument(after: "-JustUsLanguage")
    let stored = UserDefaults.standard.string(forKey: Self.storageKey)
    if let launch, let parsed = Choice(rawValue: launch) {
      choice = parsed
      persistChoice = false
    } else if let stored, let parsed = Choice(rawValue: stored) {
      choice = parsed
      persistChoice = true
    } else {
      choice = .system
      persistChoice = true
    }
    lastResolved = Self.resolvedCode(choice: choice, preferred: Locale.preferredLanguages)
  }

  /// `en` or `he`. This is the value stored on the server for push copy.
  var code: String {
    Self.resolvedCode(choice: choice, preferred: Locale.preferredLanguages)
  }

  var locale: Locale {
    Self.locale(for: choice, preferred: Locale.preferredLanguages)
  }

  var direction: LayoutDirection {
    locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
  }

  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Self.clockLocale(locale)
    calendar.timeZone = .current
    return calendar
  }

  /// A phone-language change while the app was backgrounded, when the choice is System.
  func noteSystemChange() {
    let next = Self.resolvedCode(choice: choice, preferred: Locale.preferredLanguages)
    guard next != lastResolved else { return }
    lastResolved = next
    revision += 1
  }

  static func resolvedCode(choice: Choice, preferred: [String]) -> String {
    switch choice {
    case .en: return "en"
    case .he: return "he"
    case .system:
      let hebrew = preferred.contains { identifier in
        identifier == "he" || identifier.hasPrefix("he-") || identifier.hasPrefix("he_")
      }
      return hebrew ? "he" : "en"
    }
  }

  static func locale(for choice: Choice, preferred: [String] = Locale.preferredLanguages) -> Locale {
    if resolvedCode(choice: choice, preferred: preferred) == "he" {
      return hebrewLocale
    }
    if choice == .en {
      var components = Locale.Components(languageCode: Locale.LanguageCode("en"))
      components.languageRegion = Locale.current.region
      return Locale(components: components)
    }
    return .current
  }

  /// Hebrew dates and clocks use he_IL and a 24-hour clock.
  static func clockLocale(_ locale: Locale) -> Locale {
    guard locale.language.languageCode?.identifier == "he" else { return locale }
    return hebrewLocale
  }

  /// CLDR Hebrew categories. English uses the same buckets and its own wording for each.
  static func pluralCategory(_ value: Int) -> PluralCategory {
    let count = abs(value)
    if count == 1 { return .one }
    if count == 2 { return .two }
    if count > 10 && count % 10 == 0 { return .many }
    return .other
  }

  private static var hebrewLocale: Locale {
    var components = Locale.Components(languageCode: Locale.LanguageCode("he"))
    components.languageRegion = Locale.Region("IL")
    components.hourCycle = .zeroToTwentyThree
    return Locale(components: components)
  }
}
