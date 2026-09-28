import AppKit
import PatronRadioCore
import SwiftUI

/// The popover: the macOS counterpart of the widget's FullRepresentation —
/// "now playing" header with donate + transport + actions, the recently-played
/// strip, and the station list (led by "Play Nearest Station").
struct PopoverView: View {
    @Bindable var controller: RadioController
    let openSettings: () -> Void
    let close: () -> Void

    /// -1 is the "Play Nearest Station" row; 0... are station indices.
    @State private var selection: Int?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.history.count > 1 {
                recents
                Divider()
            }
            stationList
        }
        .frame(width: 340, height: 480)
        .onAppear {
            selection = controller.currentStationIndex
            listFocused = true
        }
        .onChange(of: controller.currentStationIndex) { _, new in selection = new }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if !controller.currentStationDonate.isEmpty {
                Button { controller.openDonate() } label: {
                    Image(systemName: "heart.fill").font(.system(size: 15)).foregroundStyle(.pink)
                }
                .buttonStyle(.borderless)
                .help("Support \(controller.currentStationName)")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.currentStationName.isEmpty ? "Patron Radio" : controller.currentStationName)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                TrackLine(controller: controller)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transportButton

            Menu {
                ForEach(MenuModel.entries(controller, openSettings: openSettings)) { entry in
                    menuItem(entry)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func menuItem(_ entry: MenuEntry) -> some View {
        switch entry.kind {
        case .separator:
            Divider()
        case .action:
            if let checked = entry.checked {
                Toggle(isOn: Binding(get: { checked }, set: { _ in entry.perform() })) {
                    Text(entry.title)
                }
            } else {
                Button { entry.perform() } label: {
                    if let s = entry.symbol { Label(entry.title, systemImage: s) } else { Text(entry.title) }
                }
            }
        }
    }

    /// Honest about all four states: play / stop / buffering (spinner) / broken (fix).
    private var transportButton: some View {
        Button { controller.primaryAction() } label: {
            ZStack {
                if controller.isBuffering || controller.isFixing || controller.isLocating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: controller.isBroken ? "wrench.and.screwdriver.fill"
                          : (controller.isPlaying ? "stop.fill" : "play.fill"))
                        .font(.system(size: 16))
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(controller.isBroken ? "Find a working stream"
              : (controller.isBuffering ? "Buffering — click to stop" : (controller.isPlaying ? "Stop" : "Play")))
    }

    // MARK: Recently played

    private var recents: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Recently played").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if !controller.currentStationWebsite.isEmpty {
                    Button { controller.openPlaylist() } label: {
                        Label("Playlist", systemImage: "link").font(.caption)
                    }
                    .buttonStyle(.link)
                    .help("Open the station's playlist page")
                }
            }
            // Index 0 is the current song, already in the header.
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.history.dropFirst().prefix(3))) { entry in
                        RecentRow(entry: entry, now: ctx.date) { controller.searchTrack(entry.title) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Station list

    private var stationList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                StationRow(kind: nil,
                           title: controller.isLocating ? "Locating..." : "Play Nearest Station",
                           subtitle: nil, isCurrent: false, isPlaying: false)
                    .tag(-1)
                    .help("Uses your IP address to find and play the closest configured radio station.")
                    .onTapGesture { activate(-1) }
                ForEach(Array(controller.stations.enumerated()), id: \.offset) { i, s in
                    StationRow(kind: s.kind, title: s.name, subtitle: s.city,
                               isCurrent: i == controller.currentStationIndex,
                               isPlaying: i == controller.currentStationIndex && controller.isPlaying)
                        .tag(i)
                        .id(i)
                        .onTapGesture { activate(i) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .onKeyPress(.return) { activateSelection() }
            .onKeyPress(.space) { activateSelection() }
            .onAppear { proxy.scrollTo(controller.currentStationIndex, anchor: .center) }
        }
    }

    private func activateSelection() -> KeyPress.Result {
        guard let selection else { return .ignored }
        activate(selection)
        return .handled
    }

    private func activate(_ index: Int) {
        selection = index
        if index < 0 {
            controller.playClosestStation()
        } else {
            controller.playStation(index, reason: "list selection")
        }
        close()
    }
}

/// The track (or city) line under the station name. Long titles crawl; a real
/// track is clickable to search the web for it.
private struct TrackLine: View {
    let controller: RadioController
    @State private var hovering = false

    var body: some View {
        let track = controller.currentTrack
        let text = track.isEmpty ? controller.currentStationCity : track
        Marquee(text: text, font: .systemFont(ofSize: 12), italic: !track.isEmpty,
                color: Color(nsColor: hovering ? .labelColor : .secondaryLabelColor))
            .contentShape(Rectangle())
            .onHover { hovering = $0 && !track.isEmpty }
            .onTapGesture { if !track.isEmpty { controller.searchTrack(track) } }
            .help(track.isEmpty ? "" : "Search the web for this track")
    }
}

private struct RecentRow: View {
    let entry: TrackHistoryEntry
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(TrackHeuristics.relativeTime(from: entry.startedAt, now: now))
                .font(.caption).foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
            Text(entry.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .underline(hovering)
                .foregroundStyle(hovering ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Search the web for this track")
    }
}

private struct StationRow: View {
    let kind: StationKind?
    let title: String
    let subtitle: String?
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            StationIcon(kind: kind, size: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).fontWeight(isCurrent ? .bold : .regular).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isPlaying {
                Image(systemName: "play.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
