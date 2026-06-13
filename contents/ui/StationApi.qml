import QtQuick
import org.kde.plasma.plasmoid

import "../imports/com/signal11/patronradio" as RadioBackendModule

Item {
    id: stationApi

    function fixCurrentStream() {
        if (root.playbackState === root.stateFixing) return;
        var stationName = root.currentStationName;
        var searchName = stationName.replace(" 90.3FM", "").replace(" 106.7FM", "").replace(" (RNE)", "").trim();
        root.playbackState = root.stateFixing;
        root.currentTrack = "Searching for new stream...";
        var apiUrl = "https://de1.api.radio-browser.info/json/stations/search?name=" + encodeURIComponent(searchName) + "&hidebroken=true&order=clickcount&reverse=true&limit=3";
        var xhr = new XMLHttpRequest();
        xhr.open("GET", apiUrl, true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200) {
                    try {
                        var response = JSON.parse(xhr.responseText);
                        var foundUrl = "";
                        for (var i = 0; i < response.length; i++) {
                            var codec = (response[i].codec || "").toUpperCase();
                            var candidateUrl = response[i].url || "";
                            // Results come from a public, community-editable directory:
                            // only accept http(s) so a malicious entry can't smuggle in
                            // file:// or other schemes.
                            if (!/^https?:\/\//i.test(candidateUrl)) continue;
                            if (codec === "MP3" || codec === "AAC" || codec === "AAC+") { foundUrl = candidateUrl; break; }
                        }
                        if (foundUrl !== "") {
                            root.stationModel.setProperty(root.currentStationIndex, "url", foundUrl);
                            // New stream URL -> old loudness no longer applies; re-measure.
                            root.stationModel.setProperty(root.currentStationIndex, "loudness", NaN);
                            root.saveStations();
                            root.currentTrack = "";
                            root.playbackState = root.stateBuffering;
                            RadioBackendModule.RadioBackend.knownLoudness = NaN;
                            RadioBackendModule.RadioBackend.currentUrl = foundUrl;
                            RadioBackendModule.RadioBackend.play();
                        } else { root.playbackState = root.stateBroken; root.currentTrack = "Could not find a working replacement stream."; }
                    } catch(e) { root.playbackState = root.stateBroken; root.currentTrack = "Error parsing search results."; }
                } else { root.playbackState = root.stateBroken; root.currentTrack = "Search directory is currently offline."; }
            }
        }
        xhr.send();
    }

    function deg2rad(deg) { return deg * (Math.PI / 180); }

    function getDistanceFromLatLonInKm(lat1, lon1, lat2, lon2) {
        var R = 6371;
        var dLat = deg2rad(lat2 - lat1);
        var dLon = deg2rad(lon2 - lon1);
        var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(deg2rad(lat1)) * Math.cos(deg2rad(lat2)) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    }

    function updateClosestStation(forcePlay) {
        if (root.playbackState === root.stateLocating) return;
        root.playbackState = root.stateLocating;
        var xhr = new XMLHttpRequest();
        xhr.open("GET", "https://get.geojs.io/v1/ip/geo.json?cachebust=" + new Date().getTime(), true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (root.playbackState === root.stateLocating) root.playbackState = root.stateStopped;
                if (xhr.status === 200) {
                    try {
                        var response = JSON.parse(xhr.responseText);
                        var userLat = parseFloat(response.latitude);
                        var userLon = parseFloat(response.longitude);
                        var closestIndex = -1;
                        var minDistance = Infinity;
                        for (var i = 0; i < root.stationModel.count; i++) {
                            var st = root.stationModel.get(i);
                            if (st.lat !== undefined && st.lon !== undefined && st.lat !== "" && st.lon !== "") {
                                var d = getDistanceFromLatLonInKm(userLat, userLon, st.lat, st.lon);
                                if (d < minDistance) { minDistance = d; closestIndex = i; }
                            }
                        }
                        if (closestIndex !== -1) {
                            if (forcePlay) { root.playStation(closestIndex); }
                            else if (closestIndex !== root.currentStationIndex) { if (!root.isPlaying) { root.currentStationIndex = closestIndex; } }
                        }
                    } catch(e) {
                        root.errorMessage = "Geolocation response could not be parsed.";
                    }
                } else {
                    root.errorMessage = "Geolocation service unavailable.";
                }
            }
        }
        xhr.send();
    }

    function playClosestStation() { updateClosestStation(true); }
}
