import CryptoKit
import Darwin
import Foundation

/// NTP-format timestamps (seconds since 1900 in the high 32 bits).
enum NTPTime {
    static func now() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let secs = UInt64(ts.tv_sec) + 2_208_988_800
        let frac = (UInt64(ts.tv_nsec) << 32) / 1_000_000_000
        return (secs << 32) | frac
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    func readBE<T: FixedWidthInteger>(_ offset: Int, as: T.Type = T.self) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v = (v << 8) | T(self[startIndex + offset + i]) }
        return v
    }
}

public struct AirPlayTarget: Hashable, Sendable {
    public let name: String
    public let host: String
    public let port: UInt16
    public init(name: String, host: String, port: UInt16) {
        self.name = name; self.host = host; self.port = port
    }
}

public enum AirPlaySessionState: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case failed(String)
}

/// Process-wide identity we present to receivers.
enum SenderIdentity {
    static let deviceID: String = {
        let key = "airplaySenderDeviceID"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        var b = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, 6, &b)
        b[0] = (b[0] & 0xFC) | 0x02 // locally administered unicast
        let s = b.map { String(format: "%02X", $0) }.joined(separator: ":")
        UserDefaults.standard.set(s, forKey: key)
        return s
    }()
    static let dacpID = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
    static let activeRemote = String(UInt32.random(in: 1...UInt32.max))
    static let clientInstance = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
}

/// One AirPlay 2 receiver. Audio packets are pushed in by `AirPlayStreamer`.
public final class AirPlaySession: @unchecked Sendable {
    public let target: AirPlayTarget
    public var onStateChange: ((AirPlaySessionState) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _state: AirPlaySessionState = .idle
    public var state: AirPlaySessionState { lock.withLock { _state } }

    private var tcp: TCPSocket?
    private var rtsp: RTSPClient?
    private var eventSocket: TCPSocket?
    private var dataSocket: UDPSocket?
    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?
    private var dataDest: Data?
    private var controlDest: Data?
    private var sessionURI = ""
    private var audioKey = SymmetricKey(size: .bits256)
    private var running = false
    private var feedbackTimer: DispatchSourceTimer?

    // RTP state (touched from streamer thread)
    private var seq: UInt16 = UInt16.random(in: 0...UInt16.max)
    private let ssrc = UInt32.random(in: 0...UInt32.max)
    private var sentFirstSync = false
    private var nonceCounter: UInt64 = 0
    private var history = [UInt16: Data]()
    private let historyLimit = 512

    private var pendingVolume: Float = 0.5
    public private(set) var stats = (timingRequests: 0, resendRequests: 0, packetsSent: 0)
    public private(set) var volume: Float = 0.5
    private var _channels: ChannelMode = .stereo
    public var channels: ChannelMode {
        get { lock.withLock { _channels } }
        set { lock.withLock { _channels = newValue } }
    }

    public init(target: AirPlayTarget, volume: Float) {
        self.target = target
        self.volume = volume
        self.pendingVolume = volume
        queue = DispatchQueue(label: "airplay.\(target.name)")
    }

    private func setState(_ s: AirPlaySessionState) {
        lock.withLock { _state = s }
        onStateChange?(s)
    }

    var isStreaming: Bool { state == .streaming }
    var needsFirstSync: Bool { lock.withLock { !sentFirstSync && controlDest != nil } }

    // MARK: Lifecycle

    func start(rtpStart: UInt32, latency: UInt32) {
        queue.async { [self] in
            setState(.connecting)
            do {
                try connect(rtpStart: rtpStart, latency: latency)
                setState(.streaming)
            } catch {
                teardownSockets()
                setState(.failed("\(error)"))
            }
        }
    }

    public func stop() {
        lock.withLock { running = false }
        feedbackTimer?.cancel()
        feedbackTimer = nil
        queue.async { [self] in
            if let rtsp, !sessionURI.isEmpty {
                _ = try? rtsp.request("TEARDOWN", sessionURI)
            }
            teardownSockets()
            setState(.idle)
        }
    }

    private func teardownSockets() {
        lock.withLock { running = false; dataDest = nil }
        tcp?.shutdown()
        eventSocket?.shutdown()
        dataSocket?.close(); controlSocket?.close(); timingSocket?.close()
        tcp = nil; rtsp = nil; eventSocket = nil
        dataSocket = nil; controlSocket = nil; timingSocket = nil
    }

    private func connect(rtpStart: UInt32, latency: UInt32) throws {
        let sock = try TCPSocket(host: target.host, port: target.port)
        tcp = sock
        let client = RTSPClient(socket: sock)
        client.baseHeaders = [
            "User-Agent": "AirPlay/665.13.1",
            "DACP-ID": SenderIdentity.dacpID,
            "Active-Remote": SenderIdentity.activeRemote,
            "Client-Instance": SenderIdentity.clientInstance,
            "X-Apple-ProtocolVersion": "1",
        ]
        rtsp = client

        // 1. Transient pair-setup (SRP with the fixed PIN 3939), then encrypt the channel.
        let key = try pairTransient(client)
        client.cipher = HAPCipher(sharedSecret: key, salt: "Control-Salt",
                                  writeInfo: "Control-Write-Encryption-Key", readInfo: "Control-Read-Encryption-Key")

        // Local UDP sockets matching the TCP address family.
        let v6 = sock.isIPv6
        let timing = try UDPSocket(ipv6: v6)
        let control = try UDPSocket(ipv6: v6)
        let data = try UDPSocket(ipv6: v6)
        timingSocket = timing; controlSocket = control; dataSocket = data
        lock.withLock { running = true }
        startTimingResponder(timing)

        let sessionID = UInt32.random(in: 1...UInt32.max)
        let local = sock.isIPv6 ? "[\(sock.localAddress)]" : sock.localAddress
        sessionURI = "rtsp://\(local)/\(sessionID)"

        // 2. SETUP (session)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let sessionPlist: [String: Any] = [
            "deviceID": SenderIdentity.deviceID,
            "macAddress": SenderIdentity.deviceID,
            "sessionUUID": UUID().uuidString,
            "groupUUID": UUID().uuidString,
            "timingPort": Int(timing.port),
            "timingProtocol": "NTP",
            "isMultiSelectAirPlay": true,
            "groupContainsGroupLeader": false,
            "model": "iTunes",
            "name": "MultiAudio",
            "osName": "macOS",
            "osVersion": "\(osVersion.majorVersion).\(osVersion.minorVersion)",
            "osBuildVersion": "26B123",
            "senderSupportsRelay": false,
            "sourceVersion": "665.13.1",
            "statsCollectionEnabled": false,
        ]
        var resp = try client.plistRequest("SETUP", sessionURI, sessionPlist)
        guard resp.status == 200 else { throw AirPlayError.rtsp("SETUP session returned \(resp.status) \(resp.reason)") }
        if let eventPort = resp.plist?["eventPort"] as? Int, eventPort > 0 {
            // Receivers expect the event channel to be connected; we don't need its contents.
            eventSocket = try? TCPSocket(host: target.host, port: UInt16(eventPort))
            if let ev = eventSocket { startEventChannel(ev, sharedSecret: key) }
        }

        // 3. RECORD
        resp = try client.request("RECORD", sessionURI, headers: [
            "Range": "npt=0-",
            "RTP-Info": "seq=\(seq);rtptime=\(rtpStart)",
        ])
        guard resp.status == 200 else { throw AirPlayError.rtsp("RECORD returned \(resp.status) \(resp.reason)") }

        // 4. SETUP (audio stream) - realtime ALAC 44.1k/16/2, encrypted with a fresh key.
        let shk = audioKey.withUnsafeBytes { Data($0) }
        let streamPlist: [String: Any] = [
            "streams": [[
                "audioFormat": 0x40000,
                "audioMode": "default",
                "controlPort": Int(control.port),
                "ct": 2,
                "isMedia": true,
                "latencyMax": 88200,
                "latencyMin": Int(latency),
                "shk": shk,
                "spf": AirPlayStreamer.framesPerPacket,
                "sr": 44100,
                "type": 96,
                "supportsDynamicStreamID": false,
                "streamConnectionID": Int(sessionID),
            ]],
        ]
        resp = try client.plistRequest("SETUP", sessionURI, streamPlist)
        guard resp.status == 200,
              let streams = resp.plist?["streams"] as? [[String: Any]],
              let s0 = streams.first,
              let dataPort = s0["dataPort"] as? Int
        else { throw AirPlayError.rtsp("SETUP stream returned \(resp.status) \(resp.reason)") }
        let remoteControlPort = (s0["controlPort"] as? Int) ?? 0

        let remote = sock.remoteAddress
        let dDest = data.destination(host: remote, port: UInt16(dataPort))
        let cDest = remoteControlPort > 0 ? control.destination(host: remote, port: UInt16(remoteControlPort)) : nil
        lock.withLock {
            dataDest = dDest
            controlDest = cDest
            sentFirstSync = false
        }
        startControlListener(control)

        // 5. Volume + keepalive
        try sendVolume(pendingVolume)
        startFeedback()
    }

    private func pairTransient(_ client: RTSPClient) throws -> Data {
        let headers = ["X-Apple-HKP": "4"]
        var m1 = TLV8()
        m1.append(.method, byte: 0)
        m1.append(.state, byte: 1)
        m1.append(.flags, byte: 0x10)
        var resp = try client.request("POST", "/pair-setup", headers: headers, body: m1.encoded(), contentType: "application/octet-stream")
        guard resp.status == 200 else { throw AirPlayError.pairing("pair-setup M1 returned \(resp.status) \(resp.reason)") }
        var tlv = TLV8.decode(resp.body)
        if let err = tlv[TLVType.error.rawValue] { throw AirPlayError.pairing("device error \(Array(err))") }
        guard let salt = tlv[TLVType.salt.rawValue], let b = tlv[TLVType.publicKey.rawValue] else {
            throw AirPlayError.pairing("M2 missing salt/public key")
        }

        let srp = SRPClient(username: "Pair-Setup", password: "3939")
        let (proof, key, expected) = try srp.process(salt: salt, serverPublicKey: b)

        var m3 = TLV8()
        m3.append(.state, byte: 3)
        m3.append(.publicKey, srp.publicKey)
        m3.append(.proof, proof)
        resp = try client.request("POST", "/pair-setup", headers: headers, body: m3.encoded(), contentType: "application/octet-stream")
        guard resp.status == 200 else { throw AirPlayError.pairing("pair-setup M3 returned \(resp.status) \(resp.reason)") }
        tlv = TLV8.decode(resp.body)
        if let err = tlv[TLVType.error.rawValue] { throw AirPlayError.pairing("device rejected proof (error \(Array(err)))") }
        guard tlv[TLVType.proof.rawValue] == expected else { throw AirPlayError.pairing("server proof mismatch") }
        return key
    }

    private func startFeedback() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, let rtsp = self.rtsp else { return }
            do {
                let r = try rtsp.request("POST", "/feedback")
                self.dlog("feedback -> \(r.status)")
                if r.status != 200 { throw AirPlayError.rtsp("feedback returned \(r.status)") }
            } catch {
                self.feedbackTimer?.cancel()
                self.feedbackTimer = nil
                self.teardownSockets()
                self.setState(.failed("connection lost: \(error)"))
            }
        }
        feedbackTimer = t
        t.resume()
    }

    // MARK: Volume (0...1)

    public func setVolume(_ v: Float) {
        volume = v
        pendingVolume = v
        queue.async { [self] in
            guard state == .streaming else { return }
            try? sendVolume(pendingVolume)
        }
    }

    private func sendVolume(_ v: Float) throws {
        guard let rtsp else { return }
        // AirPlay volume is -30...0 dB, -144 is mute.
        let db: Float = v <= 0.001 ? -144 : -30 + 30 * v
        let body = Data(String(format: "volume: %.6f\r\n", db).utf8)
        _ = try rtsp.request("SET_PARAMETER", sessionURI, body: body, contentType: "text/parameters")
    }

    // MARK: Event channel — the receiver sends RTSP requests to us here and expects replies.

    static let debug = ProcessInfo.processInfo.environment["AIRPLAY_DEBUG"] != nil
    func dlog(_ s: @autoclosure () -> String) { if AirPlaySession.debug { print("[\(target.name)] \(s())") } }

    private func startEventChannel(_ sock: TCPSocket, sharedSecret: Data) {
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "airplay-events"
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // From our side: we read what the receiver writes.
            let candidates = [
                HAPCipher(sharedSecret: sharedSecret, salt: "Events-Salt", writeInfo: "Events-Read-Encryption-Key", readInfo: "Events-Write-Encryption-Key"),
                HAPCipher(sharedSecret: sharedSecret, salt: "Events-Salt", writeInfo: "Events-Write-Encryption-Key", readInfo: "Events-Read-Encryption-Key"),
            ]
            var cipher: HAPCipher?
            var plain = Data()
            var raw = Data()
            while self?.lock.withLock({ self?.running ?? false }) ?? false {
                var buf = [UInt8](repeating: 0, count: 16384)
                let n = recv(sock.fd, &buf, buf.count, 0)
                if n == 0 { self?.dlog("event channel closed"); break }
                if n < 0 { continue }
                let chunk = Data(buf[0..<n])
                if cipher == nil {
                    raw.append(chunk)
                    for c in candidates {
                        if let p = try? c.decrypt(raw), !p.isEmpty { cipher = c; plain.append(p); break }
                    }
                    if cipher == nil { self?.dlog("event: \(raw.count) undecryptable bytes"); continue }
                } else if let p = try? cipher!.decrypt(chunk) {
                    plain.append(p)
                }
                // Answer every complete request with 200 OK.
                while let headerEnd = plain.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: plain.subdata(in: plain.startIndex..<headerEnd.lowerBound), encoding: .utf8) ?? ""
                    let lines = head.components(separatedBy: "\r\n")
                    var length = 0, cseq = "0"
                    for l in lines {
                        let lower = l.lowercased()
                        if lower.hasPrefix("content-length:") { length = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
                        if lower.hasPrefix("cseq:") { cseq = l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces) }
                    }
                    let total = headerEnd.upperBound - plain.startIndex + length
                    guard plain.count >= total else { break }
                    let body = plain.subdata(in: headerEnd.upperBound..<(plain.startIndex + total))
                    self?.dlog("event request: \(lines.first ?? "?") body=\(body.count)B \(((try? PropertyListSerialization.propertyList(from: body, format: nil)).map { "\($0)" } ?? "").prefix(300))")
                    plain = plain.subdata(in: (plain.startIndex + total)..<plain.endIndex)
                    let reply = Data("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Length: 0\r\nServer: AirTunes/366.0\r\n\r\n".utf8)
                    if let enc = try? cipher!.encrypt(reply) { try? sock.send(enc) }
                }
            }
        }
    }

    // MARK: Timing (NTP) — the receiver queries us on our timing port.

    private func startTimingResponder(_ sock: UDPSocket) {
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "airplay-timing"
            while self?.lock.withLock({ self?.running ?? false }) ?? false {
                guard let (pkt, from) = sock.receive(), pkt.count >= 32, pkt[1] & 0x7F == 0x52 else { continue }
                let recvTime = NTPTime.now()
                self?.lock.withLock { self?.stats.timingRequests += 1 }
                var reply = Data([0x80, 0xD3, 0x00, 0x07, 0, 0, 0, 0])
                reply.append(pkt.subdata(in: 24..<32)) // origin = their transmit time
                reply.appendBE(recvTime)
                reply.appendBE(NTPTime.now())
                sock.send(reply, to: from)
            }
        }
    }

    // MARK: Control channel — retransmit requests from the receiver.

    private func startControlListener(_ sock: UDPSocket) {
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "airplay-control"
            while self?.lock.withLock({ self?.running ?? false }) ?? false {
                guard let (pkt, _) = sock.receive(), pkt.count >= 8, pkt[1] & 0x7F == 0x55 else { continue }
                let first: UInt16 = pkt.readBE(4)
                let count: UInt16 = pkt.readBE(6)
                self?.lock.withLock { self?.stats.resendRequests += Int(count) }
                self?.resend(first: first, count: count)
            }
        }
    }

    private func resend(first: UInt16, count: UInt16) {
        let (packets, cDest, sock) = lock.withLock { () -> ([Data], Data?, UDPSocket?) in
            var out: [Data] = []
            for i in 0..<min(count, 64) {
                if let p = history[first &+ i] { out.append(p) }
            }
            return (out, controlDest, controlSocket)
        }
        guard let cDest, let sock else { return }
        for p in packets {
            var r = Data([0x80, 0xD6])
            r.appendBE(UInt16(1))
            r.append(p)
            sock.send(r, to: cDest)
        }
    }

    // MARK: Audio (called from streamer thread)

    func sendSync(rtpNow: UInt32, latency: UInt32) {
        let (dest, sock, first) = lock.withLock { () -> (Data?, UDPSocket?, Bool) in
            let f = !sentFirstSync
            sentFirstSync = true
            return (controlDest, controlSocket, f)
        }
        guard let dest, let sock else { return }
        var p = Data([first ? 0x90 : 0x80, 0xD4, 0x00, 0x07])
        p.appendBE(rtpNow &- latency)
        p.appendBE(NTPTime.now())
        p.appendBE(rtpNow)
        sock.send(p, to: dest)
    }

    func sendAudio(rtpTime: UInt32, alac: Data, marker: Bool) {
        let (dest, sock) = lock.withLock { (dataDest, dataSocket) }
        guard let dest, let sock else { return }
        let s = seq
        seq &+= 1

        var header = Data([0x80, marker ? 0xE0 : 0x60])
        header.appendBE(s)
        header.appendBE(rtpTime)
        header.appendBE(ssrc)

        nonceCounter &+= 1
        let nonceTail = withUnsafeBytes(of: nonceCounter.littleEndian) { Data($0) }
        let nonce = try! ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + nonceTail)
        guard let box = try? ChaChaPoly.seal(alac, using: audioKey, nonce: nonce, authenticating: header.subdata(in: 4..<12)) else { return }

        var pkt = header
        pkt.append(box.ciphertext)
        pkt.append(box.tag)
        pkt.append(nonceTail)
        sock.send(pkt, to: dest)

        lock.withLock {
            history[s] = pkt
            stats.packetsSent += 1
            history.removeValue(forKey: s &- UInt16(historyLimit))
        }
    }
}
