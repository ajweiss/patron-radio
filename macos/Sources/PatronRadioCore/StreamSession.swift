import AVFoundation
import AudioToolbox
import Foundation

/// Events a stream session reports (always delivered on the main queue).
public enum StreamEvent: Equatable, Sendable {
    case info(StreamInfo)
    case title(String)
    case playing        // pre-roll reached, audio is coming out
    case underrun       // the decoded queue drained while streaming
    case resumed        // recovered from an underrun
    case failed(String)
    case ended          // the server closed a live stream
    case outputLost     // the output device disappeared
}

/// One connection to one stream URL: HTTP → ICY demux → AudioFileStream packet
/// parser → AVAudioConverter (PCM) → loudness meter + AVAudioEngine.
///
/// macOS counterpart of the widget's IcyStreamReader + QMediaPlayer pair. Doing
/// the HTTP ourselves (instead of AVPlayer) is what gives us ICY titles for every
/// stream and the decoded PCM the loudness meter needs. All work runs on one
/// private serial queue; a session is single-use (reconnect = new session).
final class StreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let prerollSeconds = 2.0      // same pre-play buffer duration as the widget
    static let rebufferSeconds = 1.0
    static let maxQueuedSeconds = 30.0
    static let sniffLimitBytes = 256 * 1024

    let url: URL
    private let queue = DispatchQueue(label: "com.signal11.patronradio.stream", qos: .userInitiated)
    private let meter: SharedLoudnessMeter
    private let emitHandler: @Sendable (StreamEvent) -> Void

    // Network
    private var urlSession: URLSession?
    private var demuxer = IcyDemuxer(metaIntHeader: nil)
    private var cancelled = false
    /// A fatal error was emitted: the download is cancelled and no further
    /// events flow, but resources stay allocated until the owner calls stop().
    private var failed = false
    private var streamFinished = false

    // Parsing / decoding
    private var fileStream: AudioFileStreamID?
    private var parseDiscontinuity = false
    private var bytesBeforeFormat = 0
    private var sourceFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending: [(data: Data, desc: AudioStreamPacketDescription)] = []

    // Output
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var engineGeneration = 0
    private var configObserver: NSObjectProtocol?
    private var deviceID: AudioDeviceID?
    private var volume: Float = 1
    private var queuedFrames: AVAudioFramePosition = 0
    private enum PlayState { case prebuffering, playing, rebuffering, waitingForDevice }
    private var playState = PlayState.prebuffering
    private var hasStartedOnce = false

    init(url: URL, meter: SharedLoudnessMeter, onEvent: @escaping @Sendable (StreamEvent) -> Void) {
        self.url = url
        self.meter = meter
        self.emitHandler = onEvent
    }

    // MARK: - Public control (any thread)

    func start(deviceID: AudioDeviceID?, volume: Float) {
        queue.async {
            self.deviceID = deviceID
            self.volume = volume
            self.startNetwork()
        }
    }

    func stop() {
        queue.async {
            guard !self.cancelled else { return }
            self.cancelled = true
            self.urlSession?.invalidateAndCancel()
            self.urlSession = nil
            self.teardownEngine()
            if let fs = self.fileStream { AudioFileStreamClose(fs); self.fileStream = nil }
            self.converter = nil
            self.pending.removeAll()
        }
    }

    func setVolume(_ v: Float) {
        queue.async {
            self.volume = v
            self.player?.volume = v
        }
    }

    /// Re-route to another output. The network stream keeps flowing; only the
    /// engine is rebuilt (a short re-buffer, like the widget's forced re-route).
    func setOutputDevice(_ id: AudioDeviceID?) {
        queue.async {
            guard !self.cancelled else { return }
            let changed = id != self.deviceID
            self.deviceID = id
            if self.playState == .waitingForDevice || (changed && self.engine != nil) {
                self.teardownEngine()
                self.playState = .prebuffering
            }
        }
    }

    // MARK: - Networking

    private func startNetwork() {
        guard !cancelled else { return }
        if URLPolicy.isDisallowedStreamURL(url) {
            fail("Refused an unsupported or non-routable stream URL")
            return
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20                 // idle timeout between chunks
        cfg.timeoutIntervalForResource = 7 * 24 * 3600     // live streams never "finish"
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
        urlSession = session

        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        req.setValue("PatronRadio/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Validate every hop: the initial check only covers the first URL, and a
        // redirect could point at an internal host. Never downgrade https → http,
        // judged against the current hop (not the original request), so a chain
        // that has upgraded to https can't be bounced back to plaintext.
        guard let target = request.url, !URLPolicy.isDisallowedStreamURL(target),
              !(task.currentRequest?.url?.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http")
        else {
            completionHandler(nil)
            fail("Refused a redirect to a non-routable or less secure host")
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !cancelled, !failed else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            fail("Server returned HTTP \(http.statusCode)")
            return
        }
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        if let ct = contentType?.lowercased(), ct.hasPrefix("text/") {
            completionHandler(.cancel)
            fail("The server sent a web page, not an audio stream")
            return
        }
        demuxer = IcyDemuxer(metaIntHeader: http?.value(forHTTPHeaderField: "icy-metaint"))
        let info = StreamInfo(contentType: contentType, icyBr: http?.value(forHTTPHeaderField: "icy-br"),
                              url: response.url)
        emit(.info(info))
        openParser(hint: info.codec)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled, !failed else { return }
        let out = demuxer.consume(data)
        for t in out.titles { emit(.title(t)) }
        if !out.audio.isEmpty { parse(out.audio) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled, !failed else { return }
        streamFinished = true
        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            fail(error.localizedDescription)
        } else {
            emit(.ended)
        }
    }

    // MARK: - Packet parsing

    private func openParser(hint: String) {
        if let fs = fileStream { AudioFileStreamClose(fs); fileStream = nil }
        let type: AudioFileTypeID
        switch hint {
        case "MP3": type = kAudioFileMP3Type
        case "AAC", "AAC+": type = kAudioFileAAC_ADTSType
        default: type = 0 // let AudioToolbox sniff
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var fs: AudioFileStreamID?
        let status = AudioFileStreamOpen(ctx, StreamSession.propertyProc, StreamSession.packetsProc, type, &fs)
        guard status == noErr, let fs else {
            fail("Could not open an audio parser (\(status))")
            return
        }
        fileStream = fs
    }

    private func parse(_ audio: Data) {
        guard let fs = fileStream else { return }
        if sourceFormat == nil {
            bytesBeforeFormat += audio.count
            if bytesBeforeFormat > StreamSession.sniffLimitBytes {
                fail("Unsupported stream format")
                return
            }
        }
        let flags: AudioFileStreamParseFlags = parseDiscontinuity ? .discontinuity : []
        parseDiscontinuity = false
        let status = audio.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(fs, UInt32(raw.count), raw.baseAddress, flags)
        }
        if status != noErr {
            // Corrupt frame(s): resync on the next chunk.
            parseDiscontinuity = true
        }
    }

    private static let propertyProc: AudioFileStream_PropertyListenerProc = { ctx, streamID, propertyID, _ in
        let session = Unmanaged<StreamSession>.fromOpaque(ctx).takeUnretainedValue()
        if propertyID == kAudioFileStreamProperty_ReadyToProducePackets {
            session.formatReady(streamID)
        }
    }

    private static let packetsProc: AudioFileStream_PacketsProc = { ctx, numberBytes, numberPackets, data, descs in
        let session = Unmanaged<StreamSession>.fromOpaque(ctx).takeUnretainedValue()
        session.receivePackets(numberBytes: numberBytes, numberPackets: numberPackets, data: data, descs: descs)
    }

    private func formatReady(_ fs: AudioFileStreamID) {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr else {
            fail("Unreadable stream format")
            return
        }

        // HE-AAC advertises its full-rate SBR format in the format list; pick the
        // first one this Mac can play.
        var listSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(fs, kAudioFileStreamProperty_FormatList, &listSize, nil) == noErr, listSize > 0 {
            let n = Int(listSize) / MemoryLayout<AudioFormatListItem>.size
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: n)
            if AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_FormatList, &listSize, &items) == noErr {
                var index: UInt32 = 0
                var indexSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioFormatGetProperty(kAudioFormatProperty_FirstPlayableFormatFromList, listSize, &items,
                                          &indexSize, &index) == noErr, Int(index) < n {
                    asbd = items[Int(index)].mASBD
                }
            }
        }

        var cookie: Data?
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(fs, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var bytes = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &bytes) == noErr {
                cookie = Data(bytes)
            }
        }

        guard let src = AVAudioFormat(streamDescription: &asbd) else {
            fail("Unsupported audio format")
            return
        }
        if let cookie { src.magicCookie = cookie }
        let channels = AVAudioChannelCount(min(max(Int(src.channelCount), 1), 2))
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate,
                                      channels: channels, interleaved: false),
              let conv = AVAudioConverter(from: src, to: pcm) else {
            fail("This Mac can't decode the stream's codec")
            return
        }
        conv.downmix = src.channelCount > 2
        if let old = pcmFormat, old != pcm, engine != nil {
            teardownEngine() // format changed mid-stream; rebuild for the new layout
            playState = .prebuffering
        }
        sourceFormat = src
        pcmFormat = pcm
        converter = conv
        pending.removeAll()
    }

    private func receivePackets(numberBytes: UInt32, numberPackets: UInt32, data: UnsafeRawPointer,
                                descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard converter != nil else { return }
        if let descs {
            for i in 0..<Int(numberPackets) {
                let d = descs[i]
                let bytes = Data(bytes: data + Int(d.mStartOffset), count: Int(d.mDataByteSize))
                pending.append((bytes, AudioStreamPacketDescription(mStartOffset: 0,
                                                                    mVariableFramesInPacket: d.mVariableFramesInPacket,
                                                                    mDataByteSize: d.mDataByteSize)))
            }
        } else if let bpp = sourceFormat?.streamDescription.pointee.mBytesPerPacket, bpp > 0 {
            // Constant-bitrate packets arrive without descriptions.
            var offset = 0
            while offset + Int(bpp) <= Int(numberBytes) {
                pending.append((Data(bytes: data + offset, count: Int(bpp)),
                                AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: bpp)))
                offset += Int(bpp)
            }
        }
        decodePending()
    }

    // MARK: - Decoding

    private func decodePending() {
        guard let converter, let pcmFormat, let sourceFormat else { return }
        while !pending.isEmpty {
            guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 8192) else { return }
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { [unowned self] _, inputStatus in
                guard !self.pending.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                let n = min(self.pending.count, 32)
                let maxSize = self.pending.prefix(n).map { $0.data.count }.max() ?? 0
                let buf = AVAudioCompressedBuffer(format: sourceFormat, packetCapacity: AVAudioPacketCount(n),
                                                  maximumPacketSize: max(1, maxSize))
                var offset = 0
                for i in 0..<n {
                    let p = self.pending[i]
                    p.data.withUnsafeBytes { raw in
                        (buf.data + offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                    }
                    buf.packetDescriptions?[i] = AudioStreamPacketDescription(
                        mStartOffset: Int64(offset), mVariableFramesInPacket: p.desc.mVariableFramesInPacket,
                        mDataByteSize: UInt32(p.data.count))
                    offset += p.data.count
                }
                buf.packetCount = AVAudioPacketCount(n)
                buf.byteLength = UInt32(offset)
                self.pending.removeFirst(n)
                inputStatus.pointee = .haveData
                return buf
            }
            if status == .error {
                // A corrupt packet; drop what's queued and carry on with fresh data.
                pending.removeAll()
                converter.reset()
                return
            }
            if out.frameLength > 0 { deliver(out) }
            if status == .inputRanDry || status == .endOfStream { break }
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        if let ch = buffer.floatChannelData {
            meter.add(channelData: UnsafePointer(ch), frames: Int(buffer.frameLength),
                      channels: Int(buffer.format.channelCount), sampleRate: buffer.format.sampleRate)
        }
        guard playState != .waitingForDevice else { return }
        let rate = buffer.format.sampleRate
        if Double(queuedFrames) / rate > StreamSession.maxQueuedSeconds { return } // server burst; cap latency
        guard ensureEngine(), let player else { return }
        let frames = AVAudioFramePosition(buffer.frameLength)
        let generation = engineGeneration
        queuedFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.queue.async { self?.consumed(frames, generation: generation) }
        }
        checkPreroll()
    }

    // MARK: - Output

    private func ensureEngine() -> Bool {
        if engine != nil { return true }
        guard let pcmFormat else { return false }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if let deviceID {
            do { try engine.outputNode.auAudioUnit.setDeviceID(deviceID) }
            catch { NSLog("patron-radio: could not select output device \(deviceID): \(error)") }
        }
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        player.volume = volume
        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail("Audio output unavailable: \(error.localizedDescription)")
            return false
        }
        engineGeneration += 1
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.engineConfigurationChanged() }
        }
        self.engine = engine
        self.player = player
        queuedFrames = 0
        return true
    }

    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engineGeneration += 1 // completions from the old player are now ignored
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        queuedFrames = 0
    }

    private func engineConfigurationChanged() {
        guard !cancelled, engine != nil else { return }
        // The engine has stopped itself. If our device is still there (sample-rate
        // or channel change), rebuild on it; if it vanished, let the router decide
        // whether to pause or move to another output — never auto-blast speakers.
        let stillThere = deviceID.map { id in AudioDevices.outputs().contains { $0.deviceID == id } } ?? true
        teardownEngine()
        if stillThere {
            playState = .prebuffering
        } else {
            playState = .waitingForDevice
            emit(.outputLost)
        }
    }

    private func consumed(_ frames: AVAudioFramePosition, generation: Int) {
        guard generation == engineGeneration, !cancelled else { return }
        queuedFrames = max(0, queuedFrames - frames)
        if queuedFrames == 0 && playState == .playing && !streamFinished {
            player?.pause()
            playState = .rebuffering
            emit(.underrun)
        }
    }

    private func checkPreroll() {
        guard let pcmFormat, let player else { return }
        let seconds = Double(queuedFrames) / pcmFormat.sampleRate
        switch playState {
        case .prebuffering where seconds >= StreamSession.prerollSeconds:
            player.play()
            playState = .playing
            if hasStartedOnce { emit(.resumed) } else { emit(.playing) }
            hasStartedOnce = true
        case .rebuffering where seconds >= StreamSession.rebufferSeconds:
            player.play()
            playState = .playing
            emit(.resumed)
        default:
            break
        }
    }

    // MARK: - Events

    private func fail(_ message: String) {
        guard !cancelled, !failed else { return }
        failed = true
        NSLog("patron-radio: stream error (\(url.absoluteString)): \(message)")
        // A failure is terminal: cancel the download and go quiet, so a still-
        // flowing stream can't keep buffering or re-emit .failed while the
        // owner's reconnect logic gets around to stop(). Resource teardown
        // stays in stop() — fail() can run inside an AudioFileStream callback,
        // where closing the parser wouldn't be safe.
        urlSession?.invalidateAndCancel()
        urlSession = nil
        emit(.failed(message))
    }

    private func emit(_ event: StreamEvent) {
        let handler = emitHandler
        DispatchQueue.main.async { handler(event) }
    }
}
