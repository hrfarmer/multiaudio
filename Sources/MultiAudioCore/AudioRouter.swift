import AVFoundation
import CoreAudio
import Foundation

/// Routes captured system audio to any mix of local devices and AirPlay receivers.
/// All methods must be called on the main thread.
public final class AudioRouter {
    private let tap = SystemAudioTap()
    private var locals: [String: LocalOutput] = [:]
    private var localVolumes: [String: Float] = [:]
    private var airplayVolumes: [String: Float] = [:]
    private var localChannels: [String: ChannelMode] = [:]
    private var airplayChannels: [String: ChannelMode] = [:]
    private var airplaySessions: [String: AirPlaySession] = [:]
    private var streamer: AirPlayStreamer?
    private var airplayBuffer: StereoRingBuffer?
    private var resampler: AirPlayResampler?
    private var defaultDeviceListener: (() -> Void)?

    /// Extra delay applied to local outputs so they line up with AirPlay (seconds).
    public var localDelay: Double = 0 {
        didSet { applyLocalDelay() }
    }

    /// Scales every output on top of its own volume (0...1), in slider terms.
    public var masterVolume: Float = 1 {
        didSet {
            guard masterVolume != oldValue else { return }
            for (uid, out) in locals { out.setVolume((localVolumes[uid] ?? 1) * masterVolume) }
            for (name, session) in airplaySessions { session.setVolume((airplayVolumes[name] ?? 0.5) * masterVolume) }
        }
    }

    /// Cushion every local output keeps on top of `localDelay` (seconds).
    public static let localBaseDelay = 0.04

    public var onError: ((String) -> Void)?

    public init() {}

    public var isCapturing: Bool { tap.isRunning }

    // MARK: Local devices

    public func enableLocal(_ device: OutputDeviceInfo, volume: Float) throws {
        localVolumes[device.id] = volume
        guard locals[device.id] == nil else { return }
        try ensureTap()
        let out = LocalOutput(device: device, sampleRate: tap.sampleRate, delayFrames: localDelayFrames)
        out.setVolume(volume * masterVolume)
        out.channels = localChannels[device.id] ?? .stereo
        try out.start(sampleRate: tap.sampleRate)
        locals[device.id] = out
        updateSinks()
    }

    public func disableLocal(_ uid: String) {
        locals.removeValue(forKey: uid)?.stop()
        updateSinks()
        stopTapIfIdle()
    }

    public func setLocalVolume(_ uid: String, _ v: Float) {
        localVolumes[uid] = v
        locals[uid]?.setVolume(v * masterVolume)
    }

    public func setLocalChannels(_ uid: String, _ channels: ChannelMode) {
        localChannels[uid] = channels
        locals[uid]?.channels = channels
    }

    // MARK: AirPlay

    public func enableAirPlay(_ target: AirPlayTarget, volume: Float, onState: @escaping (AirPlaySessionState) -> Void) throws {
        if let existing = airplaySessions[target.name] {
            if case .failed = existing.state {} else { return }
            streamer?.remove(existing)
        }
        try ensureTap()
        ensureStreamer()
        stateHandlers[target.name] = onState
        airplayVolumes[target.name] = volume
        startSession(target, volume: volume * masterVolume)
    }

    private var stateHandlers: [String: (AirPlaySessionState) -> Void] = [:]

    private func startSession(_ target: AirPlayTarget, volume: Float) {
        let session = AirPlaySession(target: target, volume: volume)
        session.channels = airplayChannels[target.name] ?? .stereo
        // Only the current session for a name may report state; late callbacks
        // from a replaced/stopped session are dropped.
        session.onStateChange = { [weak self, weak session] state in
            DispatchQueue.main.async {
                guard let self, let session, self.airplaySessions[target.name] === session else { return }
                self.stateHandlers[target.name]?(state)
            }
        }
        airplaySessions[target.name] = session
        streamer?.add(session)
    }

    public func disableAirPlay(_ name: String) {
        stateHandlers.removeValue(forKey: name)
        airplayVolumes.removeValue(forKey: name)
        if let s = airplaySessions.removeValue(forKey: name) { streamer?.remove(s) }
        if airplaySessions.isEmpty {
            streamer?.stopAll()
            streamer = nil
            airplayBuffer = nil
            resampler = nil
            updateSinks()
        }
        stopTapIfIdle()
    }

    public func setAirPlayVolume(_ name: String, _ v: Float) {
        airplayVolumes[name] = v
        airplaySessions[name]?.setVolume(v * masterVolume)
    }

    public func setAirPlayChannels(_ name: String, _ channels: ChannelMode) {
        airplayChannels[name] = channels
        airplaySessions[name]?.channels = channels
    }

    /// Latency value sent to receivers (seconds). Changing it reconnects active AirPlay sessions.
    public var airplayBufferSeconds: Double = 0.25 {
        didSet {
            guard oldValue != airplayBufferSeconds, let old = streamer else { return }
            let active = airplaySessions
            old.stopAll()
            streamer = nil
            airplaySessions = [:]
            ensureStreamer()
            for (_, s) in active { startSession(s.target, volume: s.volume) }
        }
    }

    /// Measured end-to-end AirPlay delay: receivers apply the latency both from the
    /// sync packets and from the stream setup, plus ~65 ms (measured on a HomePod mini).
    public var airplayDelay: Double { 2 * airplayBufferSeconds + 0.065 }

    public func stopAll() {
        for (uid, _) in locals { disableLocal(uid) }
        for (name, _) in airplaySessions { disableAirPlay(name) }
        tap.stop()
    }

    // MARK: Internals

    private var localDelayFrames: Int { Int((Self.localBaseDelay + localDelay) * tap.sampleRate) }

    private func applyLocalDelay() {
        for out in locals.values { out.buffer.targetFrames = localDelayFrames }
    }

    private func ensureTap() throws {
        guard !tap.isRunning else { return }
        try tap.start()
        // If the system output changes, the tap's clock device goes away: rebuild.
        defaultDeviceListener = CA.listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.restartTap()
        }
    }

    private func restartTap() {
        guard tap.isRunning else { return }
        let oldRate = tap.sampleRate
        tap.stop()
        do {
            try tap.start()
        } catch {
            onError?("\(error)")
            return
        }
        if tap.sampleRate != oldRate {
            // Rebuild everything that depends on the capture rate.
            let devices = locals.values.map(\.device)
            locals.values.forEach { $0.stop() }
            locals = [:]
            for d in devices { try? enableLocal(d, volume: localVolumes[d.id] ?? 1) }
            if airplayBuffer != nil {
                airplayBuffer = StereoRingBuffer(capacityFrames: Int(tap.sampleRate * 4), targetFrames: Int(tap.sampleRate * 0.1))
                resampler?.reset(buffer: airplayBuffer!, inputRate: tap.sampleRate)
            }
        }
        updateSinks()
    }

    private func stopTapIfIdle() {
        guard locals.isEmpty, airplaySessions.isEmpty else { return }
        tap.stop()
        defaultDeviceListener?()
        defaultDeviceListener = nil
    }

    private func ensureStreamer() {
        guard streamer == nil else { return }
        let buf = StereoRingBuffer(capacityFrames: Int(tap.sampleRate * 4), targetFrames: Int(tap.sampleRate * 0.1))
        let rs = AirPlayResampler(buffer: buf, inputRate: tap.sampleRate)
        airplayBuffer = buf
        resampler = rs
        streamer = AirPlayStreamer(latencySeconds: airplayBufferSeconds) { out, frames in
            rs.render(into: out, frames: frames)
        }
        updateSinks()
    }

    private func updateSinks() {
        var sinks = locals.values.map(\.buffer)
        if let airplayBuffer { sinks.append(airplayBuffer) }
        tap.setSinks(sinks)
    }
}

/// Pulls Float32 stereo from a ring buffer at the capture rate and produces
/// 44.1 kHz interleaved Int16 for AirPlay.
final class AirPlayResampler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: StereoRingBuffer
    private var converter: AVAudioConverter
    private var inFormat: AVAudioFormat
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!
    private var inBuf: AVAudioPCMBuffer
    private var outBuf: AVAudioPCMBuffer

    init(buffer: StereoRingBuffer, inputRate: Double) {
        self.buffer = buffer
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: true)!
        converter = AVAudioConverter(from: inFormat, to: outFormat)!
        inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 4096)!
        outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)!
    }

    func reset(buffer: StereoRingBuffer, inputRate: Double) {
        lock.withLock {
            self.buffer = buffer
            inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: true)!
            converter = AVAudioConverter(from: inFormat, to: outFormat)!
            inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 4096)!
        }
    }

    func render(into out: UnsafeMutablePointer<Int16>, frames: Int) {
        lock.withLock {
            outBuf.frameLength = 0
            var produced = 0
            while produced < frames {
                let want = AVAudioFrameCount(frames - produced)
                guard let chunk = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: want) else { break }
                var err: NSError?
                let status = converter.convert(to: chunk, error: &err) { [self] packets, inputStatus in
                    let n = min(Int(packets), Int(inBuf.frameCapacity))
                    buffer.read(into: inBuf.floatChannelData![0], frames: n, gain: 1)
                    inBuf.frameLength = AVAudioFrameCount(n)
                    inputStatus.pointee = .haveData
                    return inBuf
                }
                let got = Int(chunk.frameLength)
                if status == .error || got == 0 { break }
                (out + produced * 2).update(from: chunk.int16ChannelData![0], count: got * 2)
                produced += got
            }
            if produced < frames { (out + produced * 2).update(repeating: 0, count: (frames - produced) * 2) }
        }
    }
}
