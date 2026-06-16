import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

import "../imports/com/signal11/patronradio" as RadioBackendModule

PlasmoidItem {
    id: root

    // --- Playback State Machine ---
    readonly property int stateStopped: 0
    readonly property int stateBuffering: 1
    readonly property int statePlaying: 2
    readonly property int stateBroken: 3
    readonly property int stateFixing: 4
    readonly property int stateLocating: 5
    property int playbackState: stateStopped
    // Rebuild the context menu on every state change so the playback action
    // reflects the current state (e.g. "Fix Broken Stream" once a stream
    // breaks). The menu is a static list, so it only updates when we ask it to.
    onPlaybackStateChanged: contextActions.update()

    // Computed aliases for child QML files
    readonly property bool isPlaying: playbackState === statePlaying
    readonly property bool isBuffering: playbackState === stateBuffering
    readonly property bool isBroken: playbackState === stateBroken
    readonly property bool isFixing: playbackState === stateFixing
    readonly property bool isLocating: playbackState === stateLocating

    property int currentStationIndex: Plasmoid.configuration.defaultStation
    onCurrentStationIndexChanged: {
        Plasmoid.configuration.defaultStation = currentStationIndex
    }

    // True only when currentStationIndex is a valid row — guards against the model
    // being mid-load (count between 1 and the index) where get() returns undefined.
    readonly property bool hasCurrentStation: currentStationIndex >= 0 && currentStationIndex < stationModel.count
    property string currentStationName: hasCurrentStation ? stationModel.get(currentStationIndex).name : ""
    property string currentStationCity: hasCurrentStation ? stationModel.get(currentStationIndex).city : ""
    property string currentStationIcon: hasCurrentStation ? stationModel.get(currentStationIndex).icon : "radio"
    property string currentStationWebsite: hasCurrentStation ? (stationModel.get(currentStationIndex).website || "") : ""
    property string currentStationDonate: hasCurrentStation ? (stationModel.get(currentStationIndex).donate || "") : ""
    property string currentTrack: ""
    property string streamCodec: ""
    property string streamBitrate: ""
    property string errorMessage: ""
    property bool userRequestedPlayback: false

    // Expose stationModel so child components can access it
    property alias stationModel: stationModel

    toolTipMainText: isLocating ? "Locating Station..." : (isFixing ? "Finding new stream..." : (isPlaying ? "Playing: " + currentStationName : (isBroken ? "Stream Offline" : "Patron Radio")))
    toolTipSubText: {
        if (isLocating) return "Finding closest local station...";
        if (isFixing) return "Searching radio-browser.info for a working stream...";
        if (isBroken) {
            var msg = currentStationName + " stream is currently unavailable.";
            if (errorMessage) msg += " (" + errorMessage + ")";
            msg += " Click 'Fix' to search for a new URL.";
            return msg;
        }
        var status = isPlaying ? "Playing" : (isBuffering ? "Buffering" : "Stopped");
        var info = currentStationName;
        if (currentStationCity !== "") info += " from " + currentStationCity;
        var sub = status + " " + info;
        if (currentTrack !== "") sub += "\nNow Playing: " + currentTrack;
        var techInfo = [];
        if (streamCodec !== "") techInfo.push(streamCodec);
        if (streamBitrate !== "") techInfo.push(streamBitrate);
        if (techInfo.length > 0) sub += "\n[" + techInfo.join(" @ ") + "]";
        return sub;
    }

    // --- Sub-components ---
    AudioRouter { id: audioRouter }
    StationApi { id: stationApi }
    ContextActions {
        id: contextActions
        Component.onCompleted: contextActions.update()
    }

    // --- Backend Connections ---
    Connections {
        target: RadioBackendModule.RadioBackend
        function onStreamTitleChanged() {
            var t = RadioBackendModule.RadioBackend.streamTitle;
            root.currentTrack = t;          // header updates immediately
            root.queueTrack(t);             // history is debounced (see below)
        }
        function onLastErrorChanged() {
            var err = RadioBackendModule.RadioBackend.lastError;
            if (err) {
                root.errorMessage = err;
                root.playbackState = root.stateBroken;
            } else {
                root.errorMessage = "";
            }
        }
        function onPlayingChanged() {
            if (RadioBackendModule.RadioBackend.playing) {
                root.playbackState = root.statePlaying;
            } else if (root.playbackState === root.statePlaying) {
                root.playbackState = root.stateStopped;
            }
            contextActions.update();
        }
        function onBufferingChanged() {
            if (RadioBackendModule.RadioBackend.buffering && root.playbackState !== root.statePlaying) {
                root.playbackState = root.stateBuffering;
            }
        }
        function onMeasuredLoudnessChanged() {
            var lufs = RadioBackendModule.RadioBackend.measuredLoudness;
            if (isNaN(lufs)) return;
            if (root.currentStationIndex < 0 || root.currentStationIndex >= stationModel.count) return;
            stationModel.setProperty(root.currentStationIndex, "loudness", lufs);
            root.persistStationsSoon();
        }
        function onNextRequested() {
            if (stationModel.count > 0) {
                root.playStation((root.currentStationIndex + 1) % stationModel.count);
            }
        }
        function onPreviousRequested() {
            if (stationModel.count > 0) {
                root.playStation((root.currentStationIndex - 1 + stationModel.count) % stationModel.count);
            }
        }
    }

    Connections {
        target: audioRouter
        function onRoutingChanged() { contextActions.update(); }
    }

    Connections {
        target: Plasmoid.configuration
        function onAutoLocalStationChanged() { if (Plasmoid.configuration.autoLocalStation) stationApi.updateClosestStation(false); }
        function onStationsJsonChanged() { root.syncStations(); }
    }

    // --- Playback Control ---
    function togglePlay() {
        if (isPlaying) {
            userRequestedPlayback = false;
            RadioBackendModule.RadioBackend.stop();
            playbackState = stateStopped;
            Plasmoid.configuration.wasPlaying = false;
        } else {
            userRequestedPlayback = true;
            clearTrackHistory();
            playbackState = stateBuffering;
            var station = stationModel.get(currentStationIndex);
            RadioBackendModule.RadioBackend.currentStationName = station.name;
            RadioBackendModule.RadioBackend.knownLoudness = stationLoudness(station);
            RadioBackendModule.RadioBackend.currentUrl = station.url;
            audioRouter.applyBestAudioRouting();
            RadioBackendModule.RadioBackend.play();
            Plasmoid.configuration.wasPlaying = true;
        }
    }

    function playStation(index) {
        if (currentStationIndex !== index || (!isPlaying && !isBroken)) {
            userRequestedPlayback = true;
            currentStationIndex = index;
            clearTrackHistory();
            currentTrack = "";
            streamCodec = "";
            streamBitrate = "";
            playbackState = stateBuffering;
            RadioBackendModule.RadioBackend.currentStationName = stationModel.get(index).name;
            RadioBackendModule.RadioBackend.knownLoudness = stationLoudness(stationModel.get(index));
            RadioBackendModule.RadioBackend.currentUrl = stationModel.get(index).url;
            audioRouter.applyBestAudioRouting();
            RadioBackendModule.RadioBackend.play();
            Plasmoid.configuration.wasPlaying = true;
        }
    }

    function fixCurrentStream() { stationApi.fixCurrentStream(); }
    function playClosestStation() { stationApi.playClosestStation(); }

    // Station website/donate links come from (potentially user-edited) config.
    // Only hand http(s) URLs to the desktop URL handler so a malformed entry
    // can't launch an arbitrary URI-scheme handler.
    function openExternalUrl(url) {
        if (typeof url !== "string" || !/^https?:\/\//i.test(url)) {
            console.warn("Patron Radio: refusing to open non-HTTP(S) URL:", url);
            return;
        }
        Qt.openUrlExternally(url);
    }

    // --- Station Data ---
    ListModel { id: stationModel }

    // --- Now-playing track history (the "playlist" for live radio) ---
    // Built from the stream's ICY StreamTitle changes; index 0 is the current
    // track. Reset whenever the station changes.
    ListModel { id: trackHistory }
    property string _lastHistTrack: ""
    property string _pendingTrack: ""

    // Defer committing a title to the history until it has been the current track
    // for a while. Real songs persist for minutes; transient between-song station
    // IDs/banners flash for a few seconds and get filtered out this way.
    Timer {
        id: histCommitTimer
        interval: 20000
        onTriggered: root.commitTrack(root._pendingTrack)
    }
    function queueTrack(title) {
        _pendingTrack = title;
        if (title) histCommitTimer.restart(); else histCommitTimer.stop();
    }
    function commitTrack(title) {
        if (!title || title === _lastHistTrack) return;
        if (title === root.currentStationName) return; // station name as title, not a song
        _lastHistTrack = title;
        trackHistory.insert(0, { "title": title, "at": Date.now() });
        while (trackHistory.count > 12) trackHistory.remove(trackHistory.count - 1);
    }
    function clearTrackHistory() {
        trackHistory.clear();
        _lastHistTrack = "";
        _pendingTrack = "";
        histCommitTimer.stop();
    }

    // Drives relative timestamps ("2m") in the popup; only ticks while it's open.
    property double histNow: Date.now()
    Timer { interval: 30000; repeat: true; running: root.expanded; onTriggered: root.histNow = Date.now() }
    function relTime(at) {
        var s = Math.max(0, Math.floor((root.histNow - at) / 1000));
        if (s < 60) return "now";
        var m = Math.floor(s / 60);
        if (m < 60) return m + "m";
        return Math.floor(m / 60) + "h";
    }

    // Per-station loudness (LUFS) for normalization. NaN means "not measured yet".
    function stationLoudness(st) {
        return (st && typeof st.loudness === "number" && !isNaN(st.loudness)) ? st.loudness : NaN;
    }

    function loadStations() {
        // currentStationIndex is positional, but the list can be reordered in
        // settings (new stations insert at the top, deletes shift everything).
        // Remember the current station by URL so it stays selected across reloads
        // instead of the index silently pointing at a different station.
        var prevUrl = hasCurrentStation ? stationModel.get(currentStationIndex).url : "";

        stationModel.clear();
        try {
            var stations = JSON.parse(Plasmoid.configuration.stationsJson || "[]");
            for (var i = 0; i < stations.length; i++) {
                var s = stations[i];
                // Ensure the 'loudness' role exists (ListModel fixes roles from row 0).
                if (typeof s.loudness !== "number") s.loudness = NaN;
                stationModel.append(s);
            }
        } catch (e) {}

        if (prevUrl) {
            for (var k = 0; k < stationModel.count; k++) {
                if (stationModel.get(k).url === prevUrl) { currentStationIndex = k; break; }
            }
        }
        if (currentStationIndex >= stationModel.count) currentStationIndex = 0;
    }

    // Apply an external stationsJson change. If the station set + order is
    // unchanged (e.g. the widget's own loudness auto-save, or an in-popup edit),
    // update fields in place — a full clear+rebuild momentarily empties the model
    // and resets the popup list's selection. Only the rare structural change
    // (add/delete/reorder/url edit) does a full reload.
    function syncStations() {
        var stations;
        try { stations = JSON.parse(Plasmoid.configuration.stationsJson || "[]"); }
        catch (e) { return; }

        var sameShape = (stations.length === stationModel.count);
        for (var i = 0; sameShape && i < stations.length; i++) {
            if (stationModel.get(i).url !== stations[i].url) sameShape = false;
        }
        if (!sameShape) { loadStations(); return; }

        for (var j = 0; j < stations.length; j++) {
            var s = stations[j];
            var m = stationModel.get(j);
            var lo = (typeof s.loudness === "number") ? s.loudness : NaN;
            if (!(m.loudness === lo || (isNaN(m.loudness) && isNaN(lo)))) stationModel.setProperty(j, "loudness", lo);
            if (m.name !== s.name) stationModel.setProperty(j, "name", s.name);
            if (m.city !== s.city) stationModel.setProperty(j, "city", s.city);
            if (m.website !== (s.website || "")) stationModel.setProperty(j, "website", s.website || "");
            if (m.donate !== (s.donate || "")) stationModel.setProperty(j, "donate", s.donate || "");
            if (m.icon !== (s.icon || "")) stationModel.setProperty(j, "icon", s.icon || "");
        }
    }

    // Persist the station list (including learned loudness) back to config.
    function saveStations() {
        var arr = [];
        for (var j = 0; j < stationModel.count; j++) {
            var m = stationModel.get(j);
            var o = {
                "name": m.name, "city": m.city, "url": m.url, "website": m.website,
                "donate": m.donate, "icon": m.icon, "lat": m.lat, "lon": m.lon
            };
            if (typeof m.loudness === "number" && !isNaN(m.loudness)) o.loudness = m.loudness;
            arr.push(o);
        }
        Plasmoid.configuration.stationsJson = JSON.stringify(arr);
    }

    // Debounce config writes — loudness updates arrive every few hundred ms.
    Timer { id: saveStationsTimer; interval: 4000; onTriggered: root.saveStations() }
    function persistStationsSoon() { saveStationsTimer.restart(); }

    // --- Initialization ---
    Binding {
        target: RadioBackendModule.RadioBackend
        property: "inhibitSleep"
        value: Plasmoid.configuration.inhibitSleep
    }
    Binding {
        target: RadioBackendModule.RadioBackend
        property: "normalizeLoudness"
        value: Plasmoid.configuration.normalizeLoudness
    }
    Binding {
        target: RadioBackendModule.RadioBackend
        property: "loudnessAuto"
        value: Plasmoid.configuration.loudnessAuto
    }

    Component.onCompleted: {
        loadStations();
        audioRouter.applyBestAudioRouting();
        contextActions.update();

        var autoLocal = Plasmoid.configuration.autoLocalStation;
        var autoPlay = Plasmoid.configuration.autoplayOnStartup;
        var resumePlay = Plasmoid.configuration.resumePlaybackOnRestart && Plasmoid.configuration.wasPlaying;

        if (autoLocal) stationApi.updateClosestStation(autoPlay || resumePlay);
        else if (autoPlay || resumePlay) playStation(currentStationIndex);
    }

    compactRepresentation: Component { CompactRepresentation {} }
    fullRepresentation: Component { FullRepresentation {} }
}
