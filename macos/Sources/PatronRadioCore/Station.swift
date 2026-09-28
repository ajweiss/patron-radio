import Foundation

/// The kind of programming a station carries. Stored in JSON as the KDE icon
/// name the Plasma widget uses, so station lists move between the two apps
/// unchanged.
public enum StationKind: String, CaseIterable, Codable, Sendable {
    case music = "emblem-music-symbolic"
    case talk = "mic-on-symbolic"
    case mixed = "mixed-composite"

    public var label: String {
        switch self {
        case .music: return "Music"
        case .talk: return "Talk / Arts"
        case .mixed: return "Mixed / Variety"
        }
    }

    /// Unknown icon names (e.g. "audio-x-generic" from older lists) read as music,
    /// matching the widget's station-type combo box.
    public init(iconName: String?) {
        self = StationKind(rawValue: iconName ?? "") ?? .music
    }
}

/// One radio station. Field names and JSON shape match the Plasma widget's
/// `stationsJson` config entry exactly.
public struct Station: Identifiable, Equatable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var city: String
    public var url: String
    public var website: String
    public var donate: String
    public var kind: StationKind
    public var lat: Double?
    public var lon: Double?
    /// Measured (or hand-set) integrated loudness in LUFS; nil = not measured yet.
    public var loudness: Double?

    public init(name: String, city: String = "", url: String, website: String = "", donate: String = "",
                kind: StationKind = .music, lat: Double? = nil, lon: Double? = nil, loudness: Double? = nil) {
        self.name = name
        self.city = city
        self.url = url
        self.website = website
        self.donate = donate
        self.kind = kind
        self.lat = lat
        self.lon = lon
        self.loudness = loudness
    }

    public static func == (a: Station, b: Station) -> Bool {
        a.name == b.name && a.city == b.city && a.url == b.url && a.website == b.website
            && a.donate == b.donate && a.kind == b.kind && a.lat == b.lat && a.lon == b.lon
            && a.loudness == b.loudness
    }

    public func hash(into h: inout Hasher) { h.combine(url); h.combine(name) }
}

extension Station: Codable {
    private enum Keys: String, CodingKey { case name, city, url, website, donate, icon, lat, lon, loudness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        city = (try? c.decode(String.self, forKey: .city)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        website = (try? c.decode(String.self, forKey: .website)) ?? ""
        donate = (try? c.decode(String.self, forKey: .donate)) ?? ""
        kind = StationKind(iconName: try? c.decode(String.self, forKey: .icon))
        lat = Station.lenientDouble(c, .lat)
        lon = Station.lenientDouble(c, .lon)
        let l = Station.lenientDouble(c, .loudness)
        loudness = (l?.isFinite ?? false) ? l : nil
    }

    // The widget's settings page can leave coordinates as "" or as numeric strings.
    private static func lenientDouble(_ c: KeyedDecodingContainer<Keys>, _ k: Keys) -> Double? {
        if let d = try? c.decode(Double.self, forKey: k) { return d }
        if let s = try? c.decode(String.self, forKey: k) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(city, forKey: .city)
        try c.encode(url, forKey: .url)
        try c.encode(website, forKey: .website)
        try c.encode(donate, forKey: .donate)
        try c.encode(kind.rawValue, forKey: .icon)
        try c.encodeIfPresent(lat, forKey: .lat)
        try c.encodeIfPresent(lon, forKey: .lon)
        if let loudness, loudness.isFinite { try c.encode(loudness, forKey: .loudness) }
    }
}

extension Station {
    public static func decodeList(_ json: String) -> [Station]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Station].self, from: data)
    }

    public static func encodeList(_ stations: [Station], pretty: Bool = false) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        guard let data = try? enc.encode(stations) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static var defaults: [Station] { decodeList(defaultStationsJSON) ?? [] }

    /// A template row for "Add New Station", like the widget's.
    public static func newTemplate() -> Station {
        Station(name: "New Station", city: "City, ST", url: "https://")
    }
}
