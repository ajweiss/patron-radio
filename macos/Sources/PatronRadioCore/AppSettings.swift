import Foundation
import Observation

/// Persistent preferences. Keys and meanings follow the widget's config schema
/// (contents/config/main.xml); macOS-only additions are marked.
@MainActor
@Observable
public final class AppSettings {
    public enum SubtitleMode: Int, CaseIterable, Identifiable, Sendable {
        case city = 0, track = 1, alternate = 2
        public var id: Int { rawValue }
        public var label: String {
            switch self {
            case .city: return "Station city"
            case .track: return "Stream title"
            case .alternate: return "Alternate city and title"
            }
        }
    }

    public enum WidthMode: Int, CaseIterable, Identifiable, Sendable {
        case fixed = 0, autoStationCity = 1, autoEverything = 2
        public var id: Int { rawValue }
        public var label: String {
            switch self {
            case .fixed: return "Fixed width"
            case .autoStationCity: return "Auto-fit station & city"
            case .autoEverything: return "Auto-fit everything"
            }
        }
    }

    /// macOS addition: the menu bar can show just an icon.
    public enum MenuBarStyle: Int, CaseIterable, Identifiable, Sendable {
        case stationInfo = 0, iconOnly = 1
        public var id: Int { rawValue }
        public var label: String { self == .stationInfo ? "Station info" : "Icon only" }
    }

    public struct OutputPreference: Codable, Equatable, Hashable, Sendable {
        public var id: String   // CoreAudio device UID
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var currentStationURL: String { didSet { set(currentStationURL, "currentStationURL") } }
    public var autoLocalStation: Bool { didSet { set(autoLocalStation, "autoLocalStation") } }
    public var autoplayOnStartup: Bool { didSet { set(autoplayOnStartup, "autoplayOnStartup") } }
    public var resumePlaybackOnRestart: Bool { didSet { set(resumePlaybackOnRestart, "resumePlaybackOnRestart") } }
    public var wasPlaying: Bool { didSet { set(wasPlaying, "wasPlaying") } }
    /// Output device UIDs that start playback when they connect (widget: Bluetooth MACs).
    public var autoplayDevices: [String] { didSet { set(autoplayDevices, "autoplayBluetoothDevices") } }
    public var pauseOnDisconnect: Bool { didSet { set(pauseOnDisconnect, "pauseOnBtDisconnect") } }
    public var inhibitSleep: Bool { didSet { set(inhibitSleep, "inhibitSleep") } }
    public var normalizeLoudness: Bool { didSet { set(normalizeLoudness, "normalizeLoudness") } }
    public var loudnessAuto: Bool { didSet { set(loudnessAuto, "loudnessAuto") } }
    public var outputPriority: [OutputPreference] { didSet { setJSON(outputPriority, "outputPriorityDevices") } }
    public var subtitleMode: SubtitleMode { didSet { set(subtitleMode.rawValue, "compactSubtitleMode") } }
    public var widthMode: WidthMode { didSet { set(widthMode.rawValue, "widthMode") } }
    /// Fixed menu bar width in points (the widget uses grid units).
    public var fixedWidth: Double { didSet { set(fixedWidth, "compactWidthPoints") } }
    public var menuBarStyle: MenuBarStyle { didSet { set(menuBarStyle.rawValue, "menuBarStyle") } }
    public var searchEngine: SearchEngine { didSet { set(searchEngine.rawValue, "searchEngine") } }
    /// Bluetooth outputs seen before, so autoplay triggers can be set while they're off.
    public var knownBluetoothDevices: [OutputPreference] { didSet { setJSON(knownBluetoothDevices, "knownBluetoothDevices") } }
    public var stationsJSON: String { didSet { set(stationsJSON, "stationsJson") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        func json<T: Decodable>(_ k: String, _ d: T) -> T {
            guard let s = defaults.string(forKey: k), let data = s.data(using: .utf8),
                  let v = try? JSONDecoder().decode(T.self, from: data) else { return d }
            return v
        }
        currentStationURL = defaults.string(forKey: "currentStationURL") ?? ""
        autoLocalStation = bool("autoLocalStation", false)
        autoplayOnStartup = bool("autoplayOnStartup", false)
        resumePlaybackOnRestart = bool("resumePlaybackOnRestart", true)
        wasPlaying = bool("wasPlaying", false)
        autoplayDevices = defaults.stringArray(forKey: "autoplayBluetoothDevices") ?? []
        pauseOnDisconnect = bool("pauseOnBtDisconnect", true)
        inhibitSleep = bool("inhibitSleep", true)
        normalizeLoudness = bool("normalizeLoudness", true)
        loudnessAuto = bool("loudnessAuto", true)
        outputPriority = json("outputPriorityDevices", [OutputPreference]())
        // Default to the stream title (falls back to the city until one arrives).
        subtitleMode = SubtitleMode(rawValue: defaults.object(forKey: "compactSubtitleMode") as? Int ?? 1) ?? .track
        widthMode = WidthMode(rawValue: defaults.object(forKey: "widthMode") as? Int ?? 1) ?? .autoStationCity
        fixedWidth = defaults.object(forKey: "compactWidthPoints") as? Double ?? 110
        menuBarStyle = MenuBarStyle(rawValue: defaults.integer(forKey: "menuBarStyle")) ?? .stationInfo
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .duckDuckGo
        knownBluetoothDevices = json("knownBluetoothDevices", [OutputPreference]())
        stationsJSON = defaults.string(forKey: "stationsJson") ?? Station.defaultStationsJSON
    }

    private func set(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    private func setJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(String(decoding: data, as: UTF8.self), forKey: key) }
    }
}
