import KumoneCore
import KumoneUI
import SwiftUI

private struct CardPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isCardPressed: Bool {
        get { self[CardPressedKey.self] }
        set { self[CardPressedKey.self] = newValue }
    }
}

struct CardEnvironmentPressFeedback: ViewModifier {
    @Environment(\.isCardPressed) private var isPressed

    func body(content: Content) -> some View {
        content.modifier(ScalePressFeedback(isPressed: isPressed))
    }
}

struct ScaleCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.isCardPressed, configuration.isPressed)
    }
}

extension ButtonStyle where Self == ScaleCardButtonStyle {
    static var scaleCard: ScaleCardButtonStyle { ScaleCardButtonStyle() }
}

/// Cards that scale up on hover, scale down on press, with a soft shadow.
struct InteractiveCardStyle: ButtonStyle {
    var showShadow = true
    var hoverScale: CGFloat = 1.02
    var pressScale: CGFloat = 0.97

    #if os(macOS)
    @State private var isHovering = false
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .visualEffect { effect, _ in
                effect.scaleEffect(configuration.isPressed ? pressScale : (isHovering ? hoverScale : 1.0))
            }
            .shadow(
                color: showShadow && isHovering ? .black.opacity(0.15) : .clear,
                radius: isHovering ? 12 : 0,
                x: 0,
                y: isHovering ? 4 : 0
            )
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
            .animation(AppAnimation.spring, value: isHovering)
            .onHover { isHovering = $0 }
        #else
        configuration.label
            .modifier(ScalePressFeedback(isPressed: configuration.isPressed, pressedScale: pressScale))
        #endif
    }
}

/// List rows with a hover background highlight.
struct InteractiveRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.Radius.standard
    var hoverColor: Color = .primary.opacity(0.06)

    #if os(macOS)
    @State private var isHovering = false
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? hoverColor : .clear)
            )
            .modifier(ScalePressFeedback(isPressed: configuration.isPressed))
            .animation(AppAnimation.quick, value: isHovering)
            .onHover { isHovering = $0 }
        #else
        configuration.label
            .modifier(ScalePressFeedback(isPressed: configuration.isPressed))
        #endif
    }
}

/// Subtle press feedback for icon buttons.
struct PressableButtonStyle: ButtonStyle {
    var pressScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ScalePressFeedback(isPressed: configuration.isPressed, pressedScale: pressScale))
    }
}

/// Filter chips (category pickers).
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    #if os(macOS)
    @State private var isHovering = false
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(.primary.opacity(isHovering ? 0.1 : 0.06))
                )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : (isHovering ? 1.03 : 1.0))
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: isHovering)
            .onHover { isHovering = $0 }
        #else
        configuration.label
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(.primary.opacity(0.06))
                )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(AppAnimation.spring, value: configuration.isPressed)
        #endif
    }
}

extension ButtonStyle where Self == InteractiveCardStyle {
    static var interactiveCard: InteractiveCardStyle { InteractiveCardStyle() }
}

extension ButtonStyle where Self == InteractiveRowStyle {
    static var interactiveRow: InteractiveRowStyle { InteractiveRowStyle() }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    /// A replacement for native plain-button dimming on text and list actions.
    static var scalePress: PressableButtonStyle { PressableButtonStyle(pressScale: 0.97) }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static func chip(isSelected: Bool) -> ChipButtonStyle { ChipButtonStyle(isSelected: isSelected) }
}
