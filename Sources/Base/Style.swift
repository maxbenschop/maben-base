import AppKit
import BaseCore
import SwiftUI

/// The Maben look, as in Maben Awake and Maben Sweep: near-black surfaces, hairline borders, text in three
/// strengths, and Base pink as the one accent (the main action and edited cells). Every colour has a light
/// and a dark value and follows the Appearance setting (View › Appearance).
enum MB {
    /// A colour that switches with the appearance.
    static func dyn(_ dark: NSColor, _ light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let nsBg = dyn(rgb(0x09090A), rgb(0xFFFFFF))
    static let nsSidebar = dyn(rgb(0x0E0E0F), rgb(0xF6F6F8))
    static let nsBar = dyn(rgb(0x0B0B0D), rgb(0xFAFAFB))
    static let nsCard = dyn(rgb(0x131316), rgb(0xF6F6F8))
    static let nsText = dyn(rgb(0xF5F5F5), rgb(0x111113))
    static let nsMuted = dyn(rgb(0xB3B3B3), rgb(0x45454D))
    static let nsDim = dyn(rgb(0x8C8C8C), rgb(0x6A6A73))
    static let nsLine = dyn(NSColor(white: 1, alpha: 0.075), NSColor(white: 0, alpha: 0.09))
    static let nsGrid = dyn(NSColor(white: 1, alpha: 0.06), NSColor(white: 0, alpha: 0.07))
    /// Base pink #FF5CA8 as a fill; a deeper pink where it's text or a thin mark on white.
    static let nsAccent = rgb(0xFF5CA8)
    static let nsAccentInk = dyn(rgb(0xFF5CA8), rgb(0xD81B72))
    static let nsRed = dyn(rgb(0xFF6B66), rgb(0xC9202C))
    static let nsGreen = dyn(rgb(0x30D158), rgb(0x0E7A4A))
    static let nsOrange = dyn(rgb(0xFF9F33), rgb(0x8F5A00))
    static let nsNull = dyn(NSColor(white: 1, alpha: 0.28), NSColor(white: 0, alpha: 0.3))
    static func nsWash(_ a: CGFloat) -> NSColor { dyn(NSColor(white: 1, alpha: a), NSColor(white: 0, alpha: a * 0.8)) }

    static let bg = Color(nsColor: nsBg)
    static let sidebar = Color(nsColor: nsSidebar)
    static let bar = Color(nsColor: nsBar)
    static let card = Color(nsColor: nsCard)
    static let hover = Color(nsColor: nsWash(0.05))
    static let selected = Color(nsColor: nsWash(0.09))
    static let line = Color(nsColor: nsLine)
    static let lineStrong = Color(nsColor: dyn(NSColor(white: 1, alpha: 0.14), NSColor(white: 0, alpha: 0.16)))
    static let text = Color(nsColor: nsText)
    static let muted = Color(nsColor: nsMuted)
    static let dim = Color(nsColor: nsDim)
    static let red = Color(nsColor: nsRed)
    static let green = Color(nsColor: nsGreen)
    static let orange = Color(nsColor: nsOrange)
    static let accent = Color(nsColor: nsAccent)
    static let accentInk = Color(nsColor: nsAccentInk)
    /// Behind overlays (palette, sheets of our own).
    static let scrim = Color(nsColor: dyn(NSColor(white: 0, alpha: 0.4), NSColor(white: 0, alpha: 0.18)))
    static func wash(_ a: CGFloat) -> Color { Color(nsColor: nsWash(a)) }
    static let radius: CGFloat = 10

    static let mono = Font.system(size: 12, design: .monospaced)
    static let nsMono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

/// System, Light or Dark, kept in UserDefaults.
enum Appearance: String, CaseIterable {
    case system, light, dark

    static var current: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
            newValue.apply()
        }
    }

    var title: String { rawValue.capitalized }

    func apply() {
        let a: NSAppearance? = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = a
        for w in NSApp.windows { w.appearance = a }
    }
}

extension ConnectionConfig.Environment {
    var color: Color {
        switch self {
        case .local: MB.dim
        case .development: MB.green
        case .staging: MB.orange
        case .production: MB.red
        }
    }
}

extension DatabaseKind {
    var symbol: String {
        switch self {
        case .postgres: "cylinder.split.1x2"
        case .mysql: "cylinder"
        case .sqlite, .duckdb: "doc"
        case .sqlserver, .oracle: "server.rack"
        case .clickhouse: "chart.bar.xaxis"
        case .libsql, .d1, .snowflake, .bigquery: "cloud"
        case .cassandra: "circle.hexagongrid"
        case .mongodb: "leaf"
        case .redis: "bolt"
        }
    }
}

/// Buttons: pink (the one action), quiet (secondary), danger.
struct MBButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, danger, plain }
    var kind: Kind = .quiet
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? Color.black : kind == .danger ? MB.red : MB.text)
            .padding(.horizontal, kind == .plain ? 6 : 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(kind == .primary ? MB.accent : kind == .plain ? MB.wash(configuration.isPressed ? 0.1 : 0)
                          : MB.wash(configuration.isPressed ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(kind == .primary || kind == .plain ? Color.clear : MB.line)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == MBButtonStyle {
    static var mbPrimary: MBButtonStyle { MBButtonStyle(kind: .primary) }
    static var mbQuiet: MBButtonStyle { MBButtonStyle(kind: .quiet) }
    static var mbDanger: MBButtonStyle { MBButtonStyle(kind: .danger) }
    static var mbPlain: MBButtonStyle { MBButtonStyle(kind: .plain) }
}

/// A square icon button for bars.
struct MBIconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? MB.accentInk : hovering ? MB.text : MB.muted)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? MB.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A text field in the Maben style.
struct MBField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? MB.mono : .system(size: 13))
        .foregroundStyle(MB.text)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
    }
}

struct MBSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MB.dim)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(MB.dim)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
    }

    @ViewBuilder private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(MB.text)
        if let focus { base.focused(focus) } else { base }
    }
}

/// A row of options, one selected.
struct MBSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var tint: (Value) -> Color? = { _ in nil }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = selection == option
                Button { selection = option } label: {
                    HStack(spacing: 5) {
                        if let t = tint(option) { Circle().fill(t).frame(width: 6, height: 6) }
                        Text(label(option))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .foregroundStyle(on ? MB.bg : MB.muted)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? MB.text : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MB.wash(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.line))
        .fixedSize()
    }
}

/// A small label pill, like a type name or "production".
struct MBTag: View {
    let text: String
    var color: Color = MB.dim

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct MBKey: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MB.muted)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(MB.wash(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(MB.line))
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(MB.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// The "maben base" lockup, to the brand rules: mark 0.72 em tall on the baseline, 0.28 em from the name.
struct MBWordmark: View {
    var size: CGFloat = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.28) {
            GateMark()
                .fill(MB.text)
                .frame(width: size * 0.72 * 68 / 58, height: size * 0.72)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
            HStack(alignment: .firstTextBaseline, spacing: size * 0.24) {
                Text("maben").font(.system(size: size, weight: .semibold)).tracking(size * 0.01)
                Text("base").font(.system(size: size, weight: .regular)).foregroundStyle(MB.dim)
            }
            .foregroundStyle(MB.text)
        }
        .fixedSize()
    }
}

/// The Maben Gate mark (brand/logo/maben-mark-black.svg, viewBox 16 22 68 58).
struct GateMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 68, sy = rect.height / 58
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 16) * sx, y: rect.minY + (y - 22) * sy) }
        var path = Path()
        path.move(to: p(16, 80))
        path.addLine(to: p(16, 46))
        path.addQuadCurve(to: p(40, 22), control: p(16, 22))
        path.addLine(to: p(60, 22))
        path.addQuadCurve(to: p(84, 46), control: p(84, 22))
        path.addLine(to: p(84, 80))
        for centre in [CGFloat(64), 36] {
            path.addLine(to: p(centre + 8, 80))
            path.addLine(to: p(centre + 8, 50))
            path.addArc(center: p(centre, 50), radius: 8 * sx, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
            path.addLine(to: p(centre - 8, 80))
        }
        path.closeSubpath()
        return path
    }
}

/// Window setup shared by all Maben Base windows: dark, no title text, content under the title bar.
func makeMabenWindow(size: NSSize, autosave: String, resizable: Bool = true) -> NSWindow {
    // Callers set content with setContent(_:size:) so SwiftUI doesn't shrink the window to fit.
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    if resizable { style.insert(.resizable) }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.backgroundColor = MB.nsBg
    return window
}

extension NSWindow {
    func setContent<V: View>(_ view: V, size: NSSize, autosave: String) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        contentViewController = host
        if !setFrameUsingName(autosave) {
            setContentSize(size)
            center()
        }
        setFrameAutosaveName(autosave)
    }
}

func showError(_ error: Error, in window: NSWindow?, title: String = "Something went wrong") {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}

/// Asks before something that can't be undone. Production connections always say so.
@MainActor
func confirm(_ title: String, detail: String, button: String, destructive: Bool = true, window: NSWindow?) async -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.alertStyle = destructive ? .critical : .warning
    let ok = alert.addButton(withTitle: button)
    ok.hasDestructiveAction = destructive
    alert.addButton(withTitle: "Cancel")
    guard let window else { return alert.runModal() == .alertFirstButtonReturn }
    return await withCheckedContinuation { cont in
        alert.beginSheetModal(for: window) { cont.resume(returning: $0 == .alertFirstButtonReturn) }
    }
}
