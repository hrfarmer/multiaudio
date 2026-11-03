import Darwin
import Foundation

/// Minimal blocking BSD-socket wrappers. AirPlay control traffic is low-volume
/// request/response, so blocking IO on a dedicated queue keeps things simple.
final class TCPSocket {
    let fd: Int32
    let localAddress: String
    let remoteAddress: String
    let isIPv6: Bool

    init(host: String, port: UInt16, timeout: TimeInterval = 5) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw AirPlayError.network("cannot resolve \(host): \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(res) }

        // Prefer IPv4 (simpler for the local-address reporting AirPlay wants), fall back to anything.
        var candidates: [UnsafeMutablePointer<addrinfo>] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p { candidates.append(cur); p = cur.pointee.ai_next }
        candidates.sort { ($0.pointee.ai_family == AF_INET ? 0 : 1) < ($1.pointee.ai_family == AF_INET ? 0 : 1) }

        var lastErr = "no addresses"
        for ai in candidates {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s < 0 { continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            // Non-blocking connect with timeout.
            let flags = fcntl(s, F_GETFL)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            var r = connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if r < 0 && errno == EINPROGRESS {
                var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                r = poll(&pfd, 1, Int32(timeout * 1000))
                if r == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                    r = err == 0 ? 0 : -1
                    if err != 0 { lastErr = String(cString: strerror(err)) }
                } else {
                    lastErr = "connect timed out"
                    r = -1
                }
            } else if r < 0 {
                lastErr = String(cString: strerror(errno))
            }
            if r == 0 {
                _ = fcntl(s, F_SETFL, flags)
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                fd = s
                isIPv6 = ai.pointee.ai_family == AF_INET6
                localAddress = TCPSocket.sockName(s, peer: false)
                remoteAddress = TCPSocket.sockName(s, peer: true)
                return
            }
            close(s)
        }
        throw AirPlayError.network("cannot connect to \(host):\(port): \(lastErr)")
    }

    static func sockName(_ fd: Int32, peer: Bool) -> String {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let r = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                peer ? getpeername(fd, $0, &len) : getsockname(fd, $0, &len)
            }
        }
        guard r == 0 else { return "0.0.0.0" }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        _ = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        var s = String(cString: host)
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        return s
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + off, buf.count - off, 0)
                if n <= 0 { throw AirPlayError.network("send failed: \(String(cString: strerror(errno)))") }
                off += n
            }
        }
    }

    func receive(max: Int = 65536) throws -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        let n = recv(fd, &buf, max, 0)
        if n == 0 { throw AirPlayError.network("connection closed") }
        if n < 0 { throw AirPlayError.network("recv failed: \(String(cString: strerror(errno)))") }
        return Data(buf[0..<n])
    }

    func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    deinit { close(fd) }
}

/// UDP socket bound to an ephemeral local port.
final class UDPSocket {
    let fd: Int32
    let port: UInt16
    let family: Int32

    init(ipv6: Bool) throws {
        let fam = ipv6 ? AF_INET6 : AF_INET
        let s = socket(fam, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw AirPlayError.network("udp socket failed") }
        var r: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_any
            r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = INADDR_ANY
            r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard r == 0 else { Darwin.close(s); throw AirPlayError.network("udp bind failed") }
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        // sin_port and sin6_port sit at the same offset.
        port = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        family = fam
    }

    /// Builds a destination address for `host` (numeric) and `port`.
    func destination(host: String, port: UInt16) -> Data? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: family, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        return Data(bytes: ai.pointee.ai_addr, count: Int(ai.pointee.ai_addrlen))
    }

    func send(_ data: Data, to dest: Data) {
        data.withUnsafeBytes { buf in
            dest.withUnsafeBytes { d in
                _ = sendto(fd, buf.baseAddress, buf.count, 0, d.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(d.count))
            }
        }
    }

    /// Receives one datagram (or nil on timeout). Returns the sender address too.
    func receive() -> (Data, Data)? {
        var buf = [UInt8](repeating: 0, count: 2048)
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0 else { return nil }
        let addr = withUnsafePointer(to: &storage) { Data(bytes: $0, count: Int(len)) }
        return (Data(buf[0..<n]), addr)
    }

    func close() { Darwin.close(fd) }
}

// MARK: - RTSP

struct RTSPResponse {
    var status: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var plist: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }
}

final class RTSPClient {
    let socket: TCPSocket
    var cipher: HAPCipher?
    private var cseq = 0
    private var buffer = Data()
    var baseHeaders: [String: String] = [:]

    init(socket: TCPSocket) { self.socket = socket }

    func request(_ method: String, _ uri: String, headers: [String: String] = [:], body: Data? = nil, contentType: String? = nil) throws -> RTSPResponse {
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)"]
        for (k, v) in baseHeaders.merging(headers, uniquingKeysWith: { $1 }) { lines.append("\(k): \(v)") }
        if let contentType { lines.append("Content-Type: \(contentType)") }
        lines.append("Content-Length: \(body?.count ?? 0)")
        var msg = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { msg.append(body) }

        try socket.send(cipher.map { try $0.encrypt(msg) } ?? msg)
        let resp = try readResponse()
        return resp
    }

    func plistRequest(_ method: String, _ uri: String, _ plist: [String: Any], headers: [String: String] = [:]) throws -> RTSPResponse {
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        return try request(method, uri, headers: headers, body: body, contentType: "application/x-apple-binary-plist")
    }

    private func fill() throws {
        let chunk = try socket.receive()
        if let cipher { buffer.append(try cipher.decrypt(chunk)) } else { buffer.append(chunk) }
    }

    private func readResponse() throws -> RTSPResponse {
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while true {
            headerEnd = buffer.range(of: sep)
            if headerEnd != nil { break }
            try fill()
        }
        let headData = buffer.subdata(in: buffer.startIndex..<headerEnd!.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { throw AirPlayError.rtsp("bad response header") }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw AirPlayError.rtsp("bad status line") }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[String(l[..<c]).trimmingCharacters(in: .whitespaces)] = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
        let bodyStart = headerEnd!.upperBound
        while buffer.count - (bodyStart - buffer.startIndex) < length { try fill() }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer = buffer.subdata(in: (bodyStart + length)..<buffer.endIndex)
        return RTSPResponse(status: status, reason: statusLine.count > 2 ? statusLine[2] : "", headers: headers, body: body)
    }
}
