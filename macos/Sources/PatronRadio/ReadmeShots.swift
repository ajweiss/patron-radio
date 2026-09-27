#if DEBUG
import AppKit
import PatronRadioCore
import SwiftUI

/// Debug aid: `PatronRadio --readme-shots <dir>` renders the screenshots used in
/// macos/README.md. The real status-item label, popover and settings views are
/// drawn live (playing a real station), composed on a plain desktop the way they
/// appear on screen — needed because headless build machines can't screencapture.
@MainActor
enum ReadmeShots {
    static func run(into dir: URL, controller: RadioController, settings: AppSettings) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        controller.playStation(0, reason: "readme screenshots")
        let deadline = Date().addingTimeInterval(10)
        while (controller.currentTrack.isEmpty || !controller.isPlaying) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            Snapshots.render(Hero(controller: controller, settings: settings),
                             size: Hero.size, appearance: appearance,
                             to: dir.appendingPathComponent("popover-\(suffix).png"))
        }
        for (tab, name) in [(3, "stations"), (0, "behavior")] {
            Snapshots.render(WindowFrame(title: "Patron Radio Settings") {
                SettingsView(controller: controller, settings: settings, tab: tab)
            }, size: windowSize(for: CGSize(width: 640, height: 560)), appearance: .aqua,
               to: dir.appendingPathComponent("settings-\(name).png"))
        }
    }

    /// A strip of menu bar with the status item "open", and the popover under it.
    struct Hero: View {
        static let size = CGSize(width: 470, height: 540)
        let controller: RadioController
        let settings: AppSettings
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let itemWidth = StatusItemController.contentWidth(controller: controller, settings: settings)
                + StatusItemController.padding * 2
            let itemX: CGFloat = 200 // leading edge of the status item
            ZStack(alignment: .topLeading) {
                Desktop()
                // Menu bar
                HStack(spacing: 0) {
                    Image(systemName: "applelogo").font(.system(size: 13, weight: .medium)).padding(.leading, 14)
                    Spacer()
                }
                .frame(width: Self.size.width, height: 24)
                .background(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
                StatusItemLabel(controller: controller, settings: settings)
                    .padding(.horizontal, StatusItemController.padding)
                    .frame(width: itemWidth, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.13)))
                    .offset(x: itemX, y: 1)
                HStack(spacing: 14) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("Sat 9:41")
                }
                .font(.system(size: 12, weight: .medium))
                .frame(height: 24)
                .offset(x: itemX + itemWidth + 16)
                // Popover, centered under the status item
                PopoverView(controller: controller, openSettings: {}, close: {})
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .offset(x: itemX + itemWidth / 2 - 170, y: 34)
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    /// Content plus the title bar (28 pt) and the desktop margin (30 pt each side).
    static func windowSize(for content: CGSize) -> CGSize {
        CGSize(width: content.width + 60, height: content.height + 28 + 60)
    }

    /// A plain window chrome (traffic lights + title) around content.
    struct WindowFrame<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        var body: some View {
            ZStack {
                Desktop()
                VStack(spacing: 0) {
                    ZStack {
                        HStack(spacing: 8) {
                            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                            Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                            Spacer()
                        }
                        .padding(.leading, 12)
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .frame(height: 28)
                    content
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .padding(30)
            }
        }
    }

    /// A soft, neutral desktop so the UI reads in both appearances.
    struct Desktop: View {
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.16, green: 0.18, blue: 0.27), Color(red: 0.27, green: 0.18, blue: 0.27)]
                    : [Color(red: 0.80, green: 0.85, blue: 0.95), Color(red: 0.95, green: 0.84, blue: 0.87)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
#endif
