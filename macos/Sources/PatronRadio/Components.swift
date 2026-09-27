import AppKit
import PatronRadioCore
import SwiftUI

/// The widget's station-type icons as SF Symbols; "mixed" is the same two-glyph
/// composite (mic bottom-left, note top-right) the widget draws.
struct StationIcon: View {
    let kind: StationKind?   // nil = the "Play Nearest Station" row
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch kind {
            case nil:
                Image(systemName: "location.fill").resizable().scaledToFit()
            case .music?:
                Image(systemName: "music.note").resizable().scaledToFit()
            case .talk?:
                Image(systemName: "mic.fill").resizable().scaledToFit()
            case .mixed?:
                ZStack {
                    Image(systemName: "mic.fill").resizable().scaledToFit()
                        .frame(width: size * 0.55, height: size * 0.55)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    Image(systemName: "music.note").resizable().scaledToFit()
                        .frame(width: size * 0.55, height: size * 0.55)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Crawls text that doesn't fit instead of eliding it: pause, scroll to the end
/// at ~50 pt/s, pause, snap back — the same rhythm as the widget's marquee.
/// The text is always laid out at its natural width; the container is measured
/// in the background, so layout never depends on a GeometryReader proposal.
///
/// The text gets a concrete color rather than a hierarchical style
/// (.secondary / opacity): on vibrant surfaces (menu bar, popover) SwiftUI draws
/// hierarchical styles with a vibrancy blend, and inside the clipped layer the
/// crawl needs that blend has nothing to composite against — the text vanishes.
struct Marquee: View {
    let text: String
    let font: NSFont
    var italic = false
    var color = Color(nsColor: .labelColor)

    @State private var startedAt = Date()
    @State private var containerWidth: CGFloat = 0

    private var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    private var lineHeight: CGFloat { ceil(font.ascender - font.descender) }

    var body: some View {
        let overflow = containerWidth > 0 ? textWidth - containerWidth : 0
        Group {
            if overflow <= 1 {
                label
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    label.offset(x: -offset(at: ctx.date.timeIntervalSince(startedAt), distance: overflow + 4))
                }
            }
        }
        // Ideal width 0: a marquee fills the width it is given and never asks for
        // more, so long text crawls instead of widening its container.
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, minHeight: lineHeight, maxHeight: lineHeight, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { containerWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in containerWidth = w }
        })
        .clipped()
        .onChange(of: text) { startedAt = Date() }
    }

    private var label: some View {
        Text(text)
            .font(Font(font))
            .italic(italic)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
    }

    private func offset(at t: TimeInterval, distance: CGFloat) -> CGFloat {
        let pause = 2.0, back = 0.6
        let scroll = max(1.5, Double(distance) * 0.02)
        let cycle = pause + scroll + pause + back
        let p = t.truncatingRemainder(dividingBy: cycle)
        if p < pause { return 0 }
        if p < pause + scroll { return distance * CGFloat((p - pause) / scroll) }
        if p < pause + scroll + pause { return distance }
        let x = (p - pause - scroll - pause) / back
        let eased = x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        return distance * CGFloat(1 - eased)
    }
}

/// One entry of the actions menu. The panel right-click menu and the popover's
/// overflow menu are both built from this list so they never drift apart
/// (the widget's ContextActions.qml plays the same role).
struct MenuEntry: Identifiable {
    enum Kind { case action, separator }
    let id = UUID()
    var kind = Kind.action
    var title = ""
    var symbol: String?
    var checked: Bool?
    var shortcut: String?
    var perform: () -> Void = {}

    static var separator: MenuEntry { MenuEntry(kind: .separator) }
}

@MainActor
enum MenuModel {
    static func entries(_ c: RadioController, openSettings: @escaping () -> Void) -> [MenuEntry] {
        var e: [MenuEntry] = []

        // 1. Playback / Fix
        e.append(MenuEntry(
            title: c.isBroken ? "Fix Broken Stream" : ((c.isPlaying || c.isBuffering) ? "Stop Playback" : "Start Playback"),
            symbol: c.isBroken ? "wrench.and.screwdriver" : ((c.isPlaying || c.isBuffering) ? "stop.fill" : "play.fill"),
            perform: { c.primaryAction() }))
        e.append(MenuEntry(title: "Play Nearest Station", symbol: "location", perform: { c.playClosestStation() }))
        e.append(.separator)

        // 2. Station links
        if !c.currentStationDonate.isEmpty {
            e.append(MenuEntry(title: "Support this Station (Donate)", symbol: "heart", perform: { c.openDonate() }))
        }
        if !c.currentStationWebsite.isEmpty {
            e.append(MenuEntry(title: "Station Website / Playlist", symbol: "music.note.list",
                               perform: { c.openExternal(c.currentStationWebsite) }))
        }
        e.append(.separator)

        // 3. Audio routing
        e.append(MenuEntry(title: "Automatic Routing (Priority List)", symbol: "arrow.triangle.branch",
                           checked: c.manualOutputUID == nil, perform: { c.selectAutomaticRouting() }))
        for d in c.outputs {
            let uid = d.uid
            e.append(MenuEntry(title: d.name, symbol: d.isBluetooth ? "headphones" : "hifispeaker",
                               checked: c.manualOutputUID == uid, perform: { c.selectOutput(uid: uid) }))
        }
        e.append(.separator)

        e.append(MenuEntry(title: "Settings…", symbol: "gearshape", shortcut: ",", perform: openSettings))
        e.append(MenuEntry(title: "Quit Patron Radio", symbol: "power", shortcut: "q",
                           perform: { NSApp.terminate(nil) }))
        return e
    }

    /// AppKit menu for the status item's right click.
    static func nsMenu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            if entry.kind == .separator {
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
                continue
            }
            let item = ClosureMenuItem(title: entry.title, keyEquivalent: entry.shortcut ?? "", action: entry.perform)
            if let s = entry.symbol { item.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
            if let checked = entry.checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}

/// Re-runs `apply` whenever any @Observable state it reads changes (for AppKit
/// objects that aren't SwiftUI views).
@MainActor
func observeContinuously(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        DispatchQueue.main.async { MainActor.assumeIsolated { observeContinuously(apply) } }
    }
}
