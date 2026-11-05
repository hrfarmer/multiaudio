import Darwin
import Foundation

/// Wraps 16-bit stereo PCM in an *uncompressed* (escape) ALAC frame.
/// Receivers decode this with a stock ALAC decoder; it avoids needing a real encoder.
enum ALACRaw {
    static func encode(_ samples: UnsafePointer<Int16>, frames: Int, fullFrames: Int) -> Data {
        var w = BitWriter(capacity: frames * 4 + 16)
        w.write(1, bits: 3)          // element tag: ID_CPE (channel pair)
        w.write(0, bits: 4)          // element instance tag
        w.write(0, bits: 12)         // unused
        let partial = frames != fullFrames
        w.write(partial ? 1 : 0, bits: 1) // has explicit sample count
        w.write(0, bits: 2)          // bytes shifted
        w.write(1, bits: 1)          // escape: not compressed
        if partial { w.write(UInt32(frames), bits: 32) }
        for i in 0..<(frames * 2) {
            w.write(UInt32(UInt16(bitPattern: samples[i])), bits: 16)
        }
        w.write(7, bits: 3)          // ID_END
        return w.finish()
    }

    struct BitWriter {
        var bytes: [UInt8]
        var acc: UInt64 = 0
        var nbits = 0
        init(capacity: Int) { bytes = []; bytes.reserveCapacity(capacity) }
        mutating func write(_ value: UInt32, bits: Int) {
            acc = (acc << UInt64(bits)) | (UInt64(value) & ((1 << UInt64(bits)) - 1))
            nbits += bits
            while nbits >= 8 {
                nbits -= 8
                bytes.append(UInt8(truncatingIfNeeded: acc >> UInt64(nbits)))
            }
        }
        mutating func finish() -> Data {
            if nbits > 0 { bytes.append(UInt8(truncatingIfNeeded: acc << UInt64(8 - nbits))); nbits = 0 }
            return Data(bytes)
        }
    }
}

/// Owns the shared RTP timeline and pushes audio to every AirPlay session
/// so all receivers play in sync with each other.
public final class AirPlayStreamer: @unchecked Sendable {
    public static let framesPerPacket = 352
    public static let sampleRate = 44100

    /// Fills `frames` interleaved stereo Int16 frames at 44.1 kHz.
    public typealias Source = (_ buffer: UnsafeMutablePointer<Int16>, _ frames: Int) -> Void

    private let lock = NSLock()
    private var sessions: [AirPlaySession] = []
    private var thread: Thread?
    private var running = false
    private var rtpNow: UInt32 = UInt32.random(in: 0...UInt32.max / 2)
    private let source: Source

    /// Playback delay applied by receivers, in frames.
    public let latencyFrames: UInt32

    public init(latencySeconds: Double = 2.0, source: @escaping Source) {
        latencyFrames = UInt32(latencySeconds * Double(AirPlayStreamer.sampleRate))
        self.source = source
    }

    public var latencySeconds: Double { Double(latencyFrames) / Double(AirPlayStreamer.sampleRate) }

    public func add(_ session: AirPlaySession) {
        let rtp: UInt32 = lock.withLock {
            sessions.append(session)
            return rtpNow
        }
        session.start(rtpStart: rtp, latency: latencyFrames)
        startIfNeeded()
    }

    public func remove(_ session: AirPlaySession) {
        lock.withLock { sessions.removeAll { $0 === session } }
        session.stop()
    }

    public func stopAll() {
        let all = lock.withLock { () -> [AirPlaySession] in
            let s = sessions
            sessions = []
            running = false
            return s
        }
        all.forEach { $0.stop() }
    }

    private func startIfNeeded() {
        let shouldStart = lock.withLock { () -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "airplay-streamer"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func run() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanosPerPacket = Double(AirPlayStreamer.framesPerPacket) / Double(AirPlayStreamer.sampleRate) * 1e9
        let ticksPerPacket = nanosPerPacket * Double(timebase.denom) / Double(timebase.numer)

        let start = mach_absolute_time()
        var packetIndex: UInt64 = 0
        var lastSync = 0.0
        let spf = AirPlayStreamer.framesPerPacket
        let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: spf * 2)
        let mixed = UnsafeMutablePointer<Int16>.allocate(capacity: spf * 2)
        defer {
            pcm.deallocate()
            mixed.deallocate()
        }

        while true {
            let (alive, current, rtp) = lock.withLock { (running, sessions, rtpNow) }
            if !alive { break }

            source(pcm, spf)
            let active = current.filter { $0.isStreaming }
            if !active.isEmpty {
                let now = Double(mach_absolute_time() - start) * Double(timebase.numer) / Double(timebase.denom) / 1e9
                if now - lastSync >= 1.0 || lastSync == 0 {
                    lastSync = now
                    for s in active { s.sendSync(rtpNow: rtp, latency: latencyFrames) }
                } else {
                    for s in active where s.needsFirstSync { s.sendSync(rtpNow: rtp, latency: latencyFrames) }
                }
                // Same RTP timeline for everyone; only the channel mix differs per speaker.
                for mode in ChannelMode.allCases {
                    let group = active.filter { $0.channels == mode }
                    guard !group.isEmpty else { continue }
                    mixed.update(from: pcm, count: spf * 2)
                    mode.apply(to: mixed, frames: spf)
                    let frame = ALACRaw.encode(mixed, frames: spf, fullFrames: spf)
                    for s in group { s.sendAudio(rtpTime: rtp, alac: frame, marker: false) }
                }
            }
            lock.withLock { rtpNow = rtpNow &+ UInt32(spf) }

            packetIndex += 1
            let deadline = start + UInt64(Double(packetIndex) * ticksPerPacket)
            let nowTicks = mach_absolute_time()
            if deadline > nowTicks {
                mach_wait_until(deadline)
            }
        }
    }
}
