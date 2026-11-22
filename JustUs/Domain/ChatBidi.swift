import Foundation

/// Keeps a URL or an English run in its own order inside a Hebrew bubble.
enum ChatBidi {
  private static let latinRun = #"https?://\S+|[A-Za-z][A-Za-z0-9@.+_:/?&=%~#'\-]*"#

  static func display(_ text: String, rightToLeft: Bool) -> String {
    guard rightToLeft, text.isEmpty == false else { return text }
    return "\u{200F}" + isolate(text)
  }

  private static func isolate(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: latinRun) else { return text }
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    var result = ""
    var cursor = text.startIndex
    for match in regex.matches(in: text, range: full) {
      guard let span = Range(match.range, in: text) else { continue }
      result += text[cursor..<span.lowerBound]
      result += "\u{2066}"
      result += text[span]
      result += "\u{2069}"
      cursor = span.upperBound
    }
    result += text[cursor...]
    return result
  }
}
