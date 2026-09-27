import AppKit
import PatronRadioCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings, organized like the widget's configuration dialog:
/// Behavior · Loudness · Appearance · Stations (plus About).
struct SettingsView: View {
    let controller: RadioController
    @Bindable var settings: AppSettings
    @State var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            BehaviorTab(controller: controller, settings: settings)
                .tabItem { Label("Behavior", systemImage: "gearshape") }.tag(0)
            LoudnessTab(settings: settings)
                .tabItem { Label("Loudness", systemImage: "speaker.wave.2") }.tag(1)
            AppearanceTab(settings: settings)
                .tabItem { Label("Appearance", systemImage: "menubar.rectangle") }.tag(2)
            StationsTab(controller: controller, settings: settings)
                .tabItem { Label("Stations", systemImage: "antenna.radiowaves.left.and.right") }.tag(3)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }.tag(4)
        }
        .frame(width: 640, height: 560)
        .onChange(of: settings.normalizeLoudness) { controller.settingsChanged() }
        .onChange(of: settings.loudnessAuto) { controller.settingsChanged() }
        .onChange(of: settings.inhibitSleep) { controller.settingsChanged() }
        .onChange(of: settings.outputPriority) { controller.settingsChanged() }
    }
}

// MARK: - Behavior

private struct BehaviorTab: View {
    let controller: RadioController
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Patron Radio at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Start playing automatically when Patron Radio opens", isOn: $settings.autoplayOnStartup)
                Toggle("Select closest local station on startup", isOn: $settings.autoLocalStation)
                Toggle("Resume playback if it was playing when last quit", isOn: $settings.resumePlaybackOnRestart)
                Toggle("Pause playback when the active audio output disconnects", isOn: $settings.pauseOnDisconnect)
                Toggle("Prevent system sleep while playing", isOn: $settings.inhibitSleep)
                Picker("Search the web for tracks with", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Startup & Playback")
            }

            Section {
                OutputPriorityEditor(controller: controller, settings: settings)
            } header: {
                Text("Audio Output Priority")
            } footer: {
                Text("Patron Radio plays through the highest connected device in this list. When none of them are connected, it follows the system output.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                AutoplayDevicesEditor(controller: controller, settings: settings)
            } header: {
                Text("Autoplay Triggers")
            } footer: {
                Text("Checked Bluetooth devices start playback when they connect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Patron Radio in System Settings › General › Login Items." : nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct OutputPriorityEditor: View {
    let controller: RadioController
    @Bindable var settings: AppSettings

    var body: some View {
        let online = Set(controller.outputs.map(\.uid))
        if settings.outputPriority.isEmpty {
            Text("No preferred outputs — following the system output.").foregroundStyle(.secondary)
        }
        ForEach(Array(settings.outputPriority.enumerated()), id: \.element.id) { i, pref in
            HStack {
                Image(systemName: "hifispeaker").opacity(online.contains(pref.id) ? 1 : 0.3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pref.name.isEmpty ? "Offline Device" : pref.name)
                        .opacity(online.contains(pref.id) ? 1 : 0.5)
                    Text(online.contains(pref.id) ? pref.id : "Not connected — \(pref.id)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(i == 0)
                Button { move(i, 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(i == settings.outputPriority.count - 1)
                Button { settings.outputPriority.remove(at: i) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        let addable = controller.outputs.filter { d in !settings.outputPriority.contains { $0.id == d.uid } }
        Menu("Add Output") {
            ForEach(addable) { d in
                Button(d.name) { settings.outputPriority.append(.init(id: d.uid, name: d.name)) }
            }
        }
        .disabled(addable.isEmpty)
        .fixedSize()
    }

    private func move(_ i: Int, _ delta: Int) {
        let j = i + delta
        guard settings.outputPriority.indices.contains(j) else { return }
        settings.outputPriority.swapAt(i, j)
    }
}

private struct AutoplayDevicesEditor: View {
    let controller: RadioController
    @Bindable var settings: AppSettings

    var body: some View {
        if settings.knownBluetoothDevices.isEmpty {
            Text("No Bluetooth audio devices seen yet. Connect one and it will appear here.")
                .foregroundStyle(.secondary)
        }
        ForEach(settings.knownBluetoothDevices, id: \.id) { d in
            Toggle(isOn: Binding(
                get: { settings.autoplayDevices.contains(d.id) },
                set: { on in
                    settings.autoplayDevices.removeAll { $0 == d.id }
                    if on { settings.autoplayDevices.append(d.id) }
                })) {
                HStack {
                    Text(d.name)
                    if controller.outputs.contains(where: { $0.uid == d.id }) {
                        Text("connected").font(.caption).foregroundStyle(.green)
                    }
                }
            }
        }
    }
}

// MARK: - Loudness

private struct LoudnessTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Normalize loudness across stations", isOn: $settings.normalizeLoudness)
                Toggle("Measure levels automatically", isOn: $settings.loudnessAuto)
                    .disabled(!settings.normalizeLoudness)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Evens out volume differences between stations (EBU R128), so switching isn't jarring. Louder stations are turned down to \(Int(Loudness.targetLUFS)) LUFS; quieter ones are left as they are, so set your system volume once.")
                    Text("When automatic measurement is off, per-station levels are editable in the Stations tab and are never overwritten.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Show", selection: $settings.menuBarStyle) {
                    ForEach(AppSettings.MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Subtitle", selection: $settings.subtitleMode) {
                    ForEach(AppSettings.SubtitleMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.menuBarStyle == .iconOnly)
            }
            Section("Sizing") {
                Picker("Width", selection: $settings.widthMode) {
                    ForEach(AppSettings.WidthMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.widthMode == .fixed {
                    HStack {
                        Slider(value: $settings.fixedWidth, in: 60...320, step: 10)
                        Text("\(Int(settings.fixedWidth)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
            }
            .disabled(settings.menuBarStyle == .iconOnly)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Stations

private struct StationsTab: View {
    let controller: RadioController
    @Bindable var settings: AppSettings
    @State private var expanded: Set<UUID> = []
    @State private var confirmRestore = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Station List").font(.headline)
                    Text("Drag to reorder. The list uses the same JSON format as the Plasma widget.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Import…", action: importStations)
                    Button("Export…", action: exportStations)
                    Divider()
                    Button("Restore Default Stations…") { confirmRestore = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button {
                    let s = Station.newTemplate()
                    controller.setStations([s] + controller.stations)
                    expanded.insert(s.id)
                } label: { Label("Add New Station", systemImage: "plus") }
            }
            if let importError { Text(importError).font(.caption).foregroundStyle(.red) }

            List {
                ForEach(controller.stations) { station in
                    StationEditorRow(controller: controller, settings: settings, stationID: station.id,
                                     isExpanded: Binding(
                                        get: { expanded.contains(station.id) },
                                        set: { if $0 { expanded.insert(station.id) } else { expanded.remove(station.id) } }))
                }
                .onMove { from, to in
                    var list = controller.stations
                    list.move(fromOffsets: from, toOffset: to)
                    controller.setStations(list)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding()
        .confirmationDialog("Replace your station list with the default stations?", isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) { controller.setStations(Station.defaults) }
        } message: {
            Text("Your edits and added stations will be lost. Export first to keep a copy.")
        }
    }

    private func importStations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8), let list = Station.decodeList(text), !list.isEmpty else {
            importError = "That file isn't a station list."
            return
        }
        importError = nil
        controller.setStations(list)
    }

    private func exportStations() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "patron-radio-stations.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Station.encodeList(controller.stations, pretty: true).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct StationEditorRow: View {
    let controller: RadioController
    @Bindable var settings: AppSettings
    let stationID: UUID
    @Binding var isExpanded: Bool
    @State private var manualLevel = ""

    private var index: Int? { controller.stations.firstIndex { $0.id == stationID } }

    private func binding<T>(_ kp: WritableKeyPath<Station, T>) -> Binding<T> {
        Binding(
            get: { index.map { controller.stations[$0][keyPath: kp] } ?? Station.newTemplate()[keyPath: kp] },
            set: { v in
                guard let i = index else { return }
                var list = controller.stations
                list[i][keyPath: kp] = v
                controller.setStations(list)
            })
    }

    private func coordinate(_ kp: WritableKeyPath<Station, Double?>) -> Binding<String> {
        Binding(
            get: { binding(kp).wrappedValue.map { String($0) } ?? "" },
            set: { binding(kp).wrappedValue = Double($0.trimmingCharacters(in: .whitespaces)) })
    }

    var body: some View {
        if let i = index {
            let s = controller.stations[i]
            DisclosureGroup(isExpanded: $isExpanded) {
                Form {
                    TextField("Name", text: binding(\.name))
                    TextField("Location", text: binding(\.city), prompt: Text("City, ST"))
                    TextField("Stream URL", text: binding(\.url), prompt: Text("https://stream.example.com/live.mp3"))
                    TextField("Website URL", text: binding(\.website), prompt: Text("https://station.example.com/playlist"))
                    TextField("Donate URL", text: binding(\.donate), prompt: Text("https://station.example.com/donate"))
                    HStack {
                        TextField("Coordinates", text: coordinate(\.lat), prompt: Text("Latitude (e.g. 40.71)"))
                        TextField("", text: coordinate(\.lon), prompt: Text("Longitude (e.g. -74.00)"))
                            .labelsHidden()
                    }
                    Picker("Station Type", selection: binding(\.kind)) {
                        ForEach(StationKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    levelRow(s)
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    StationIcon(kind: s.kind, size: 14).foregroundStyle(.secondary)
                    Text(s.name.isEmpty ? "Unnamed Station" : s.name).bold().lineLimit(1)
                    Text(s.city).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button {
                        var list = controller.stations
                        list.remove(at: i)
                        controller.setStations(list)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete Station")
                }
            }
        }
    }

    /// Loudness level: measured (automatic) or a hand-set attenuation in dB.
    @ViewBuilder
    private func levelRow(_ s: Station) -> some View {
        let adj = s.loudness.map { Loudness.attenuationGainDB(measured: $0) }
        if settings.loudnessAuto {
            LabeledContent("Level") {
                if let adj, let l = s.loudness {
                    Text(String(format: "%.1f dB   (%.1f LUFS)", adj <= -0.05 ? adj : 0, l))
                        .foregroundStyle(.secondary)
                        .help("Turn off \"Measure levels automatically\" (Loudness tab) to set this manually.")
                } else {
                    Text("measuring…").foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                TextField("Level", text: $manualLevel, prompt: Text("0"))
                    .frame(maxWidth: 200)
                    .onAppear { manualLevel = adj.map { String(format: "%.1f", $0) } ?? "" }
                    .onSubmit {
                        if let v = Double(manualLevel) {
                            let clamped = min(0, max(-Loudness.maxAttenuationDB, v))
                            binding(\.loudness).wrappedValue = Loudness.targetLUFS - clamped
                            manualLevel = String(format: "%.1f", clamped)
                        } else {
                            binding(\.loudness).wrappedValue = nil // clear → use the default
                        }
                    }
                Text("dB attenuation (boost not possible)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "radio").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Patron Radio").font(.title.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Independent and public radio in your menu bar — a companion to the Patron Radio KDE Plasma widget. Please support the stations you listen to.")
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Link("github.com/ajweiss/patron-radio", destination: URL(string: "https://github.com/ajweiss/patron-radio")!)
            Divider().frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 4) {
                Text("Privacy").font(.headline)
                Text("Patron Radio contacts station stream servers when you play them, get.geojs.io only for \"Play Nearest Station\", and radio-browser.info only when you use \"Fix\". No telemetry, no accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420, alignment: .leading)
            Text("Licensed under the GNU GPL v3 or later.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
