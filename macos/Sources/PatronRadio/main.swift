import AppKit
import PatronRadioCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var backend: RadioBackend!
    private var controller: RadioController!
    private var statusItem: StatusItemController!
    private var nowPlaying: NowPlayingBridge!
    private var deviceMonitor: AudioDeviceMonitor?
    private var deviceRefreshWork: DispatchWorkItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        backend = RadioBackend()
        controller = RadioController(settings: settings, backend: backend,
                                     openURL: { NSWorkspace.shared.open($0) })
        statusItem = StatusItemController(controller: controller, settings: settings,
                                          openSettings: { [weak self] in self?.showSettings() })
        nowPlaying = NowPlayingBridge(controller: controller)

        // Output list / default output changes, debounced like the widget's
        // 500 ms routing timer (CoreAudio fires several notifications per change).
        deviceMonitor = AudioDeviceMonitor { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deviceRefreshWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.controller.refreshOutputs() }
                }
                self.deviceRefreshWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }

        #if DEBUG
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if let i = CommandLine.arguments.firstIndex(of: "--readme-shots"), i + 1 < CommandLine.arguments.count {
            ReadmeShots.run(into: URL(fileURLWithPath: CommandLine.arguments[i + 1]), controller: controller, settings: settings)
            NSApp.terminate(nil)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count {
            Snapshots.run(into: URL(fileURLWithPath: CommandLine.arguments[i + 1]), controller: controller, settings: settings)
            Snapshots.capturePopover(statusItem, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("real-popover.png"))
            NSApp.terminate(nil)
            return
        }
        #endif
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.saveStations() // flush any debounced loudness write
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(controller: controller, settings: settings)))
            window.title = "Patron Radio Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
