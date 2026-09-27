#if DEBUG
import AppKit
import PatronRadioCore
import SwiftUI

/// Debug aid: `PatronRadio --snapshots <dir>` renders the popover, menu bar
/// label and settings tabs to PNGs (useful on headless build machines).
@MainActor
enum Snapshots {
    static func run(into dir: URL, controller: RadioController, settings: AppSettings) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Real playback so the header shows a live title and the playing state.
        controller.playStation(0, reason: "snapshots")
        let deadline = Date().addingTimeInterval(8)
        while (controller.currentTrack.isEmpty || !controller.isPlaying) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            render(PopoverView(controller: controller, openSettings: {}, close: {}),
                   size: CGSize(width: 340, height: 480), appearance: appearance, to: dir.appendingPathComponent("popover-\(suffix).png"))
            render(StatusItemLabel(controller: controller, settings: settings).padding(.horizontal, 4)
                    .frame(width: 150, height: 24).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 150, height: 24), appearance: appearance, scale: 3,
                   to: dir.appendingPathComponent("menubar-\(suffix).png"))
        }
        for (i, name) in ["behavior", "loudness", "appearance", "stations", "about"].enumerated() {
            render(SettingsView(controller: controller, settings: settings, tab: i),
                   size: CGSize(width: 640, height: 560), appearance: .aqua, to: dir.appendingPathComponent("settings-\(name).png"))
        }
    }

    /// Opens the real status-item popover and captures its window (arrow, material and all).
    static func capturePopover(_ status: StatusItemController, to url: URL) {
        RunLoop.main.run(until: Date().addingTimeInterval(2)) // let the status item settle in the menu bar
        status.showPopover()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let window = NSApp.windows.first(where: { $0.className.contains("Popover") && $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSLog("no popover window"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        if let b = status.buttonForSnapshots, let r = b.bitmapImageRepForCachingDisplay(in: b.bounds) {
            b.cacheDisplay(in: b.bounds, to: r)
            try? r.representation(using: .png, properties: [:])?.write(to: url.deletingLastPathComponent().appendingPathComponent("real-button.png"))
            let onScreen = b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } ?? .zero
            NSLog("requested length \(status.requestedLengthForSnapshots)")
            NSLog("button frame \(b.frame) window \(b.window?.frame ?? .zero) onScreen \(onScreen) flipped \(b.isFlipped)")
        }
        NSLog("popover window frame \(window.frame) content \(window.contentView?.frame ?? .zero)")
    }

    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, scale: CGFloat = 2, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif
