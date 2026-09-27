import Foundation

/// Exponential backoff with ±25 % jitter and an attempt cap (RadioBackend::scheduleReconnect).
public struct ReconnectPolicy: Sendable {
    public static let initialMS = 2000
    public static let maxMS = 30000
    public static let maxAttempts = 10

    public private(set) var attempts = 0
    private var baseDelayMS = 0

    public init() {}

    public mutating func reset() { attempts = 0; baseDelayMS = 0 }

    /// Next delay in ms, or nil once the attempt cap is reached.
    public mutating func nextDelayMS(random: (Int) -> Int = { Int.random(in: 0..<max(1, $0)) }) -> Int? {
        guard attempts < ReconnectPolicy.maxAttempts else { return nil }
        attempts += 1
        baseDelayMS = baseDelayMS == 0 ? ReconnectPolicy.initialMS : min(baseDelayMS * 2, ReconnectPolicy.maxMS)
        // Jitter avoids a thundering herd on stream servers.
        let jitter = random(baseDelayMS / 2) - baseDelayMS / 4
        return baseDelayMS + jitter
    }
}

/// Now-playing history: the "playlist" of a live station, built from ICY titles.
public enum TrackHeuristics {
    /// Station IDs/banners flash for a few seconds between songs; only titles that
    /// stay current this long are committed to the history.
    public static let commitDelay: TimeInterval = 20
    public static let maxEntries = 12

    /// A StreamTitle that's really a station ID rather than a song: empty, the
    /// station name, or a whole-word leading portion of it ("New Sounds" from
    /// "New Sounds (WNYC)", which arrives as "New Sounds-").
    public static func isStationBanner(_ title: String, stationName: String) -> Bool {
        let t = normalize(title)
        if t.isEmpty { return true }
        let st = normalize(stationName)
        if st.isEmpty { return false }
        return t == st || st.hasPrefix(t + " ")
    }

    static func normalize(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s.lowercased().unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(ch)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// "now", "2m", "1h" — compact relative times for the recents strip.
    public static func relativeTime(from date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h"
    }
}

public struct TrackHistoryEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let startedAt: Date
    public init(title: String, startedAt: Date) { self.title = title; self.startedAt = startedAt }
    public static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.startedAt == b.startedAt }
}

/// Geography for "Play Nearest Station".
public enum Geo {
    public static func distanceKM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    public static func closestStationIndex(_ stations: [Station], lat: Double, lon: Double) -> Int? {
        var best: (Int, Double)?
        for (i, s) in stations.enumerated() {
            guard let sl = s.lat, let so = s.lon else { continue }
            let d = distanceKM(lat1: lat, lon1: lon, lat2: sl, lon2: so)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// Parses get.geojs.io's /v1/ip/geo.json (latitude/longitude arrive as strings).
    public static func parseGeoJS(_ data: Data) -> (lat: Double, lon: Double)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let s = v as? String { return Double(s) }
            return nil
        }
        guard let lat = num(obj["latitude"]), let lon = num(obj["longitude"]) else { return nil }
        return (lat, lon)
    }
}

/// radio-browser.info lookups for the "Fix" tool.
public enum RadioBrowser {
    /// Strip qualifiers that hurt directory matching: a trailing parenthesized
    /// network ("Radio 3 (RNE)") or FM frequency ("KEXP 90.3FM").
    public static func searchName(for stationName: String) -> String {
        var s = stationName
        if let r = s.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"\s+\d+(\.\d+)?\s*FM$"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    public static func searchURL(for stationName: String) -> URL? {
        // all.api round-robins across the project's mirrors; don't pin one.
        var c = URLComponents(string: "https://all.api.radio-browser.info/json/stations/search")!
        c.queryItems = [
            URLQueryItem(name: "name", value: searchName(for: stationName)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        return c.url
    }

    /// First playable MP3/AAC result. Results come from a public, community-
    /// editable directory, so only http(s) URLs are accepted.
    public static func pickReplacement(_ data: Data) -> String? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for entry in arr {
            let codec = (entry["codec"] as? String ?? "").uppercased()
            let url = entry["url"] as? String ?? ""
            guard URLPolicy.isWebURL(url) else { continue }
            if codec == "MP3" || codec == "AAC" || codec == "AAC+" { return url }
        }
        return nil
    }
}

/// Where "search the web for this track" goes. macOS has no system-wide default
/// search engine API (the widget uses KDE web shortcuts), so it's a setting.
public enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case duckDuckGo, google, bing, kagi, startpage
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        case .startpage: return "Startpage"
        }
    }
    public func url(for query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/?q="
        case .google: base = "https://www.google.com/search?q="
        case .bing: base = "https://www.bing.com/search?q="
        case .kagi: base = "https://kagi.com/search?q="
        case .startpage: base = "https://www.startpage.com/do/search?q="
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return URL(string: base + (q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q))
    }
}
