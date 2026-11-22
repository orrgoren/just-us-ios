import Foundation

/// Keeps an English phrase or a URL in its own order inside a Hebrew bubble.
enum ChatBidi {
  static func display(_ text: String, rightToLeft: Bool) -> String {
    guard rightToLeft, text.isEmpty == false else { return text }
    return "\u{200F}" + isolate(text)
  }

  /// One isolate per foreign phrase. Isolating each word lets the RTL paragraph reverse them.
  private static func isolate(_ text: String) -> String {
    var result = ""
    var run = ""
    for character in text {
      if isHebrew(character) {
        flush(run, into: &result)
        run = ""
        result.append(character)
      } else {
        run.append(character)
      }
    }
    flush(run, into: &result)
    return result
  }

  private static func flush(_ run: String, into result: inout String) {
    let core = run.trimmingCharacters(in: .whitespacesAndNewlines)
    guard core.contains(where: isLatinOrDigit), let range = run.range(of: core) else {
      result += run
      return
    }
    result += run[..<range.lowerBound]
    result += "\u{2066}"
    result += core
    result += "\u{2069}"
    result += run[range.upperBound...]
  }

  private static func isHebrew(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      (0x0590...0x05FF).contains(scalar.value) || (0xFB1D...0xFB4F).contains(scalar.value)
    }
  }

  private static func isLatinOrDigit(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      (65...90).contains(scalar.value)
        || (97...122).contains(scalar.value)
        || (48...57).contains(scalar.value)
    }
  }
}
