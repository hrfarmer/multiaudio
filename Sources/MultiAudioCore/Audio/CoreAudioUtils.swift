import CoreAudio
import Foundation

enum CA {
    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default def: T) -> T {
        var addr = address(sel, scope)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return status == noErr ? value : def
    }

    static func array<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type, zero: T) -> [T] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &items) == noErr else { return [] }
        return items
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static var defaultOutputDevice: AudioDeviceID {
        CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
    }

    static func device(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func allDevices() -> [AudioDeviceID] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self, zero: 0)
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var v = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
    }

    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Registers a block listener; returns a token that removes it when called.
    static func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       queue: DispatchQueue = .main, _ handler: @escaping () -> Void) -> () -> Void {
        var addr = address(sel)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(obj, &addr, queue, block)
        return {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
        }
    }
}

/// A playable (non-AirPlay) CoreAudio output device.
public struct OutputDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: String // UID
    public let deviceID: AudioDeviceID
    public let name: String
    public let transport: UInt32

    public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    public static func currentOutputs() -> [OutputDeviceInfo] {
        CA.allDevices().compactMap { dev in
            let streams = CA.array(dev, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self, zero: 0)
            guard !streams.isEmpty,
                  let uid = CA.string(dev, kAudioDevicePropertyDeviceUID),
                  let name = CA.string(dev, kAudioObjectPropertyName) else { return nil }
            let transport = CA.get(dev, kAudioDevicePropertyTransportType, default: UInt32(0))
            // AirPlay is handled natively; skip aggregates (including our own private ones).
            if transport == kAudioDeviceTransportTypeAirPlay || transport == kAudioDeviceTransportTypeAggregate { return nil }
            if uid.hasPrefix("MultiAudio") { return nil }
            return OutputDeviceInfo(id: uid, deviceID: dev, name: name, transport: transport)
        }
    }
}

// MARK: - Public helpers for the app layer

@discardableResult
public func CA_listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ handler: @escaping () -> Void) -> () -> Void {
    CA.listen(obj, sel, handler)
}

public func CA_defaultOutput() -> AudioDeviceID { CA.defaultOutputDevice }

public func CA_transport(_ dev: AudioDeviceID) -> UInt32 {
    CA.get(dev, kAudioDevicePropertyTransportType, default: UInt32(0))
}

public func CA_setDefaultOutput(_ dev: AudioDeviceID) { CA.setDefaultOutput(dev) }
