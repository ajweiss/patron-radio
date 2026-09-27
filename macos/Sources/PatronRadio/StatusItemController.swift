import AppKit
import PatronRadioCore
import SwiftUI

/// The menu bar item — the counterpart of the widget's CompactRepresentation.
/// Left click opens the popover, right click shows the actions menu, and
/// middle click toggles playback (as on the Plasma panel).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static let padding: CGFloat = 4

    private let controller: RadioController
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let label = StatusLabelView()

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
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.padding),
                label.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.padding),
                label.topAnchor.constraint(equalTo: button.topAnchor),
                label.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        observeContinuously { [weak self] in self?.refresh() }
    }

    /// Label content, width and tooltip follow state.
    private func refresh() {
        label.content = labelContent()
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
            var fit = max(36, StatusLabelView.glyphWidth + w(controller.currentStationName, StatusLabelView.nameFont),
                          w(controller.currentStationCity, StatusLabelView.subtitleFont))
            if settings.widthMode == .autoEverything && settings.subtitleMode != .city {
                fit = max(fit, w(controller.currentTrack, StatusLabelView.subtitleFont))
            }
            return min(fit, 420)
        }
    }

    private func labelContent() -> StatusLabelView.Content {
        var c = StatusLabelView.Content()
        let state = controller.playbackState
        c.iconOnly = settings.menuBarStyle == .iconOnly || controller.stations.isEmpty
        switch state {
        case .broken: c.symbol = "exclamationmark.triangle"; c.glyph = "exclamationmark.triangle.fill"
        case .buffering, .fixing, .locating: c.symbol = "antenna.radiowaves.left.and.right"; c.glyph = "arrow.triangle.2.circlepath"
        case .playing: c.symbol = "radio.fill"; c.glyph = "play.fill"
        case .stopped: c.symbol = "radio"; c.glyph = "stop.fill"
        }
        c.name = controller.currentStationName
        let city = controller.currentStationCity
        let track = controller.currentTrack.isEmpty ? city : controller.currentTrack
        switch settings.subtitleMode {
        case .city: c.subtitles = [city]
        case .track: c.subtitles = [track]
        case .alternate: c.subtitles = track == city ? [city] : [city, track]
        }
        return c
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
