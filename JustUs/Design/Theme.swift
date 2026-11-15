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

  static func color(_ rgb: Palette.RGB) -> Color {
    Color(red: rgb.r, green: rgb.g, blue: rgb.b)
  }

  static let display = Font.system(.largeTitle, design: .serif)
  static let title = Font.system(.title2, design: .serif)
  static let body = Font.body
  static let caption = Font.subheadline

  enum Space {
    static let screen: CGFloat = 28
    static let section: CGFloat = 24
    static let stack: CGFloat = 12
    static let field: CGFloat = 6
  }
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
      .padding(Theme.Space.section)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
  }
}

struct HelperText: View {
  @Environment(\.colorScheme) private var scheme
  var text: String

  var body: some View {
    Text(text)
      .font(Theme.caption)
      .foregroundStyle(Theme.muted(scheme))
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct RoleLine: View {
  var waiting: Bool
  var text: String

  var body: some View {
    Text(text)
      .font(Theme.caption.weight(.semibold))
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(waiting ? Theme.champagne : Theme.blush, in: Capsule())
  }
}

enum JustButtonKind {
  case primary
  case secondary
  case link
  case destructive
}

struct JustButtonStyle: ButtonStyle {
  var kind: JustButtonKind
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed && enabled
    configuration.label
      .font(.body.weight(.semibold))
      .multilineTextAlignment(kind == .link ? .leading : .center)
      .foregroundStyle(foreground)
      .padding(.horizontal, kind == .link ? 2 : 16)
      .padding(.vertical, 12)
      .frame(maxWidth: kind == .link ? nil : .infinity, minHeight: 48, alignment: kind == .link ? .leading : .center)
      .background(background(pressed: pressed), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        if showsBorder {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(border(pressed: pressed), lineWidth: pressed ? 2 : 1.5)
        }
      }
      .underline(kind == .link && enabled)
      .contentShape(Rectangle())
      .scaleEffect(pressed && kind != .link ? 0.98 : 1)
      .animation(.easeOut(duration: 0.12), value: pressed)
  }

  private var showsBorder: Bool {
    kind == .destructive || (kind == .secondary && !enabled)
  }

  private var foreground: Color {
    if !enabled { return Theme.muted(scheme) }
    switch kind {
    case .primary:
      return Theme.canvas
    case .secondary:
      return scheme == .dark ? Theme.inkDark : Theme.ink
    case .link, .destructive:
      return scheme == .dark ? Theme.color(Palette.accentOnDark) : Theme.wine
    }
  }

  private func background(pressed: Bool) -> Color {
    if kind == .link {
      if !pressed || !enabled { return .clear }
      return scheme == .dark ? Theme.color(Palette.secondaryDark) : Theme.blush
    }
    if !enabled {
      return scheme == .dark ? Theme.color(Palette.disabledFillDark) : Theme.champagne
    }
    switch kind {
    case .primary:
      return pressed ? Theme.color(Palette.winePressed) : Theme.wine
    case .secondary:
      if scheme == .dark {
        return Theme.color(pressed ? Palette.secondaryDarkPressed : Palette.secondaryDark)
      }
      return pressed ? Theme.color(Palette.blushPressed) : Theme.blush
    case .destructive:
      guard pressed else { return .clear }
      return scheme == .dark ? Theme.color(Palette.secondaryDark) : Theme.blush
    case .link:
      return .clear
    }
  }

  private func border(pressed: Bool) -> Color {
    if !enabled { return Theme.muted(scheme) }
    if scheme == .dark { return Theme.color(Palette.accentOnDark) }
    return pressed ? Theme.color(Palette.winePressed) : Theme.wine
  }
}

struct WineButton: View {
  var title: String
  var identifier: String
  var busy: Bool = false
  var busyTitle: String?
  var action: () -> Void

  var body: some View {
    Button(action: {
      guard !busy else { return }
      Haptics.tap()
      action()
    }) {
      HStack(spacing: 10) {
        if busy {
          ProgressView()
            .controlSize(.small)
            .tint(Theme.canvas)
        }
        Text(label)
      }
    }
    .buttonStyle(JustButtonStyle(kind: .primary))
    .allowsHitTesting(!busy)
    .accessibilityIdentifier(identifier)
    .accessibilityLabel(label)
  }

  private var label: String { busy ? (busyTitle ?? L10n.loading) : title }
}

struct ActionButton: View {
  var title: String
  var identifier: String?
  var kind: JustButtonKind = .secondary
  var action: () -> Void

  var body: some View {
    Button(action: {
      Haptics.tap()
      action()
    }) {
      Text(title)
    }
    .buttonStyle(JustButtonStyle(kind: kind))
    .modifier(AccessIdentifier(identifier: identifier))
  }
}

private struct AccessIdentifier: ViewModifier {
  var identifier: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let identifier {
      content.accessibilityIdentifier(identifier)
    } else {
      content
    }
  }
}

struct AccentLink: View {
  var title: String
  var destination: URL

  var body: some View {
    Link(destination: destination) {
      Text(title)
    }
    .buttonStyle(JustButtonStyle(kind: .link))
  }
}

struct MoodChip: View {
  var mood: MoodKey
  var selected: Bool
  var enabled: Bool
  var action: () -> Void

  var body: some View {
    Button(action: {
      guard enabled else { return }
      Haptics.tap()
      action()
    }) {
      HStack(spacing: 8) {
        Text(L10n.moodName(mood))
        Spacer(minLength: 8)
        if selected {
          Image(systemName: "checkmark")
            .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(MoodChipStyle(mood: mood, selected: selected))
    .disabled(!enabled)
    .accessibilityIdentifier(A11y.mood(mood))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct MoodChipStyle: ButtonStyle {
  var mood: MoodKey
  var selected: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed && enabled
    configuration.label
      .font(.body.weight(selected ? .semibold : .regular))
      .foregroundStyle(foreground)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .background(fill(pressed: pressed), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(border, lineWidth: selected ? 2 : 1.5)
      }
      .scaleEffect(pressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.12), value: pressed)
  }

  private var foreground: Color {
    if !enabled { return Theme.muted(scheme) }
    if selected { return Theme.canvas }
    return scheme == .dark ? Theme.inkDark : Theme.ink
  }

  private func fill(pressed: Bool) -> Color {
    if !enabled { return scheme == .dark ? Theme.color(Palette.disabledFillDark) : Theme.champagne }
    if selected {
      return Theme.color(Palette.moodSelected(mood))
    }
    if scheme == .dark {
      return Theme.color(pressed ? Palette.secondaryDarkPressed : Palette.moodTintDark(mood))
    }
    return Theme.color(pressed ? Palette.blushPressed : Palette.moodTint(mood))
  }

  private var border: Color {
    if !enabled { return Theme.muted(scheme) }
    if scheme == .dark { return Theme.color(Palette.moodBorderDark(mood)) }
    return Theme.color(Palette.moodSelected(mood))
  }
}

struct StatusBanner: View {
  @Environment(\.colorScheme) private var scheme
  var message: String
  var identifier: String

  var body: some View {
    Text(message)
      .font(Theme.caption)
      .foregroundStyle(scheme == .dark ? Theme.canvas : Theme.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(scheme == .dark ? Theme.wine : Theme.blush, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityIdentifier(identifier)
  }
}

enum Haptics {
  static func tap() {
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
  }

  static func success() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }
}
