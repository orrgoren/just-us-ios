import SwiftUI

enum Theme {
  static let canvas = Color(red: 246 / 255, green: 240 / 255, blue: 230 / 255)
  static let canvasDark = Color(red: 26 / 255, green: 20 / 255, blue: 18 / 255)
  static let ink = Color(red: 44 / 255, green: 33 / 255, blue: 28 / 255)
  static let inkDark = Color(red: 246 / 255, green: 239 / 255, blue: 232 / 255)
  static let muted = Color(red: 94 / 255, green: 83 / 255, blue: 74 / 255)
  static let mutedDark = Color(red: 210 / 255, green: 195 / 255, blue: 182 / 255)
  static let wine = Color(red: 110 / 255, green: 36 / 255, blue: 54 / 255)
  static let blush = Color(red: 243 / 255, green: 217 / 255, blue: 210 / 255)
  static let champagne = Color(red: 232 / 255, green: 214 / 255, blue: 184 / 255)

  static func canvas(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? canvasDark : canvas
  }

  static func ink(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? inkDark : ink
  }

  static func muted(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? mutedDark : muted
  }

  static let display = Font.system(.largeTitle, design: .serif)
  static let title = Font.system(.title2, design: .serif)
  static let body = Font.body
  static let caption = Font.subheadline
}

struct JustScreen<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ZStack {
      Theme.canvas(scheme).ignoresSafeArea()
      content
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .foregroundStyle(Theme.ink(scheme))
    .animation(reduceMotion ? nil : .spring(duration: 0.35), value: scheme)
  }
}

struct Wordmark: View {
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "heart")
        .font(.caption)
        .foregroundStyle(Theme.wine)
        .accessibilityHidden(true)
      Text(L10n.wordmark)
        .font(Theme.title)
      Image(systemName: "circle")
        .font(.caption2)
        .foregroundStyle(Theme.champagne)
        .accessibilityHidden(true)
    }
  }
}

struct MonogramView: View {
  var names: [String]

  var body: some View {
    Text(letters)
      .font(Theme.title)
      .foregroundStyle(Theme.wine)
      .frame(width: 72, height: 72)
      .background(Theme.blush, in: Circle())
      .accessibilityLabel(L10n.monogram)
  }

  private var letters: String {
    let marks = names.compactMap { name -> String? in
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let first = trimmed.first else { return nil }
      return String(first).uppercased()
    }
    return marks.prefix(2).joined()
  }
}

struct GlassCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
  }
}

struct WineButton: View {
  var title: String
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.body.weight(.semibold))
        .foregroundStyle(Theme.canvas)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(Theme.wine, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .accessibilityIdentifier(identifier)
    .buttonStyle(.plain)
  }
}

struct StatusBanner: View {
  var message: String
  var identifier: String

  var body: some View {
    Text(message)
      .font(Theme.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(Theme.blush, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityIdentifier(identifier)
  }
}

enum Haptics {
  static func tap() {
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
  }
}
