import CoreAudio
import Foundation

/// The MultiAudio virtual output device (Driver/MultiAudioDevice.c), if it's installed.
/// Video players delay their picture by its latency, and its volume controls are what the
/// volume keys change while it's the system output.
public enum VirtualDevice {
    private static let uid = "MultiAudioDevice_UID"
    private static let latencySelector: AudioObjectPropertySelector = 0x6D6C6174 // 'mlat'
    private static let latencySampleRate = 48000.0
    private static let output = kAudioObjectPropertyScopeOutput

    public static var deviceID: AudioDeviceID? { CA.device(forUID: uid) }

    public static var isSystemOutput: Bool { deviceID == CA.defaultOutputDevice }

    public static func setLatency(seconds: Double) {
        guard let deviceID else { return }
        var addr = CA.address(latencySelector)
        var frames = Int32(seconds * latencySampleRate)
        var number: CFNumber? = CFNumberCreate(nil, .sInt32Type, &frames)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<CFNumber?>.size), &number)
    }

    /// The device's volume as a 0...1 slider value; 0 when muted.
    public static var volume: Float {
        guard let deviceID else { return 1 }
        if CA.get(deviceID, kAudioDevicePropertyMute, scope: output, default: UInt32(0)) != 0 { return 0 }
        return CA.get(deviceID, kAudioDevicePropertyVolumeScalar, scope: output, default: Float32(1))
    }

    /// Calls `handler` when the volume or mute changes. Returns a token that removes the listeners.
    public static func observeVolume(of device: AudioDeviceID, _ handler: @escaping () -> Void) -> () -> Void {
        let tokens = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
            CA.listen(device, $0, scope: output, handler)
        }
        return { tokens.forEach { $0() } }
    }

    /// Makes this the system output and returns the UID of the output it replaced.
    public static func becomeSystemOutput() -> String? {
        guard let deviceID else { return nil }
        let previous = CA.string(CA.defaultOutputDevice, kAudioDevicePropertyDeviceUID)
        CA.setDefaultOutput(deviceID)
        return previous == uid ? nil : previous
    }

    /// Hands the system output back: to `uid` if it still exists, else the built-in output.
    public static func resignSystemOutput(to uid: String?) {
        let fallback = OutputDeviceInfo.currentOutputs()
        let target = uid.flatMap(CA.device(forUID:)) ?? (fallback.first(where: \.isBuiltIn) ?? fallback.first)?.deviceID
        if let target, target != deviceID { CA.setDefaultOutput(target) }
    }
}
