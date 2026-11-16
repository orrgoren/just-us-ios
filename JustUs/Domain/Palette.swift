import Foundation

enum Palette {
  struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ hex: UInt32) {
      r = Double((hex >> 16) & 0xFF) / 255
      g = Double((hex >> 8) & 0xFF) / 255
      b = Double(hex & 0xFF) / 255
    }

    func luminance() -> Double {
      func channel(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
  }

  static let canvas = RGB(0xF6F0E6)
  static let canvasDark = RGB(0x1A1412)
  static let ink = RGB(0x2C211C)
  static let inkDark = RGB(0xF6EFE8)
  static let muted = RGB(0x5E534A)
  static let mutedDark = RGB(0xD2C3B6)
  static let wine = RGB(0x6E2436)
  static let blush = RGB(0xF3D9D2)
  static let champagne = RGB(0xE8D6B8)
  static let ivory = RGB(0xF6F0E6)
  static let accentOnDark = RGB(0xE7B7C2)
  static let winePressed = RGB(0x541827)
  static let blushPressed = RGB(0xE4C4BA)
  static let secondaryDark = RGB(0x3A242C)
  static let secondaryDarkPressed = RGB(0x4A3038)
  static let disabledFillDark = RGB(0x3A322C)

  static func moodSelected(_ mood: MoodKey) -> RGB {
    switch mood {
    case .fun: return RGB(0x8E5713)
    case .romance: return wine
    case .deep: return RGB(0x4C6584)
    case .intimacy: return RGB(0x974A63)
    case .adventure: return RGB(0x287051)
    case .chill: return RGB(0x3E6C64)
    }
  }

  /// Dark selected fill. Romance uses the brand wine in light mode. That wine
  /// is under 3:1 on the dark canvas, so the dark fill is wine lightened to 3:1.
  static func moodSelectedDark(_ mood: MoodKey) -> RGB {
    switch mood {
    case .romance: return RGB(0x8C5260)
    default: return moodSelected(mood)
    }
  }

  static func moodBorderDark(_ mood: MoodKey) -> RGB {
    switch mood {
    case .fun: return RGB(0x9E6F34)
    case .romance: return RGB(0x9A6773)
    case .deep: return RGB(0x5E7490)
    case .intimacy: return RGB(0xA56277)
    case .adventure: return RGB(0x448368)
    case .chill: return RGB(0x577F78)
    }
  }

  static func moodTint(_ mood: MoodKey) -> RGB {
    switch mood {
    case .fun: return RGB(0xF6E4C8)
    case .romance: return blush
    case .deep: return RGB(0xD7E2F2)
    case .intimacy: return RGB(0xF6D4DE)
    case .adventure: return RGB(0xD4E8DC)
    case .chill: return RGB(0xD3E6E1)
    }
  }

  static func moodTintDark(_ mood: MoodKey) -> RGB {
    switch mood {
    case .fun: return RGB(0x3A2A18)
    case .romance: return secondaryDark
    case .deep: return RGB(0x1C2838)
    case .intimacy: return RGB(0x3A2430)
    case .adventure: return RGB(0x1A3028)
    case .chill: return RGB(0x1A302C)
    }
  }

  static func contrast(_ a: RGB, _ b: RGB) -> Double {
    let left = a.luminance()
    let right = b.luminance()
    let lighter = max(left, right)
    let darker = min(left, right)
    return (lighter + 0.05) / (darker + 0.05)
  }
}
