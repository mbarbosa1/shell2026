import SwiftUI

/// Colors sampled from the Figma frames (dark indigo + lavender).
enum Theme {
    static let background = Color(hex: 0x15111F)
    static let card = Color(hex: 0x211B2F)
    static let cardRaised = Color(hex: 0x2A2340)
    static let lavender = Color(hex: 0xC7B2FF)
    static let onLavender = Color(hex: 0x1B1530)
    static let accentText = Color(hex: 0xB79CFF)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xA7A0B8)
    static let success = Color(hex: 0x9BE3B5)
    static let hairline = Color.white.opacity(0.08)
    static let glowViolet = Color(hex: 0xA07BFF)
    static let glowBlue = Color(hex: 0x6E8BFF)

    static let cardRadius: CGFloat = 16
    static let controlHeight: CGFloat = 56
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.onLavender)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background(Theme.lavender, in: .rect(cornerRadius: Theme.cardRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background(Theme.cardRaised, in: .rect(cornerRadius: Theme.cardRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: Cards

extension View {
    func cardStyle(highlighted: Bool = false) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Theme.cardRaised : Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(highlighted ? Theme.accentText : .clear, lineWidth: 1)
            }
    }

    /// Soft violet/blue glow around the screen edge while the microphone is live.
    func listeningGlow(_ isActive: Bool) -> some View {
        modifier(ListeningGlow(isActive: isActive))
    }
}

// MARK: Listening glow

struct ListeningGlow: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                let gradient = AngularGradient(
                    colors: [Theme.glowViolet, Theme.glowBlue, Theme.glowViolet, Theme.glowBlue, Theme.glowViolet],
                    center: .center
                )
                ZStack {
                    RoundedRectangle(cornerRadius: 55, style: .continuous)
                        .strokeBorder(gradient, lineWidth: 10)
                        .blur(radius: 12)
                    RoundedRectangle(cornerRadius: 55, style: .continuous)
                        .strokeBorder(gradient, lineWidth: 2)
                }
                .opacity(pulse ? 1 : 0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
                .onAppear {
                    guard !reduceMotion else { pulse = true; return }
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}
