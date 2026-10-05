import SwiftUI
import UIKit

/// Shared visual language for the app, App Clip and iMessage extension.
enum CSTheme {
  // MARK: Colors

  static let background = Color(red: 0.045, green: 0.047, blue: 0.043)
  static let backgroundRaised = Color(red: 0.072, green: 0.078, blue: 0.072)
  static let ink = Color(red: 0.965, green: 0.965, blue: 0.92)
  static let inkSecondary = Color.white.opacity(0.58)
  static let inkTertiary = Color.white.opacity(0.42)
  static let accent = Color(red: 0.48, green: 1.0, blue: 0.70)
  static let accentDeep = Color(red: 0.22, green: 0.78, blue: 0.52)
  static let accentInk = Color(red: 0.035, green: 0.06, blue: 0.045)
  static let info = Color(red: 0.84, green: 0.92, blue: 1.0)
  static let warning = Color(red: 1.0, green: 0.68, blue: 0.38)
  static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)
  static let success = Color(red: 0.50, green: 0.92, blue: 0.68)

  static let surface = Color.white.opacity(0.055)
  static let surfaceField = Color.white.opacity(0.065)
  static let stroke = Color.white.opacity(0.09)
  static let strokeStrong = Color.white.opacity(0.14)

  // MARK: Shape

  static let cornerRadius: CGFloat = 14
  static let smallCornerRadius: CGFloat = 10

  static func card(_ radius: CGFloat = cornerRadius) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
  }

  // MARK: Type

  static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .rounded)
  }

  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }
}

/// App backdrop: near-black with a faint mint bloom at the top so the
/// screen reads as "lit from the reveal zone" without competing with content.
struct CSBackground: View {
  var body: some View {
    ZStack {
      CSTheme.background

      RadialGradient(
        colors: [CSTheme.accent.opacity(0.10), CSTheme.accent.opacity(0)],
        center: .init(x: 0.5, y: -0.08),
        startRadius: 0,
        endRadius: 420
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}

struct CSCardModifier: ViewModifier {
  var padding: CGFloat = 16
  var fill: Color = CSTheme.surface

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background(fill, in: CSTheme.card())
      .overlay(
        CSTheme.card()
          .strokeBorder(
            LinearGradient(
              colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 1
          )
      )
  }
}

extension View {
  func csCard(padding: CGFloat = 16, fill: Color = CSTheme.surface) -> some View {
    modifier(CSCardModifier(padding: padding, fill: fill))
  }

  func csField() -> some View {
    background(CSTheme.surfaceField, in: CSTheme.card(CSTheme.smallCornerRadius + 2))
      .overlay(CSTheme.card(CSTheme.smallCornerRadius + 2).strokeBorder(CSTheme.stroke, lineWidth: 1))
  }
}

/// Circular glass button used for close / info / toggles in headers.
struct CSIconButtonLabel: View {
  let systemImage: String
  var size: CGFloat = 40
  var tint: Color = CSTheme.ink

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: size * 0.4, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(Color.white.opacity(0.08), in: Circle())
      .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
      .contentShape(Circle())
  }
}

struct CSPressableButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

/// Cached feedback generators. Creating a generator per tap allocates and
/// spins up the Taptic Engine each time, which is both slower and less crisp.
@MainActor
enum CSHaptics {
  private static let soft = UIImpactFeedbackGenerator(style: .soft)
  private static let light = UIImpactFeedbackGenerator(style: .light)
  private static let notification = UINotificationFeedbackGenerator()
  private static let selectionGenerator = UISelectionFeedbackGenerator()

  static func tap(_ intensity: CGFloat = 0.35) {
    soft.impactOccurred(intensity: intensity)
  }

  static func tick(_ intensity: CGFloat = 0.34) {
    light.impactOccurred(intensity: intensity)
  }

  static func selection() {
    selectionGenerator.selectionChanged()
  }

  static func success() {
    notification.notificationOccurred(.success)
  }

  static func warning() {
    notification.notificationOccurred(.warning)
  }

  static func prepare() {
    soft.prepare()
    light.prepare()
  }
}
