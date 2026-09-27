import AVFoundation
import Foundation
import IOKit.pwr_mgt

public enum BackendEvent: Equatable, Sendable {
    case playingChanged
    case bufferingChanged
    case streamTitleChanged
    case lastErrorChanged
    case measuredLoudnessChanged
    case streamInfoChanged
    case outputLost
}

/// What the playback controller needs from the audio backend. The real one is
/// `RadioBackend`; tests drive the controller with a fake.
@MainActor
public protocol RadioBackendProtocol: AnyObject {
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var streamTitle: String { get }
    var currentURL: String { get }
    var lastError: String { get }
    var measuredLoudness: Double? { get }
    var streamInfo: StreamInfo? { get }
    var activeOutputUID: String? { get }

    var currentStationName: String { get set }
    /// Last-known loudness (LUFS) of the station about to play, so it starts at
    /// the right level instantly. Applied at the next URL change.
    var knownLoudness: Double? { get set }
    var normalizeLoudness: Bool { get set }
    var loudnessAuto: Bool { get set }
    var inhibitSleep: Bool { get set }
    var onEvent: ((BackendEvent) -> Void)? { get set }

    func setCurrentURL(_ url: String)
    func play()
    func stop()
    /// nil follows the system default output.
    func setOutputPreference(uid: String?)
}

/// Port of the widget's C++ RadioBackend: owns the stream session, reconnect
/// with backoff, the stall watchdog, loudness normalization and the sleep lock.
@MainActor
public final class RadioBackend: RadioBackendProtocol {
    public private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { playingDidChange() } }
    }
    public private(set) var isBuffering = false {
        didSet { if oldValue != isBuffering { onEvent?(.bufferingChanged) } }
    }
    public private(set) var streamTitle = "" {
        didSet { if oldValue != streamTitle { onEvent?(.streamTitleChanged) } }
    }
    public private(set) var currentURL = ""
    public private(set) var lastError = ""
    public private(set) var measuredLoudness: Double?
    public private(set) var streamInfo: StreamInfo? {
        didSet { if oldValue != streamInfo { onEvent?(.streamInfoChanged) } }
    }
    public private(set) var activeOutputUID: String?

    public var currentStationName = ""
    public var knownLoudness: Double?
    public var onEvent: ((BackendEvent) -> Void)?

    public var normalizeLoudness = true {
        didSet {
            guard oldValue != normalizeLoudness else { return }
            meter.reset(enabled: normalizeLoudness && loudnessAuto)
            if !normalizeLoudness { normGainDB = 0; applyVolume() } // back to full level immediately
        }
    }
    /// When false, levels aren't measured: stored/manual values apply but are never overwritten.
    public var loudnessAuto = true {
        didSet {
            guard oldValue != loudnessAuto else { return }
            meter.reset(enabled: normalizeLoudness && loudnessAuto)
        }
    }
    public var inhibitSleep = false {
        didSet {
            if inhibitSleep && isPlaying { takeSleepLock() } else if !inhibitSleep { releaseSleepLock() }
        }
    }
    /// User volume (0...1); normalization attenuates below it.
    public var volume = 1.0 { didSet { applyVolume() } }

    static let stallTimeout: TimeInterval = 7

    private var session: StreamSession?
    private var sessionID = 0
    private let meter = SharedLoudnessMeter()
    private var reconnect = ReconnectPolicy()
    private var reconnectTimer: Timer?
    private var stallTimer: Timer?
    private var loudnessTimer: Timer?
    private var wantsToPlay = false
    private var normGainDB = 0.0
    private var lastEmittedLoudness: Double?
    private var lastAppliedVolume: Float = -1
    private var sleepAssertion: IOPMAssertionID = 0
    private var outputPreferenceUID: String?

    public init() {
        loudnessTimer = Timer.scheduledTimer(withTimeInterval: Loudness.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateNormalizationGain() }
        }
    }

    // MARK: - Transport

    public func setCurrentURL(_ url: String) {
        // Stream URLs can originate from the community-editable radio-browser.info
        // directory: only http(s) is ever fetched.
        if !url.isEmpty && !URLPolicy.isWebURL(url) {
            NSLog("patron-radio: refusing non-HTTP(S) stream URL: \(url)")
            setError("Refused unsupported stream URL")
            return
        }
        guard url != currentURL else { return }
        stopSession()
        stallTimer?.invalidate()
        reconnectTimer?.invalidate(); reconnectTimer = nil
        reconnect.reset()
        beginStreamLoudness()
        currentURL = url
        streamTitle = ""
        streamInfo = nil
        if wantsToPlay && !url.isEmpty {
            isBuffering = true
            startSession()
        }
    }

    public func play() {
        NSLog("patron-radio: play() \(currentStationName) \(currentURL)")
        guard !currentURL.isEmpty else { return }
        wantsToPlay = true
        if session == nil {
            // Re-seed the level after a stop too, so a known-loud station never
            // starts at full volume while the meter warms up.
            beginStreamLoudness()
            isBuffering = true
            startSession()
        }
    }

    public func stop() {
        NSLog("patron-radio: stop() \(currentStationName)")
        wantsToPlay = false
        reconnectTimer?.invalidate(); reconnectTimer = nil
        stallTimer?.invalidate(); stallTimer = nil
        reconnect.reset()
        stopSession()
        meter.reset(enabled: normalizeLoudness && loudnessAuto)
        normGainDB = 0
        measuredLoudness = nil
        lastEmittedLoudness = nil
        applyVolume()
        streamTitle = ""
        isBuffering = false
    }

    public func setOutputPreference(uid: String?) {
        outputPreferenceUID = uid
        let (id, resolvedUID) = resolveOutput()
        activeOutputUID = resolvedUID
        session?.setOutputDevice(id)
    }

    // MARK: - Sessions

    private func resolveOutput() -> (AudioDeviceID?, String?) {
        let outputs = AudioDevices.outputs()
        if let pref = outputPreferenceUID, let d = outputs.first(where: { $0.uid == pref }) {
            return (d.deviceID, d.uid)
        }
        guard let def = AudioDevices.defaultOutputID() else { return (nil, nil) }
        return (def, outputs.first { $0.deviceID == def }?.uid)
    }

    private func startSession() {
        guard let url = URL(string: currentURL) else {
            setError("Invalid stream URL")
            return
        }
        sessionID += 1
        let id = sessionID
        let s = StreamSession(url: url, meter: meter) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, sessionID: id) }
        }
        session = s
        let (deviceID, uid) = resolveOutput()
        activeOutputUID = uid
        lastAppliedVolume = -1
        s.start(deviceID: deviceID, volume: Float(effectiveVolume))
    }

    private func stopSession() {
        session?.stop()
        session = nil
        sessionID += 1
        stallTimer?.invalidate(); stallTimer = nil
        isPlaying = false
    }

    private func handle(_ event: StreamEvent, sessionID id: Int) {
        guard id == sessionID else { return } // stale session
        switch event {
        case .info(let info):
            streamInfo = info
        case .title(let t):
            streamTitle = t
        case .playing, .resumed:
            stallTimer?.invalidate(); stallTimer = nil
            isBuffering = false
            if !isPlaying {
                reconnectTimer?.invalidate(); reconnectTimer = nil
                reconnect.reset()
                if !lastError.isEmpty { lastError = ""; onEvent?(.lastErrorChanged) }
                isPlaying = true
            }
            applyVolume()
        case .underrun:
            // Give the stream a chance to recover by itself; if it's still starved
            // when the watchdog fires, force a clean reconnect.
            isBuffering = true
            if wantsToPlay && reconnectTimer == nil {
                stallTimer?.invalidate()
                stallTimer = Timer.scheduledTimer(withTimeInterval: Self.stallTimeout, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        NSLog("patron-radio: playback stalled past timeout; forcing reconnect")
                        self?.scheduleReconnect()
                    }
                }
            }
        case .failed(let message):
            setError(message)
            isBuffering = false
            scheduleReconnect()
        case .ended:
            // A live stream should never end; reconnect rather than wait for the watchdog.
            NSLog("patron-radio: unexpected end of live stream; reconnecting")
            scheduleReconnect()
        case .outputLost:
            onEvent?(.outputLost)
        }
    }

    private func setError(_ message: String) {
        lastError = message
        onEvent?(.lastErrorChanged)
    }

    private func scheduleReconnect() {
        guard wantsToPlay, !currentURL.isEmpty, reconnectTimer == nil else { return }
        guard let delay = reconnect.nextDelayMS() else {
            NSLog("patron-radio: reconnect limit reached (\(ReconnectPolicy.maxAttempts) attempts), giving up")
            wantsToPlay = false
            stopSession()
            // Surface the failure so the UI offers "Fix" instead of spinning forever.
            setError("Stream unavailable after repeated reconnect attempts")
            isBuffering = false
            return
        }
        NSLog("patron-radio: scheduling reconnect in \(delay) ms")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: Double(delay) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.attemptReconnect() }
        }
    }

    private func attemptReconnect() {
        reconnectTimer = nil
        guard wantsToPlay, !currentURL.isEmpty else { return }
        NSLog("patron-radio: attempting reconnect to \(currentURL)")
        stopSession()
        isBuffering = true
        startSession()
    }

    private func playingDidChange() {
        if isPlaying && inhibitSleep { takeSleepLock() }
        if !isPlaying { releaseSleepLock() }
        onEvent?(.playingChanged)
    }

    // MARK: - Loudness

    /// A new station: seed the gain from its last-known loudness so it plays at
    /// the right level immediately; if never measured, assume a loud default so it
    /// starts pre-attenuated rather than blasting until the meter converges.
    private func beginStreamLoudness() {
        meter.reset(enabled: normalizeLoudness && loudnessAuto)
        if normalizeLoudness {
            normGainDB = Loudness.attenuationGainDB(measured: knownLoudness ?? Loudness.defaultLUFS)
        } else {
            normGainDB = 0
        }
        // Only real, known loudness is exposed/persisted — never the assumed default.
        measuredLoudness = knownLoudness
        lastEmittedLoudness = nil
        applyVolume()
    }

    private func updateNormalizationGain() {
        guard normalizeLoudness, loudnessAuto, session != nil else { return }
        let lufs = meter.integratedLoudness
        guard Loudness.isMeasurable(lufs) else { return } // silence / not enough data yet
        measuredLoudness = lufs
        normGainDB = Loudness.slew(from: normGainDB, to: Loudness.attenuationGainDB(measured: lufs))
        applyVolume()
        if lastEmittedLoudness == nil || abs(lufs - lastEmittedLoudness!) > Loudness.persistThresholdLU {
            lastEmittedLoudness = lufs
            onEvent?(.measuredLoudnessChanged)
        }
    }

    private var effectiveVolume: Double {
        min(1, max(0, volume * Loudness.linearGain(db: normGainDB)))
    }

    private func applyVolume() {
        let v = Float(effectiveVolume)
        guard v != lastAppliedVolume else { return }
        lastAppliedVolume = v
        session?.setVolume(v)
    }

    // MARK: - Sleep prevention (logind Inhibit on Linux, a power assertion here)

    private func takeSleepLock() {
        guard sleepAssertion == 0 else { return }
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Patron Radio: playing audio" as CFString, &sleepAssertion)
        if ok != kIOReturnSuccess { sleepAssertion = 0 }
    }

    private func releaseSleepLock() {
        guard sleepAssertion != 0 else { return }
        IOPMAssertionRelease(sleepAssertion)
        sleepAssertion = 0
    }
}
