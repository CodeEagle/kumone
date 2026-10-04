import KumoneCore
import SwiftUI

/// Built-in components: the layout primitives every screen needs plus the
/// first real data component.
///
/// Registration is exactly the same call a plugin makes — the engine treats
/// `HStack` and a user's `plugin.Thing` identically. Call
/// `registerBuiltinComponents()` once at app startup (before any screen
/// renders).
public enum BuiltinComponents {
    public static func register() {
        ComponentRegistry.register("HStack", builder: layouts.stack(axis: .horizontal))
        ComponentRegistry.register("VStack", builder: layouts.stack(axis: .vertical))
        ComponentRegistry.register("ZStack", builder: layouts.zstack)
        ComponentRegistry.register("Spacer", builder: layouts.spacer)
        ComponentRegistry.register("Text", builder: leaf.text)
        ComponentRegistry.register("Container", builder: leaf.container)
        ComponentRegistry.register("SpectrumBars", builder: data.spectrumBars)
    }
}

// MARK: - Prop helpers

extension Prop {
    var numberValue: Double? { if case .number(let v) = self { return v } else { return nil } }
    var flagValue: Bool? { if case .flag(let v) = self { return v } else { return nil } }
    var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
}

/// `#RRGGBB` / named-colour parsing shared by every component that paints.
public enum StyleColor {
    static func parse(_ string: String) -> Color? {
        let hex = string.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: String(hex.dropFirst())).scanHexInt64(&value) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Layout primitives

private enum layouts {
    static func stack(axis: Axis) -> ComponentBuilder {
        { node, context in
            let spacing = context.style["spacing"]?.numberValue ?? 8
            let alignment = (context.style["alignment"]?.stringValue ?? "center")
            let padding = context.style["padding"]?.numberValue ?? 0
            let content = ForEach(Array(context.children.indices), id: \.self) { index in
                context.child(index)
            }
            let group = axis == .horizontal
                ? AnyView(HStack(alignment: hAlignment(alignment), spacing: spacing) { content })
                : AnyView(VStack(alignment: vAlignment(alignment), spacing: spacing) { content })
            return AnyView(group.padding(padding))
        }
    }

    static let zstack: ComponentBuilder = { node, context in
        AnyView(ZStack {
            ForEach(Array(context.children.indices), id: \.self) { index in
                context.child(index)
            }
        })
    }

    static let spacer: ComponentBuilder = { node, context in
        let minLength = context.style["minLength"]?.numberValue
        return AnyView(Spacer(minLength: minLength.map { CGFloat($0) } ?? 0))
    }

    private static func hAlignment(_ name: String) -> VerticalAlignment {
        switch name {
        case "top": return .top
        case "bottom": return .bottom
        case "center", "middle": return .center
        case "firstTextBaseline": return .firstTextBaseline
        case "lastTextBaseline": return .lastTextBaseline
        default: return .center
        }
    }

    private static func vAlignment(_ name: String) -> HorizontalAlignment {
        switch name {
        case "leading": return .leading
        case "trailing": return .trailing
        case "center": return .center
        default: return .center
        }
    }
}

// MARK: - Leaf views

private enum leaf {
    static let text: ComponentBuilder = { node, context in
        let text = context.style["text"]?.stringValue ?? ""
        let size = context.style["fontSize"]?.numberValue ?? 13
        let weight = context.style["fontWeight"]?.stringValue ?? "regular"
        let colour = context.style["color"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
        return AnyView(
            Text(text)
                .font(.system(size: size, weight: weightOf(weight)))
                .foregroundColor(colour)
        )
    }

    static let container: ComponentBuilder = { node, context in
        let corner = context.style["cornerRadius"]?.numberValue ?? 0
        let padding = context.style["padding"]?.numberValue ?? 0
        let fill = context.style["background"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
        return AnyView(
            RoundedRectangle(cornerRadius: corner)
                .fill(fill ?? Color.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    VStack(spacing: 0) {
                        ForEach(Array(context.children.indices), id: \.self) { index in
                            context.child(index)
                        }
                    }
                    .padding(padding)
                }
        )
    }

    private static func weightOf(_ name: String) -> Font.Weight {
        switch name {
        case "bold": return .bold
        case "semibold": return .semibold
        case "light": return .light
        case "thin": return .thin
        default: return .regular
        }
    }
}

// MARK: - Real data: the audio spectrum

private enum data {
    /// The first component that proves the wiring: a live spectrum driven by
    /// the shared `AudioSpectrum`, the same source the shaders read. A config
    /// screen that moves with the music is a config screen that is alive.
    static let spectrumBars: ComponentBuilder = { node, context in
        let height = context.style["barHeight"]?.numberValue ?? 20
        let width = context.style["barWidth"]?.numberValue ?? 4
        let spacing = context.style["spacing"]?.numberValue ?? 6
        let colour = context.style["color"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
            ?? Color.accentColor
        return AnyView(
            TimelineView(.animation) { _ in
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<AudioSpectrum.bandCount, id: \.self) { band in
                        Capsule()
                            .fill(colour)
                            .frame(width: width,
                                   height: max(2, height * CGFloat(AudioSpectrum.shared.level(at: band))))
                    }
                }
            }
        )
    }
}
