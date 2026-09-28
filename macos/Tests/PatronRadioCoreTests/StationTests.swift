import Foundation
import Testing
@testable import PatronRadioCore

struct StationTests {
    @Test func defaultListMatchesTheWidget() {
        let s = Station.defaults
        #expect(s.count == 28)
        #expect(s.first?.name == "KEXP")
        #expect(s.allSatisfy { URLPolicy.isWebURL($0.url) && $0.lat != nil && $0.lon != nil && $0.loudness != nil })
        #expect(s.first { $0.name == "WNYC" }?.kind == .talk)
        #expect(s.first { $0.name == "KCRW" }?.kind == .mixed)
    }

    /// contents/config/main.xml is the source of truth; DefaultStations.swift is
    /// generated from it by scripts/sync-stations.sh. Fails if they drift apart.
    @Test func defaultListMatchesTheWidgetConfigSchema() throws {
        let xmlURL = SharedVectors.repoRoot.appendingPathComponent("contents/config/main.xml")
        let xml = try String(contentsOf: xmlURL, encoding: .utf8)
        let open = try #require(xml.range(of: #"<entry name="stationsJson" type="String">\s*<default>"#,
                                          options: .regularExpression))
        let close = try #require(xml.range(of: "</default>", range: open.upperBound..<xml.endIndex))
        let widget = try #require(Station.decodeList(String(xml[open.upperBound..<close.lowerBound])))
        #expect(widget == Station.defaults, "Run macos/scripts/sync-stations.sh to regenerate DefaultStations.swift")
    }

    @Test func roundTripsThroughWidgetJSON() {
        let original = Station.defaults
        let json = Station.encodeList(original)
        #expect(Station.decodeList(json) == original)
        // Same keys the Plasma widget writes.
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        #expect(Set(obj[0].keys) == ["name", "city", "url", "website", "donate", "icon", "lat", "lon", "loudness"])
        #expect(obj[0]["icon"] as? String == "emblem-music-symbolic")
    }

    @Test func decodesLenientlyLikeTheWidgetSettingsPage() {
        let json = #"""
        [{"name":"A","city":"X","url":"https://a","lat":"","lon":"12.5","icon":"audio-x-generic"},
         {"name":"B","url":"https://b","lat":1,"lon":2,"loudness":null}]
        """#
        let s = Station.decodeList(json)!
        #expect(s[0].lat == nil && s[0].lon == 12.5)
        #expect(s[0].kind == .music)          // unknown icon → Music
        #expect(s[1].city == "" && s[1].website == "" && s[1].loudness == nil)
    }

    @Test func omitsUnknownLoudness() {
        let json = Station.encodeList([Station(name: "X", url: "https://x")])
        #expect(!json.contains("loudness"))
        #expect(!json.contains("lat"))
    }

    @Test func rejectsNonLists() {
        #expect(Station.decodeList("{}") == nil)
        #expect(Station.decodeList("not json") == nil)
    }
}
