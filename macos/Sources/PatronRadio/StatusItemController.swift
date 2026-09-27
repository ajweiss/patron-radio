import AppKit
import PatronRadioCore
import SwiftUI

/// The menu bar item — the counterpart of the widget's CompactRepresentation.
/// Left click opens the popover, right click shows the actions menu, and
/// middle click toggles playback (as on the Plasma panel).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static let nameFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    static let subtitleFont = NSFont.systemFont(ofSize: 8.5)
    static let glyphWidth: CGFloat = 11
    static let padding: CGFloat = 4

    private let controller: RadioController
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var hostingView: NSHostingView<StatusItemLabel>?

    init(controller: RadioController, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.settings = settings
        self.openSettings = openSettings
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
            let host = PassthroughHostingView(rootView: StatusItemLabel(controller: controller, settings: settings))
            // The item width is set explicitly (statusItem.length); the label must not
            // push it wider through its intrinsic size (e.g. a long stream title).
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.padding),
                host.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.padding),
                host.topAnchor.constraint(equalTo: button.topAnchor),
                host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            hostingView = host
        }
        observeContinuously { [weak self] in self?.refresh() }
    }

    /// Width and tooltip follow state (the label itself is SwiftUI and updates itself).
    private func refresh() {
        statusItem.length = contentWidth() + Self.padding * 2
        statusItem.button?.toolTip = controller.statusTitle + "\n" + controller.statusDetail
        statusItem.button?.setAccessibilityLabel(controller.statusTitle)
    }

    /// Sizing modes from the widget: fixed, auto-fit station & city, auto-fit everything.
    private func contentWidth() -> CGFloat {
        if settings.menuBarStyle == .iconOnly { return 18 }
        func w(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) + 2 }
        switch settings.widthMode {
        case .fixed:
            return CGFloat(settings.fixedWidth)
        case .autoStationCity, .autoEverything:
            var fit = max(36, Self.glyphWidth + w(controller.currentStationName, Self.nameFont),
                          w(controller.currentStationCity, Self.subtitleFont))
            if settings.widthMode == .autoEverything && settings.subtitleMode != .city {
                fit = max(fit, w(controller.currentTrack, Self.subtitleFont))
            }
            return min(fit, 420)
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showMenu()
        case .otherMouseUp:
            controller.primaryAction()
        default:
            if event.modifierFlags.contains(.control) { showMenu() } else { togglePopover() }
        }
    }

    #if DEBUG
    var buttonForSnapshots: NSView? { statusItem.button }
    var requestedLengthForSnapshots: CGFloat { statusItem.length }
    #endif

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        let host = NSHostingController(rootView: PopoverView(
            controller: controller,
            openSettings: { [weak self] in self?.closePopover(); self?.openSettings() },
            close: { [weak self] in self?.closePopover() }))
        // Fixed size up front: letting the hosting controller resize the popover
        // after it's shown re-anchors it upward, pushing its top off the screen.
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 340, height: 480)
        NSApp.activate(ignoringOtherApps: true)
        // The status bar button is flipped, so its visual bottom edge is maxY there.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        popover.contentViewController = nil // drop the view tree (and its marquee timer) while hidden
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        let menu = MenuModel.nsMenu(MenuModel.entries(controller, openSettings: openSettings))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

/// Lets clicks fall through the SwiftUI label to the status bar button.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Two tiny lines, like the Plasma panel: a state glyph + station name in bold,
/// then the city / stream title (crawling when it doesn't fit).
struct StatusItemLabel: View {
    let controller: RadioController
    let settings: AppSettings

    var body: some View {
        Group {
            if settings.menuBarStyle == .iconOnly || controller.stations.isEmpty {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Two fixed-height lines (11 + 10 pt) so both fit a 22 pt menu bar.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 2) {
                        Image(systemName: glyphName)
                            .font(.system(size: 7, weight: .heavy))
                            .frame(width: StatusItemController.glyphWidth - 2)
                        Text(controller.currentStationName)
                            .font(Font(StatusItemController.nameFont))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Center the glyph on the capitals, not the whole line box
                            // (which includes descender space and reads as "too low").
                            .alignmentGuide(VerticalAlignment.center) { d in
                                d[.firstTextBaseline] - StatusItemController.nameFont.capHeight / 2
                            }
                    }
                    .frame(height: 11)
                    TimelineView(.periodic(from: .now, by: 15)) { ctx in
                        Marquee(text: subtitle(at: ctx.date), font: StatusItemController.subtitleFont,
                                color: Color(nsColor: .labelColor).opacity(0.75))
                    }
                    .frame(height: 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private var glyphName: String {
        switch controller.playbackState {
        case .broken: return "exclamationmark.triangle.fill"
        case .buffering, .fixing, .locating: return "arrow.triangle.2.circlepath"
        case .playing: return "play.fill"
        case .stopped: return "stop.fill"
        }
    }

    private var iconName: String {
        switch controller.playbackState {
        case .broken: return "exclamationmark.triangle"
        case .buffering, .fixing, .locating: return "antenna.radiowaves.left.and.right"
        case .playing: return "radio.fill"
        case .stopped: return "radio"
        }
    }

    private func subtitle(at date: Date) -> String {
        let city = controller.currentStationCity
        let track = controller.currentTrack.isEmpty ? city : controller.currentTrack
        switch settings.subtitleMode {
        case .city: return city
        case .track: return track
        case .alternate: return Int(date.timeIntervalSinceReferenceDate / 15) % 2 == 0 ? city : track
        }
    }
}
