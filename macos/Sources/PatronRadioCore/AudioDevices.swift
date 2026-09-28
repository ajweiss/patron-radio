import CoreAudio
import Foundation

/// An audio output as CoreAudio reports it. `uid` is stable across reboots and
/// reconnects, so it's what settings store (the widget stores PipeWire sink ids).
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let deviceID: AudioDeviceID
    public let isBluetooth: Bool
}

public enum AudioDevices {
    public static func outputs() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            let transport = uint32Property(id, kAudioDevicePropertyTransportType) ?? 0
            let bt = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            return AudioOutputDevice(uid: uid, name: name, deviceID: id, isBluetooth: bt)
        }
    }

    public static func defaultOutputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    public static func defaultOutputUID() -> String? {
        defaultOutputID().flatMap { stringProperty($0, kAudioDevicePropertyDeviceUID) }
    }

    public static func device(uid: String) -> AudioOutputDevice? {
        outputs().first { $0.uid == uid }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Calls back on the main queue whenever outputs appear/disappear or the system
/// default output changes (the macOS counterpart of QMediaDevices::audioOutputsChanged).
public final class AudioDeviceMonitor {
    private var blocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(onChange: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
                blocks.append((addr, block))
            }
        }
    }

    deinit {
        for (addr, block) in blocks {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        }
    }
}
