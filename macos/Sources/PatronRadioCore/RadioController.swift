import Foundation
import Observation

/// The single playback state. Like the widget's main.qml, there is one state
/// value, never a set of independent booleans.
public enum PlaybackState: Int, Sendable {
    case stopped, buffering, playing, broken, fixing, locating
}

/// Orchestration: the macOS port of main.qml + AudioRouter.qml + StationApi.qml.
/// Owns the station list, the playback state machine, track history, output
/// routing and the network lookups (nearest station, stream "Fix").
@MainActor
@Observable
public final class RadioController {
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    // MARK: State

    public private(set) var playbackState: PlaybackState = .stopped
    public private(set) var stations: [Station] = []
    public private(set) var currentStationIndex = 0
    public private(set) var currentTrack = ""
    public private(set) var errorMessage = ""
    /// Committed history, newest first (index 0 is the current song once committed).
    public private(set) var history: [TrackHistoryEntry] = []
    public private(set) var outputs: [AudioOutputDevice] = []
    /// Manual output override from the menu; nil = automatic (priority list).
    public private(set) var manualOutputUID: String?
    public var userRequestedPlayback = false

    public var isPlaying: Bool { playbackState == .playing }
    public var isBuffering: Bool { playbackState == .buffering }
    public var isBroken: Bool { playbackState == .broken }
    public var isFixing: Bool { playbackState == .fixing }
    public var isLocating: Bool { playbackState == .locating }

    public var hasCurrentStation: Bool { stations.indices.contains(currentStationIndex) }
    public var currentStation: Station? { hasCurrentStation ? stations[currentStationIndex] : nil }
    public var currentStationName: String { currentStation?.name ?? "" }
    public var currentStationCity: String { currentStation?.city ?? "" }
    public var currentStationWebsite: String { currentStation?.website ?? "" }
    public var currentStationDonate: String { currentStation?.donate ?? "" }
    public var streamInfo: StreamInfo? { backendStreamInfo }
    public var activeOutputUID: String? { backend.activeOutputUID }

    public let settings: AppSettings
    @ObservationIgnored public let backend: RadioBackendProtocol
    @ObservationIgnored private let deviceProvider: () -> [AudioOutputDevice]
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let openURLHandler: (URL) -> Void

    private var backendStreamInfo: StreamInfo?
    @ObservationIgnored private var isRouting = false
    @ObservationIgnored private var pendingTrack = ""
    @ObservationIgnored private var pendingTrackAt = Date()
    @ObservationIgnored private var lastHistoryTrack = ""
    @ObservationIgnored private var historyTimer: Timer?
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored public var historyCommitDelay = TrackHeuristics.commitDelay
    @ObservationIgnored public var saveDelay: TimeInterval = 4

    public init(settings: AppSettings,
                backend: RadioBackendProtocol,
                deviceProvider: @escaping () -> [AudioOutputDevice] = AudioDevices.outputs,
                fetch: @escaping Fetch = RadioController.urlSessionFetch,
                openURL: @escaping (URL) -> Void = { _ in }) {
        self.settings = settings
        self.backend = backend
        self.deviceProvider = deviceProvider
        self.fetch = fetch
        self.openURLHandler = openURL
        backend.normalizeLoudness = settings.normalizeLoudness
        backend.loudnessAuto = settings.loudnessAuto
        backend.inhibitSleep = settings.inhibitSleep
        backend.onEvent = { [weak self] event in self?.handleBackend(event) }
        loadStations()
    }

    nonisolated public static let urlSessionFetch: Fetch = { url in
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("PatronRadio/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Startup, like main.qml's Component.onCompleted.
    public func start() {
        refreshOutputs(initial: true)
        let resume = settings.resumePlaybackOnRestart && settings.wasPlaying
        let autoPlay = settings.autoplayOnStartup
        if settings.autoLocalStation {
            updateClosestStation(forcePlay: autoPlay || resume)
        } else if autoPlay || resume {
            playStation(currentStationIndex, reason: resume ? "startup resume" : "startup autoplay")
        }
    }

    /// Mirror setting changes into the backend (the widget uses QML Bindings).
    public func settingsChanged() {
        backend.normalizeLoudness = settings.normalizeLoudness
        backend.loudnessAuto = settings.loudnessAuto
        backend.inhibitSleep = settings.inhibitSleep
        applyBestAudioRouting()
    }

    // MARK: - Backend events

    private func handleBackend(_ event: BackendEvent) {
        switch event {
        case .streamTitleChanged:
            let t = backend.streamTitle
            currentTrack = t          // header updates immediately
            queueTrack(t)             // history is debounced
        case .lastErrorChanged:
            let err = backend.lastError
            if !err.isEmpty {
                errorMessage = err
                playbackState = .broken
            } else {
                errorMessage = ""
            }
        case .playingChanged:
            if backend.isPlaying {
                playbackState = .playing
            } else {
                if playbackState == .playing { playbackState = .stopped }
                // The backend stopped and we're not mid-reroute: the user no longer
                // wants playback. Disarm so an output change can't auto-resume.
                if !isRouting { userRequestedPlayback = false }
            }
        case .bufferingChanged:
            if backend.isBuffering && playbackState != .playing { playbackState = .buffering }
        case .measuredLoudnessChanged:
            guard let lufs = backend.measuredLoudness, hasCurrentStation,
                  stations[currentStationIndex].url == backend.currentURL else { return }
            stations[currentStationIndex].loudness = lufs
            persistStationsSoon()
        case .streamInfoChanged:
            backendStreamInfo = backend.streamInfo
        case .outputLost:
            handleActiveOutputGone()
        }
    }

    // MARK: - Playback control

    private func logPlay(_ reason: String) {
        NSLog("patron-radio: play trigger = \(reason) | state = \(playbackState.rawValue) | userRequested = \(userRequestedPlayback)")
    }

    public func togglePlay() {
        if isPlaying {
            NSLog("patron-radio: stop trigger = user toggle | state = \(playbackState.rawValue)")
            stop()
        } else {
            guard let station = currentStation else {
                NSLog("patron-radio: cannot play, station list is empty or index is invalid")
                return
            }
            logPlay("user toggle")
            userRequestedPlayback = true
            clearTrackHistory()
            playbackState = .buffering
            startBackend(station)
        }
    }

    /// Stop by user request (the transport button, a media key, the menu).
    public func stop() {
        userRequestedPlayback = false
        backend.stop()
        playbackState = .stopped
        settings.wasPlaying = false
    }

    /// Transport button semantics: fix when broken, stop while playing or
    /// buffering ("Buffering — click to stop"), otherwise play.
    public func primaryAction() {
        if isBroken {
            fixCurrentStream()
        } else if isBuffering {
            NSLog("patron-radio: stop trigger = user stop while buffering")
            stop()
        } else {
            togglePlay()
        }
    }

    public func playStation(_ index: Int, reason: String = "station selected") {
        guard stations.indices.contains(index) else {
            NSLog("patron-radio: cannot play station, index \(index) is out of range")
            return
        }
        guard currentStationIndex != index || (!isPlaying && !isBroken) else { return }
        logPlay("playStation (\(reason))")
        userRequestedPlayback = true
        setCurrentStationIndex(index)
        clearTrackHistory()
        currentTrack = ""
        playbackState = .buffering
        startBackend(stations[index])
    }

    private func startBackend(_ station: Station) {
        backend.currentStationName = station.name
        backend.knownLoudness = station.loudness
        backend.setCurrentURL(station.url)
        applyBestAudioRouting()
        backend.play()
        settings.wasPlaying = true
    }

    public func next() {
        guard !stations.isEmpty else { return }
        playStation((currentStationIndex + 1) % stations.count, reason: "media key next")
    }

    public func previous() {
        guard !stations.isEmpty else { return }
        playStation((currentStationIndex - 1 + stations.count) % stations.count, reason: "media key previous")
    }

    private func setCurrentStationIndex(_ i: Int) {
        currentStationIndex = i
        if stations.indices.contains(i) { settings.currentStationURL = stations[i].url }
    }

    // MARK: - Links

    /// Station links come from (potentially user-edited) config: only http(s) is
    /// ever handed to the system, so a bad entry can't launch another URL handler.
    public func openExternal(_ string: String) {
        guard URLPolicy.isWebURL(string), let url = URL(string: string) else {
            NSLog("patron-radio: refusing to open non-HTTP(S) URL: \(string)")
            return
        }
        openURLHandler(url)
    }

    public func openDonate() {
        guard !currentStationDonate.isEmpty else { return }
        openExternal(URLPolicy.taggedOutboundURL(currentStationDonate))
    }

    public func openPlaylist() {
        guard !currentStationWebsite.isEmpty else { return }
        openExternal(URLPolicy.taggedOutboundURL(currentStationWebsite))
    }

    /// Look a track up on the web. ICY titles are free text (no per-track URL), so
    /// a search is the only reliable target.
    public func searchTrack(_ title: String) {
        guard let url = settings.searchEngine.url(for: title) else { return }
        openExternal(url.absoluteString)
    }

    // MARK: - Track history

    private func queueTrack(_ title: String) {
        // Stamp the start time on first sighting so the debounce doesn't skew it.
        if title != pendingTrack { pendingTrack = title; pendingTrackAt = Date() }
        historyTimer?.invalidate()
        guard !title.isEmpty else { return }
        historyTimer = Timer.scheduledTimer(withTimeInterval: historyCommitDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitPendingTrack() }
        }
    }

    public func commitPendingTrack() {
        let title = pendingTrack
        guard !title.isEmpty, title != lastHistoryTrack else { return }
        guard !TrackHeuristics.isStationBanner(title, stationName: currentStationName) else { return }
        lastHistoryTrack = title
        history.insert(TrackHistoryEntry(title: title, startedAt: pendingTrackAt), at: 0)
        if history.count > TrackHeuristics.maxEntries { history.removeLast(history.count - TrackHeuristics.maxEntries) }
    }

    private func clearTrackHistory() {
        history.removeAll()
        lastHistoryTrack = ""
        pendingTrack = ""
        historyTimer?.invalidate()
    }

    // MARK: - Stations

    /// Replace the station list (settings editor, import, Fix tool). Keeps the
    /// current station selected by URL across reorders, like loadStations().
    public func setStations(_ newStations: [Station]) {
        let prevURL = currentStation?.url
        stations = newStations
        if let prevURL, let i = stations.firstIndex(where: { $0.url == prevURL }) {
            currentStationIndex = i
        } else if currentStationIndex >= stations.count {
            currentStationIndex = 0
        }
        if hasCurrentStation { settings.currentStationURL = stations[currentStationIndex].url }
        saveStations()
    }

    private func loadStations() {
        stations = Station.decodeList(settings.stationsJSON) ?? Station.defaults
        currentStationIndex = stations.firstIndex { $0.url == settings.currentStationURL } ?? 0
    }

    public func saveStations() {
        saveTimer?.invalidate()
        settings.stationsJSON = Station.encodeList(stations)
    }

    /// Loudness updates arrive every few hundred ms; debounce the writes.
    private func persistStationsSoon() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveStations() }
        }
    }

    // MARK: - Fix tool (radio-browser.info)

    public func fixCurrentStream() {
        guard playbackState != .fixing, hasCurrentStation, let url = RadioBrowser.searchURL(for: currentStationName) else { return }
        playbackState = .fixing
        currentTrack = "Searching for new stream..."
        // The list can be edited while the search is in flight, so remember the
        // station itself, not its index (the id survives reorders; the URL
        // survives an import round-trip, which regenerates ids).
        let target = stations[currentStationIndex]
        let fetch = self.fetch
        Task { @MainActor in
            do {
                let (data, status) = try await fetch(url)
                guard status == 200 else {
                    fixFailed("Search directory is currently offline.")
                    return
                }
                guard let found = RadioBrowser.pickReplacement(data) else {
                    fixFailed("Could not find a working replacement stream.")
                    return
                }
                guard let index = stations.firstIndex(where: { $0.id == target.id })
                        ?? stations.firstIndex(where: { $0.url == target.url }) else {
                    fixFailed("The station was removed while searching.")
                    return
                }
                stations[index].url = found
                stations[index].loudness = nil // new stream → old loudness no longer applies
                currentStationIndex = index
                saveStations()
                settings.currentStationURL = found
                currentTrack = ""
                playbackState = .buffering
                backend.knownLoudness = nil
                backend.setCurrentURL(found)
                logPlay("fix broken stream")
                backend.play()
            } catch {
                fixFailed("Search directory is currently offline.")
            }
        }
    }

    private func fixFailed(_ message: String) {
        playbackState = .broken
        currentTrack = message
    }

    // MARK: - Nearest station (get.geojs.io)

    public func playClosestStation() { updateClosestStation(forcePlay: true) }

    public func updateClosestStation(forcePlay: Bool) {
        guard playbackState != .locating else { return }
        playbackState = .locating
        let fetch = self.fetch
        Task { @MainActor in
            defer { if playbackState == .locating { playbackState = .stopped } }
            do {
                let url = URL(string: "https://get.geojs.io/v1/ip/geo.json")!
                let (data, status) = try await fetch(url)
                guard status == 200 else { errorMessage = "Geolocation service unavailable."; return }
                guard let loc = Geo.parseGeoJS(data) else {
                    errorMessage = "Geolocation response could not be parsed."
                    return
                }
                guard let closest = Geo.closestStationIndex(stations, lat: loc.lat, lon: loc.lon) else { return }
                if playbackState == .locating { playbackState = .stopped }
                if forcePlay {
                    playStation(closest, reason: "closest station")
                } else if closest != currentStationIndex && !isPlaying {
                    setCurrentStationIndex(closest)
                }
            } catch {
                errorMessage = "Geolocation service unavailable."
            }
        }
    }

    // MARK: - Output routing (AudioRouter.qml)

    /// Called at startup and whenever CoreAudio's device list or default changes.
    public func refreshOutputs(initial: Bool = false) {
        let new = deviceProvider()
        let oldUIDs = Set(outputs.map(\.uid))
        let newUIDs = Set(new.map(\.uid))
        outputs = new

        // Remember Bluetooth outputs so autoplay triggers can be set while they're off.
        var known = settings.knownBluetoothDevices
        for d in new where d.isBluetooth {
            if let i = known.firstIndex(where: { $0.id == d.uid }) {
                if known[i].name != d.name { known[i].name = d.name }
            } else {
                known.append(.init(id: d.uid, name: d.name))
            }
        }
        if known != settings.knownBluetoothDevices { settings.knownBluetoothDevices = known }

        if !initial {
            if let active = backend.activeOutputUID, oldUIDs.contains(active), !newUIDs.contains(active) {
                handleActiveOutputGone()
            }
            for d in new where !oldUIDs.contains(d.uid) && settings.autoplayDevices.contains(d.uid) {
                userRequestedPlayback = true
                if playbackState == .stopped {
                    playStation(currentStationIndex, reason: "device autoplay (\(d.name))")
                }
            }
        }
        applyBestAudioRouting()
    }

    /// The output we were playing through went away (headphones unplugged,
    /// AirPods out of range): pause rather than fall back to the speakers.
    private func handleActiveOutputGone() {
        isRouting = true
        if let m = manualOutputUID, !outputs.contains(where: { $0.uid == m }) { manualOutputUID = nil }
        if settings.pauseOnDisconnect && (isPlaying || isBuffering) {
            NSLog("patron-radio: stop trigger = active output disconnected")
            userRequestedPlayback = false
            backend.stop()
            playbackState = .stopped
        }
        applyBestAudioRouting()
    }

    public func applyBestAudioRouting() {
        if let m = manualOutputUID {
            if outputs.contains(where: { $0.uid == m }) {
                backend.setOutputPreference(uid: m)
                isRouting = false
                return
            }
            manualOutputUID = nil
        }
        let target = settings.outputPriority.first { pref in outputs.contains { $0.uid == pref.id } }
        backend.setOutputPreference(uid: target?.id)
        if userRequestedPlayback && playbackState != .playing && playbackState != .broken && playbackState != .buffering {
            logPlay("routing auto-resume (output change)")
            playbackState = .buffering
            if let s = currentStation { startBackend(s) }
        }
        isRouting = false
    }

    public func selectOutput(uid: String) {
        manualOutputUID = uid
        backend.setOutputPreference(uid: uid)
    }

    public func selectAutomaticRouting() {
        manualOutputUID = nil
        applyBestAudioRouting()
    }

    // MARK: - Tooltip text (mirrors the widget's tooltip)

    public var statusTitle: String {
        switch playbackState {
        case .locating: return "Locating Station..."
        case .fixing: return "Finding new stream..."
        case .playing: return "Playing: \(currentStationName)"
        case .broken: return "Stream Offline"
        default: return "Patron Radio"
        }
    }

    public var statusDetail: String {
        switch playbackState {
        case .locating: return "Finding closest local station..."
        case .fixing: return "Searching radio-browser.info for a working stream..."
        case .broken:
            let base = errorMessage.isEmpty
                ? "\(currentStationName) stream is currently unavailable."
                : "\(currentStationName) stream is currently unavailable. (\(errorMessage))"
            return base + " Click 'Fix' to search for a new URL."
        default:
            let where_ = currentStationCity.isEmpty ? currentStationName : "\(currentStationName) from \(currentStationCity)"
            var s = isPlaying ? "Playing \(where_)" : (isBuffering ? "Buffering \(where_)" : "Stopped \(where_)")
            if !currentTrack.isEmpty { s += "\nNow Playing: \(currentTrack)" }
            let tech = [streamInfo?.codec ?? "", streamInfo?.bitrateText ?? ""].filter { !$0.isEmpty }
            if !tech.isEmpty { s += "\n[\(tech.joined(separator: " @ "))]" }
            return s
        }
    }
}
