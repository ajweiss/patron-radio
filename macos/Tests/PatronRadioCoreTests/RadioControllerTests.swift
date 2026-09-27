import Foundation
import Testing
@testable import PatronRadioCore

/// Records calls and lets tests fire backend events.
@MainActor
final class FakeBackend: RadioBackendProtocol {
    var isPlaying = false
    var isBuffering = false
    var streamTitle = ""
    var currentURL = ""
    var lastError = ""
    var measuredLoudness: Double?
    var streamInfo: StreamInfo?
    var activeOutputUID: String?
    var currentStationName = ""
    var knownLoudness: Double?
    var normalizeLoudness = true
    var loudnessAuto = true
    var inhibitSleep = false
    var onEvent: ((BackendEvent) -> Void)?

    var playCount = 0
    var stopCount = 0
    var outputPreference: String?? = .none
    var defaultOutputUID = "builtin"

    func setCurrentURL(_ url: String) { currentURL = url }
    func play() { playCount += 1; isBuffering = true; onEvent?(.bufferingChanged) }
    func stop() {
        stopCount += 1
        isBuffering = false
        if isPlaying { isPlaying = false; onEvent?(.playingChanged) }
    }
    func setOutputPreference(uid: String?) {
        outputPreference = .some(uid)
        activeOutputUID = uid ?? defaultOutputUID
    }

    // Test drivers
    func startPlaying() { isBuffering = false; isPlaying = true; onEvent?(.playingChanged) }
    func title(_ t: String) { streamTitle = t; onEvent?(.streamTitleChanged) }
    func fail(_ e: String) { lastError = e; onEvent?(.lastErrorChanged) }
    func measure(_ lufs: Double) { measuredLoudness = lufs; onEvent?(.measuredLoudnessChanged) }
}

@MainActor
struct RadioControllerTests {
    let settings: AppSettings
    let backend = FakeBackend()
    var devices: [AudioOutputDevice] = [AudioOutputDevice(uid: "builtin", name: "MacBook Speakers", deviceID: 1, isBluetooth: false)]
    var fetchResult: (Data, Int) = (Data(), 500)
    var opened: [URL] = []

    init() {
        settings = AppSettings(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.stationsJSON = Station.encodeList([
            Station(name: "KEXP", city: "Seattle, WA", url: "https://kexp/stream", website: "https://kexp.org/playlist/",
                    donate: "https://kexp.org/donate/", lat: 47.6, lon: -122.3, loudness: -18.8),
            Station(name: "WFMU", city: "Jersey City, NJ", url: "https://wfmu/stream", lat: 40.7, lon: -74.1),
            Station(name: "New Sounds (WNYC)", city: "New York, NY", url: "https://wnyc/q2", lat: 40.75, lon: -73.99),
        ])
    }

    private func make(devices: [AudioOutputDevice]? = nil, fetch: (Data, Int)? = nil) -> RadioController {
        let devs = devices ?? self.devices
        let result = fetch ?? fetchResult
        let c = RadioController(settings: settings, backend: backend, deviceProvider: { devs },
                                fetch: { _ in result })
        c.historyCommitDelay = 3600 // tests commit explicitly
        c.saveDelay = 3600
        return c
    }

    // MARK: Playback state machine

    @Test func togglePlayStartsTheCurrentStation() {
        let c = make()
        c.togglePlay()
        #expect(c.playbackState == .buffering)
        #expect(backend.currentURL == "https://kexp/stream")
        #expect(backend.currentStationName == "KEXP")
        #expect(backend.knownLoudness == -18.8)
        #expect(backend.playCount >= 1)
        #expect(settings.wasPlaying)
        #expect(c.userRequestedPlayback)

        backend.startPlaying()
        #expect(c.playbackState == .playing)
    }

    @Test func toggleWhilePlayingStops() {
        let c = make()
        c.togglePlay()
        backend.startPlaying()
        c.togglePlay()
        #expect(c.playbackState == .stopped)
        #expect(backend.stopCount == 1)
        #expect(!settings.wasPlaying)
        #expect(!c.userRequestedPlayback)
    }

    @Test func primaryActionStopsWhileBuffering() {
        let c = make()
        c.togglePlay()
        #expect(c.isBuffering)
        c.primaryAction()
        #expect(c.playbackState == .stopped)
        #expect(backend.stopCount == 1)
    }

    @Test func errorsBreakThePlayerAndRecoveryClearsIt() {
        let c = make()
        c.togglePlay()
        backend.fail("Server returned HTTP 404")
        #expect(c.playbackState == .broken)
        #expect(c.errorMessage == "Server returned HTTP 404")
        #expect(c.statusDetail.contains("Click 'Fix'"))
        backend.lastError = ""
        backend.onEvent?(.lastErrorChanged)
        backend.startPlaying()
        #expect(c.playbackState == .playing)
        #expect(c.errorMessage.isEmpty)
    }

    @Test func bufferingDoesNotOverridePlaying() {
        let c = make()
        c.togglePlay()
        backend.startPlaying()
        backend.isBuffering = true
        backend.onEvent?(.bufferingChanged)
        #expect(c.playbackState == .playing)
    }

    @Test func backendStopDisarmsAutoResume() {
        let c = make()
        c.togglePlay()
        backend.startPlaying()
        backend.isPlaying = false
        backend.onEvent?(.playingChanged)
        #expect(c.playbackState == .stopped)
        #expect(!c.userRequestedPlayback)
    }

    @Test func selectingThePlayingStationAgainIsANoOp() {
        let c = make()
        c.playStation(1)
        backend.startPlaying()
        let plays = backend.playCount
        c.playStation(1)
        #expect(backend.playCount == plays)
        c.playStation(2)
        #expect(backend.currentURL == "https://wnyc/q2")
        #expect(settings.currentStationURL == "https://wnyc/q2")
    }

    @Test func outOfRangeStationIsIgnored() {
        let c = make()
        c.playStation(99)
        c.playStation(-1)
        #expect(c.playbackState == .stopped)
        #expect(backend.playCount == 0)
    }

    @Test func nextAndPreviousWrap() {
        let c = make()
        c.previous()
        #expect(c.currentStationIndex == 2)
        backend.startPlaying()
        c.next()
        #expect(c.currentStationIndex == 0)
    }

    @Test func emptyStationListCannotPlay() {
        settings.stationsJSON = "[]"
        let c = make()
        c.togglePlay()
        c.next()
        #expect(c.playbackState == .stopped)
        #expect(backend.playCount == 0)
    }

    // MARK: Loudness persistence

    @Test func measuredLoudnessIsStoredOnTheMatchingStationOnly() {
        let c = make()
        c.playStation(1)
        backend.measure(-14.2)
        #expect(c.stations[1].loudness == -14.2)
        c.saveStations()
        #expect(Station.decodeList(settings.stationsJSON)?[1].loudness == -14.2)

        backend.currentURL = "https://somewhere-else"
        backend.measure(-9)
        #expect(c.stations[1].loudness == -14.2)
    }

    // MARK: Track history

    @Test func historyFiltersBannersAndDuplicates() {
        let c = make()
        c.playStation(2)
        backend.title("New Sounds-")
        c.commitPendingTrack()
        #expect(c.history.isEmpty)
        #expect(c.currentTrack == "New Sounds-")

        backend.title("Arvo Pärt - Spiegel im Spiegel")
        c.commitPendingTrack()
        c.commitPendingTrack()
        #expect(c.history.map(\.title) == ["Arvo Pärt - Spiegel im Spiegel"])
    }

    @Test func historyIsCappedAndResetOnStationChange() {
        let c = make()
        c.playStation(0)
        for i in 0..<20 {
            backend.title("Artist \(i) - Song")
            c.commitPendingTrack()
        }
        #expect(c.history.count == TrackHeuristics.maxEntries)
        #expect(c.history.first?.title == "Artist 19 - Song")
        c.playStation(1)
        #expect(c.history.isEmpty)
        #expect(c.currentTrack == "")
    }

    // MARK: Stations

    @Test func editingKeepsTheCurrentStationByURL() {
        let c = make()
        c.playStation(1)
        var list = c.stations
        list.insert(Station.newTemplate(), at: 0)
        c.setStations(list)
        #expect(c.currentStationIndex == 2)
        #expect(c.currentStationName == "WFMU")
        #expect(Station.decodeList(settings.stationsJSON)?.count == 4)

        c.setStations([list[0]])
        #expect(c.currentStationIndex == 0)
    }

    @Test func restoresTheLastStationOnLaunch() {
        settings.currentStationURL = "https://wnyc/q2"
        let c = make()
        #expect(c.currentStationIndex == 2)
    }

    // MARK: Startup

    @Test func resumesIfPlayingWhenLastQuit() {
        settings.wasPlaying = true
        settings.resumePlaybackOnRestart = true
        let c = make()
        c.start()
        #expect(c.playbackState == .buffering)
        #expect(backend.playCount >= 1)
    }

    @Test func staysQuietByDefault() {
        let c = make()
        c.start()
        #expect(c.playbackState == .stopped)
        #expect(backend.playCount == 0)
    }

    // MARK: Links

    @Test func linksAreTaggedAndRestrictedToHTTP() {
        var opened: [URL] = []
        let c = RadioController(settings: settings, backend: backend, deviceProvider: { [] },
                                openURL: { opened.append($0) })
        c.openDonate()
        c.openPlaylist()
        c.openExternal("file:///etc/passwd")
        c.searchTrack("Simon & Garfunkel")
        #expect(opened.map(\.absoluteString) == [
            "https://kexp.org/donate/?source=patron_radio",
            "https://kexp.org/playlist/?source=patron_radio",
            "https://duckduckgo.com/?q=Simon%20%26%20Garfunkel",
        ])
    }

    // MARK: Fix tool & nearest station (network faked)

    @Test func fixReplacesTheStreamAndResetsLoudness() async {
        let json = #"[{"codec":"MP3","url":"https://new.kexp/stream"}]"#
        let c = make(fetch: (Data(json.utf8), 200))
        c.togglePlay()
        backend.fail("gone")
        c.primaryAction()
        #expect(c.playbackState == .fixing)
        await waitUntil { c.playbackState != .fixing }
        #expect(c.playbackState == .buffering)
        #expect(c.stations[0].url == "https://new.kexp/stream")
        #expect(c.stations[0].loudness == nil)
        #expect(backend.currentURL == "https://new.kexp/stream")
        #expect(backend.knownLoudness == nil)
        #expect(Station.decodeList(settings.stationsJSON)?[0].url == "https://new.kexp/stream")
    }

    @Test func fixFailureStaysBroken() async {
        let c = make(fetch: (Data("[]".utf8), 200))
        c.togglePlay()
        backend.fail("gone")
        c.fixCurrentStream()
        await waitUntil { c.playbackState != .fixing }
        #expect(c.playbackState == .broken)
        #expect(c.currentTrack == "Could not find a working replacement stream.")
    }

    @Test func nearestStationPlaysTheClosest() async {
        let geo = #"{"latitude":"40.72","longitude":"-74.09"}"# // Jersey City
        let c = make(fetch: (Data(geo.utf8), 200))
        c.playClosestStation()
        #expect(c.playbackState == .locating)
        await waitUntil { c.playbackState != .locating }
        #expect(c.currentStationName == "WFMU")
        #expect(c.playbackState == .buffering)
    }

    @Test func nearestStationOnStartupOnlySelects() async {
        settings.autoLocalStation = true
        let geo = #"{"latitude":"40.75","longitude":"-73.99"}"#
        let c = make(fetch: (Data(geo.utf8), 200))
        c.start()
        await waitUntil { c.playbackState != .locating }
        #expect(c.currentStationName == "New Sounds (WNYC)")
        #expect(c.playbackState == .stopped)
        #expect(backend.playCount == 0)
    }

    // MARK: Output routing

    @Test func priorityListPicksTheFirstConnectedOutput() {
        settings.outputPriority = [.init(id: "airpods", name: "AirPods"), .init(id: "builtin", name: "Speakers")]
        let c = make()
        c.refreshOutputs(initial: true)
        #expect(backend.outputPreference == .some("builtin"))

        let withAirPods = devices + [AudioOutputDevice(uid: "airpods", name: "AirPods", deviceID: 2, isBluetooth: true)]
        let c2 = make(devices: withAirPods)
        c2.refreshOutputs(initial: true)
        #expect(backend.outputPreference == .some("airpods"))
        #expect(settings.knownBluetoothDevices.map(\.id) == ["airpods"])
    }

    @Test func manualOverrideWinsUntilTheDeviceDisappears() {
        let c = make()
        c.refreshOutputs(initial: true)
        c.selectOutput(uid: "builtin")
        #expect(c.manualOutputUID == "builtin")
        c.selectAutomaticRouting()
        #expect(c.manualOutputUID == nil)
        #expect(backend.outputPreference == .some(nil))
    }

    @Test func losingTheActiveOutputPauses() {
        var devs = devices + [AudioOutputDevice(uid: "airpods", name: "AirPods", deviceID: 2, isBluetooth: true)]
        let c = RadioController(settings: settings, backend: backend, deviceProvider: { devs })
        c.refreshOutputs(initial: true)
        c.selectOutput(uid: "airpods")
        c.togglePlay()
        backend.startPlaying()

        devs.removeLast()
        c.refreshOutputs()
        #expect(c.playbackState == .stopped)
        #expect(!c.userRequestedPlayback)
        #expect(c.manualOutputUID == nil)
        #expect(backend.activeOutputUID == "builtin")
    }

    @Test func losingTheOutputKeepsPlayingWhenPauseIsOff() {
        settings.pauseOnDisconnect = false
        let c = make()
        c.refreshOutputs(initial: true)
        c.togglePlay()
        backend.startPlaying()
        backend.onEvent?(.outputLost)
        #expect(c.playbackState == .playing)
    }

    @Test func autoplayDeviceStartsPlaybackWhenItConnects() {
        settings.autoplayDevices = ["airpods"]
        var devs = devices
        let c = RadioController(settings: settings, backend: backend, deviceProvider: { devs })
        c.refreshOutputs(initial: true)
        #expect(c.playbackState == .stopped)

        devs.append(AudioOutputDevice(uid: "airpods", name: "AirPods", deviceID: 2, isBluetooth: true))
        c.refreshOutputs()
        #expect(c.playbackState == .buffering)
        #expect(backend.playCount >= 1)
    }

    @Test func settingsFlowIntoTheBackend() {
        let c = make()
        settings.normalizeLoudness = false
        settings.inhibitSleep = true
        c.settingsChanged()
        #expect(!backend.normalizeLoudness)
        #expect(backend.inhibitSleep)
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
