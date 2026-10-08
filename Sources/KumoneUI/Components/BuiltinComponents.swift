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
        ComponentRegistry.register("Icon", builder: leaf.icon)
        ComponentRegistry.register("Container", builder: leaf.container)
        ComponentRegistry.register("SpectrumBars", builder: data.spectrumBars)
        ComponentRegistry.register("Button", builder: leaf.button)
        ComponentRegistry.register("ForEach", builder: leaf.forEach)
        ComponentRegistry.register("LyricView", builder: leaf.lyricView)
        ComponentRegistry.register("ProgressSlider", builder: leaf.progressSlider)
        ComponentRegistry.register("Artwork", builder: leaf.artwork)
    }
}

// MARK: - Prop helpers

extension Prop {
    public var numberValue: Double? { if case .number(let v) = self { return v } else { return nil } }
    public var flagValue: Bool? { if case .flag(let v) = self { return v } else { return nil } }
    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
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
                ? AnyView(HStack(alignment: hAlignment(alignment), spacing: spacing) { content }
                    .frame(maxWidth: .infinity, alignment: mainAxisPosition(alignment)))
                : AnyView(VStack(alignment: vAlignment(alignment), spacing: spacing) { content }
                    .frame(maxHeight: .infinity, alignment: mainAxisPosition(alignment)))
            return AnyView(group.padding(padding))
        }
    }

    /// The stack fills the space it is given; this decides where its
    /// children sit along the *main* axis (horizontal for HStack, vertical
    /// for VStack). The alignment prop already drives the cross axis —
    /// a centered transport row inside a left-aligned column now actually
    /// centres, where before it hugged the leading edge.
    private static func mainAxisPosition(_ name: String) -> Alignment {
        switch name {
        case "leading", "top": return .leading
        case "trailing", "bottom": return .trailing
        default: return .center
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

private func stringOf(_ prop: Prop) -> String? {
    switch prop {
    case .string(let s): return s
    case .number(let n): return String(n)
    case .flag(let b): return b ? "true" : "false"
    case .binding, .list, .mapping: return nil
    }
}

private enum leaf {
    static let icon: ComponentBuilder = { node, context in
        // SF Symbols by name — the one pictorial primitive. A config that
        // wants a play button writes `play.fill`, not a Unicode glyph that
        // stands in for one.
        let name = context.style["name"]?.stringValue ?? "music.note"
        let size = context.style["size"]?.numberValue ?? 16
        let weight = context.style["fontWeight"]?.stringValue ?? "regular"
        let colour = context.style["color"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
        return AnyView(IconView(name: name, fontSize: size, weight: weightOf(weight), tint: colour))
    }

    static let text: ComponentBuilder = { node, context in
        // ${...} bindings resolve here (inside the view's observation frame)
        // so a bound title/artist changes the text without re-rendering the
        // whole screen by hand.
        let text = context.resolve(context.style["text"] ?? .string(""))
            .flatMap { stringOf($0) } ?? ""
        let size = context.style["fontSize"]?.numberValue ?? 13
        let weight = context.style["fontWeight"]?.stringValue ?? "regular"
        let colour = context.style["color"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
        return AnyView(
            Text(text)
                .font(.system(size: size, weight: weightOf(weight)))
                .foregroundColor(colour)
        )
    }

    static let button: ComponentBuilder = { node, context in
        // The action name comes from props; the dispatcher comes from the
        // environment at body time. No name → disabled, not a crash, and no
        // dispatcher at all (no host) → disabled too: the screen still shows.
        // An `argument` rides along: a literal (`argument: mini`) or a
        // `${path}` — whatever the verb wants, e.g. which screen to open.
        let action = context.style["action"]?.stringValue
        let argument = context.style["argument"].flatMap { context.resolve($0) }
        let label = AnyView(
            VStack(spacing: 0) {
                ForEach(Array(context.children.indices), id: \.self) { index in
                    context.child(index)
                }
            })
        return AnyView(ActionButton(name: action, argument: argument, label: label))
    }

    static let forEach: ComponentBuilder = { node, context in
        // A collection consumed, not declared: `items` is a binding the app
        // resolves to a list (upcoming tracks, lyric lines); the first child
        // is the stamp repeated per item, and each stamp's `item.` bindings
        // see its own element through the scope the view below installs.
        // Non-list or unresolvable items render nothing — same never-crash
        // rule as an unknown component.
        let resolved = context.resolve(context.style["items"] ?? .list([]))
        let items: [Prop]
        if case .list(let values) = resolved { items = values } else { items = [] }
        let spacing = context.style["spacing"]?.numberValue ?? 8
        let template = context.children.first
            ?? Node(type: "Text", props: ["text": .string("")])
        return AnyView(ForEachItems(
            items: items, template: template, stylesheet: context.stylesheet, spacing: spacing))
    }

    /// The first *composite* component: a column of lyric lines with the
    /// current one highlighted and kept centered. Could a screen express
    /// this from atoms? No — "is this row current" is a comparison, and
    /// there is no expression language by design. The registry does not
    /// care: a component may be config composed of children (a VStack) or
    /// a view composed in Swift (this), exactly as plugins will be.
    static let lyricView: ComponentBuilder = { node, context in
        let lines: [String]
        if case .list(let values) = context.resolve(context.style["lines"] ?? .list([])) {
            lines = values.compactMap(stringOf)
        } else {
            lines = []
        }
        let cursor = context.resolve(context.style["currentIndex"] ?? .number(-1))
            .flatMap { $0.numberValue }.map(Int.init) ?? -1
        let size = context.style["fontSize"]?.numberValue ?? 14
        let active = context.style["activeColor"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
            ?? Color.primary
        let inactive = context.style["inactiveColor"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
            ?? Color.secondary
        let placeholder = context.resolve(context.style["placeholder"] ?? .string(""))
            .flatMap { stringOf($0) } ?? ""
        let leading = (context.style["alignment"]?.stringValue ?? "center") == "leading"
        return AnyView(LyricView(
            lines: lines, cursor: cursor, fontSize: size, active: active,
            inactive: inactive, placeholder: placeholder, leading: leading))
    }

    static let progressSlider: ComponentBuilder = { node, context in
        // The first bidirectional component: reads where playback is, and
        // on release sends the position the user chose as the argument of a
        // named action (`player.seek`). Bindings resolve here (inside the
        // observation frame) so the track position follows the music.
        let value = context.resolve(context.style["value"] ?? .number(0))?.numberValue ?? 0
        let duration = context.resolve(context.style["duration"] ?? .number(0))?.numberValue ?? 0
        let action = context.style["action"]?.stringValue
        let colour = context.style["color"].flatMap { $0.stringValue }.flatMap(StyleColor.parse)
        return AnyView(ProgressSlider(
            value: value, duration: duration, action: action, tint: colour))
    }

    static let artwork: ComponentBuilder = { node, context in
        // Album art from a bound URL — the component knows nothing about
        // where the URL came from, only that a string arrived.
        let urlString = context.resolve(context.style["url"] ?? .string(""))?.stringValue ?? ""
        let size = context.style["size"]?.numberValue ?? 64
        let corner = context.style["cornerRadius"]?.numberValue ?? 8
        return AnyView(ArtworkView(url: urlString, side: size, cornerRadius: corner))
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

/// The interactive primitive: a SwiftUI button that sends a *named* action
/// through the environment's dispatcher.
///
/// Kept as a View (not a closure) because it needs the environment; the
/// builder wraps it in AnyView. Its label is whatever children the screen
/// put inside it, so a button is composable like everything else.
struct ActionButton: View {
    let name: String?
    /// An argument the verb takes: a screen name for `app.presentScreen`,
    /// nil for verbs that need nothing. Carried as a prop, not unpacked,
    /// so the verb decides what it means.
    let argument: Prop?
    let label: AnyView
    @Environment(\.actionDispatcher) private var dispatcher

    var body: some View {
        Button(action: send) {
            label
                // A fingertip-sized target matters more than a tight glyph
                // frame: the hit area stays 12pt larger than the icon.
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(name == nil || dispatcher == nil)
    }

    private func send() {
        guard let name else { return }
        // Unknown action names are surfaced by returning false; the log is
        // the only place that says so, so a typo'd action still renders.
        guard dispatcher?.invoke(name, with: argument) == true else {
            #if DEBUG
            print("[KumoneUI] unknown action: \(name)")
            #endif
            return
        }
    }
}

/// A pictogram: one SF Symbol by name, sized and coloured like text.
/// Configs reach for it instead of pasting a Unicode glyph that only
/// pretends to be an icon.
struct IconView: View {
    let name: String
    let fontSize: Double
    let weight: Font.Weight
    let tint: Color?

    var body: some View {
        Image(systemName: name)
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(tint ?? .primary)
    }
}

/// The seek control: bound to position and length, it memorises the drag
/// while the user holds it (so the music's own progress does not fight the
/// finger) and commits the final position as the argument of the named
/// action on release.
struct ProgressSlider: View {
    let value: Double
    let duration: Double
    let action: String?
    let tint: Color?
    @Environment(\.actionDispatcher) private var dispatcher
    @State private var dragged: Double?

    var body: some View {
        let display = dragged ?? value
        Slider(
            value: Binding(get: { display }, set: { dragged = $0 }),
            in: 0...(max(duration, 0.001)),
            onEditingChanged: commit
        )
        .tint(tint)
        // Nothing to seek (no track, or duration unknown) or nobody to tell
        // — inert instead of broken, same rule as the button.
        .disabled(duration <= 0 || action == nil || dispatcher == nil)
    }

    private func commit(editing: Bool) {
        guard !editing, let final = dragged, let action else { return }
        dragged = nil
        guard let dispatcher, dispatcher.invoke(action, with: .number(final)) else {
            #if DEBUG
            print("[KumoneUI] unknown action: \(action)")
            #endif
            return
        }
    }
}

/// Album art: a remote URL when the track has one, a quiet placeholder when
/// it does not (or while the image loads).
struct ArtworkView: View {
    let url: String
    let side: Double
    let cornerRadius: Double

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder
            case .empty:
                placeholder
            @unknown default:
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary))
    }
}

/// The collection renderer: repeats one template node per element of a
/// list, and for each copy overrides the resolver with a scope where `item`
/// is that element. Everything outside `item.` still talks to the app's
/// real state, so a row can show the queued title and the now-playing
/// indicator in the same view.
struct ForEachItems: View {
    let items: [Prop]
    let template: Node
    let stylesheet: Stylesheet
    let spacing: Double
    @Environment(\.bindingResolver) private var base

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(items.indices, id: \.self) { index in
                NodeView(node: template, stylesheet: stylesheet)
                    .environment(\.bindingResolver,
                                 ScopedResolver(base: base, item: items[index]))
            }
        }
    }
}

/// A full lyric sheet: every line, the current one highlighted and held at
/// the middle of the view. The cursor arrives as an index from a binding
/// (`lyrics.currentIndex`), so which line is current is the app's truth —
/// the component only renders the consequence.
struct LyricView: View {
    let lines: [String]
    /// Index of the live line; -1 (or out of range) highlights nothing,
    /// which is the state before the first word and after the last.
    let cursor: Int
    let fontSize: Double
    let active: Color
    let inactive: Color
    let placeholder: String
    let leading: Bool

    var body: some View {
        if lines.isEmpty {
            Text(placeholder.isEmpty ? "No lyrics" : placeholder)
                .font(.system(size: fontSize))
                .foregroundStyle(inactive)
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: leading ? .leading : .center, spacing: 10) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index])
                                .font(.system(size: fontSize))
                                .foregroundStyle(index == cursor ? active : inactive)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 120)  // room so the active line centers
                }
                .onAppear { scrollToCursor(proxy) }
                .onChange(of: cursor) { _ in scrollToCursor(proxy) }
            }
        }
    }

    private func scrollToCursor(_ proxy: ScrollViewProxy) {
        guard lines.indices.contains(cursor) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(cursor, anchor: .center)
        }
    }
}
