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
  static let ivory = RGB(0xF6F0E6)

  static func contrast(_ a: RGB, _ b: RGB) -> Double {
    let left = a.luminance()
    let right = b.luminance()
    let lighter = max(left, right)
    let darker = min(left, right)
    return (lighter + 0.05) / (darker + 0.05)
  }
}
