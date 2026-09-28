import Foundation
import Testing
@testable import PatronRadioCore

struct URLPolicyTests {
    @Test func onlyWebURLs() {
        #expect(URLPolicy.isWebURL("https://kexp.org/donate"))
        #expect(URLPolicy.isWebURL("HTTP://example.com"))
        #expect(!URLPolicy.isWebURL("file:///etc/passwd"))
        #expect(!URLPolicy.isWebURL("javascript:alert(1)"))
        #expect(!URLPolicy.isWebURL("smb://nas/share"))
        #expect(!URLPolicy.isWebURL("https://"))
        #expect(!URLPolicy.isWebURL(""))
    }

    @Test(arguments: [
        "http://127.0.0.1/", "http://10.0.0.5:8000/s", "http://192.168.1.1/", "http://172.20.0.1/",
        "http://169.254.169.254/latest/meta-data", "http://100.64.1.1/", "http://0.0.0.0/",
        "http://224.0.0.1/", "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/",
        "http://[::ffff:127.0.0.1]/", "ftp://radio.example.com/", "file:///tmp/x.mp3",
        // Legacy IPv4 literal forms getaddrinfo resolves: short, hex, octal,
        // single integer ("127.1" is 127.0.0.1; the octal quad is 169.254.169.254).
        "http://127.1/", "http://0x7f000001/", "http://2130706433/",
        "http://0251.0376.0251.0376/",
        // Scoped (zone id) and deprecated site-local IPv6.
        "http://[fe80::1%25en0]/", "http://[fec0::1]/",
    ])
    func blocksNonRoutableAndNonHTTP(_ s: String) {
        #expect(URLPolicy.isDisallowedStreamURL(URL(string: s)!))
    }

    @Test(arguments: [
        "https://kexp-mp3-128.streamguys1.com/kexp128.mp3", "http://8.8.8.8/stream",
        "http://[2606:4700::1111]/stream", "http://localhost.example.com/",
    ])
    func allowsPublicHosts(_ s: String) {
        #expect(!URLPolicy.isDisallowedStreamURL(URL(string: s)!))
    }

    @Test func tagsOutboundLinks() {
        #expect(URLPolicy.taggedOutboundURL("https://kexp.org/donate/") == "https://kexp.org/donate/?source=patron_radio")
        #expect(URLPolicy.taggedOutboundURL("https://x.org/?a=1") == "https://x.org/?a=1&source=patron_radio")
    }
}

struct ReconnectPolicyTests {
    @Test func backsOffExponentiallyAndCaps() {
        var p = ReconnectPolicy()
        var delays: [Int] = []
        while let d = p.nextDelayMS(random: { $0 / 2 }) { delays.append(d) }
        #expect(delays == [2000, 4000, 8000, 16000, 30000, 30000, 30000, 30000, 30000, 30000])
        #expect(p.attempts == ReconnectPolicy.maxAttempts)
    }

    @Test func jitterStaysWithinTwentyFivePercent() {
        for _ in 0..<200 {
            var p = ReconnectPolicy()
            let d = p.nextDelayMS()!
            #expect(d >= 1500 && d <= 2500)
        }
    }

    @Test func resetStartsOver() {
        var p = ReconnectPolicy()
        _ = p.nextDelayMS(); _ = p.nextDelayMS()
        p.reset()
        #expect(p.attempts == 0)
        #expect(p.nextDelayMS(random: { $0 / 2 }) == 2000)
    }
}

struct TrackHeuristicsTests {
    @Test func detectsStationBanners() {
        #expect(TrackHeuristics.isStationBanner("", stationName: "KEXP"))
        #expect(TrackHeuristics.isStationBanner("  - ", stationName: "KEXP"))
        #expect(TrackHeuristics.isStationBanner("KEXP", stationName: "KEXP"))
        #expect(TrackHeuristics.isStationBanner("New Sounds-", stationName: "New Sounds (WNYC)"))
        #expect(TrackHeuristics.isStationBanner("new sounds", stationName: "New Sounds (WNYC)"))
        #expect(!TrackHeuristics.isStationBanner("New Order - Blue Monday", stationName: "New Sounds (WNYC)"))
        #expect(!TrackHeuristics.isStationBanner("New", stationName: "Newsounds"))
        #expect(!TrackHeuristics.isStationBanner("Fresh Air", stationName: ""))
    }

    @Test func relativeTimes() {
        let now = Date()
        #expect(TrackHeuristics.relativeTime(from: now.addingTimeInterval(-30), now: now) == "now")
        #expect(TrackHeuristics.relativeTime(from: now.addingTimeInterval(-150), now: now) == "2m")
        #expect(TrackHeuristics.relativeTime(from: now.addingTimeInterval(-7300), now: now) == "2h")
        #expect(TrackHeuristics.relativeTime(from: now.addingTimeInterval(60), now: now) == "now")
    }
}

struct GeoTests {
    @Test func haversine() {
        // Seattle → New York ≈ 3,870 km.
        let d = Geo.distanceKM(lat1: 47.6062, lon1: -122.3321, lat2: 40.7484, lon2: -73.9857)
        #expect(abs(d - 3870) < 30)
        #expect(Geo.distanceKM(lat1: 10, lon1: 10, lat2: 10, lon2: 10) == 0)
    }

    @Test func closestSkipsStationsWithoutCoordinates() {
        let stations = [
            Station(name: "No coords", url: "https://a"),
            Station(name: "KEXP", url: "https://b", lat: 47.6062, lon: -122.3321),
            Station(name: "WFMU", url: "https://c", lat: 40.7282, lon: -74.0776),
        ]
        #expect(Geo.closestStationIndex(stations, lat: 40.7, lon: -74.0) == 2)
        #expect(Geo.closestStationIndex(stations, lat: 45.5, lon: -122.6) == 1)
        #expect(Geo.closestStationIndex([], lat: 0, lon: 0) == nil)
    }

    @Test func parsesGeoJS() {
        let json = #"{"latitude":"40.7128","longitude":"-74.0060","city":"New York"}"#
        let loc = Geo.parseGeoJS(Data(json.utf8))
        #expect(loc?.lat == 40.7128 && loc?.lon == -74.006)
        #expect(Geo.parseGeoJS(Data("nope".utf8)) == nil)
    }
}

struct RadioBrowserTests {
    @Test func cleansSearchNames() {
        #expect(RadioBrowser.searchName(for: "Radio 3 (RNE)") == "Radio 3")
        #expect(RadioBrowser.searchName(for: "KEXP 90.3FM") == "KEXP")
        #expect(RadioBrowser.searchName(for: "KEXP 90.3 fm") == "KEXP")
        #expect(RadioBrowser.searchName(for: "New Sounds (WNYC)") == "New Sounds")
        #expect(RadioBrowser.searchName(for: "WWOZ") == "WWOZ")
    }

    @Test func picksFirstSafePlayableResult() {
        let json = #"""
        [{"codec":"OGG","url":"https://a/ogg"},
         {"codec":"MP3","url":"file:///etc/passwd"},
         {"codec":"AAC+","url":"https://good/stream"},
         {"codec":"MP3","url":"https://later/stream"}]
        """#
        #expect(RadioBrowser.pickReplacement(Data(json.utf8)) == "https://good/stream")
        #expect(RadioBrowser.pickReplacement(Data("[]".utf8)) == nil)
        #expect(RadioBrowser.pickReplacement(Data("garbage".utf8)) == nil)
    }

    @Test func searchURLIsEncoded() {
        let u = RadioBrowser.searchURL(for: "WFMU Rock 'n' Soul")!.absoluteString
        #expect(u.hasPrefix("https://all.api.radio-browser.info/json/stations/search?name=WFMU%20Rock"))
        #expect(u.contains("hidebroken=true"))
    }
}

struct SearchEngineTests {
    @Test func encodesQueries() {
        let u = SearchEngine.duckDuckGo.url(for: "Simon & Garfunkel - The Boxer")!.absoluteString
        #expect(u == "https://duckduckgo.com/?q=Simon%20%26%20Garfunkel%20-%20The%20Boxer")
        #expect(SearchEngine.google.url(for: "   ") == nil)
    }
}
