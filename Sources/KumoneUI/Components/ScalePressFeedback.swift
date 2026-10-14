import SwiftUI

/// Scale the rendered content while keeping its layout and hit frame stable.
/// Card hero anchors and configuration-driven buttons share this feedback.
public struct ScalePressFeedback: ViewModifier {
    private let isPressed: Bool
    private let pressedScale: CGFloat

    public init(isPressed: Bool, pressedScale: CGFloat = 0.97) {
        self.isPressed = isPressed
        self.pressedScale = pressedScale
    }

    public func body(content: Content) -> some View {
        content
            .visualEffect { effect, _ in
                effect.scaleEffect(isPressed ? pressedScale : 1)
            }
            .animation(.spring(response: 0.18, dampingFraction: 1), value: isPressed)
    }
}

public struct ScalePressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ScalePressFeedback(isPressed: configuration.isPressed))
    }
}
