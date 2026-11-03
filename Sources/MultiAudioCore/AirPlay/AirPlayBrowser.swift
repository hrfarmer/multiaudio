import Foundation
import Network
import SystemConfiguration

public struct DiscoveredAirPlayDevice: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let model: String
    let endpoint: NWEndpoint

    public static func == (a: Self, b: Self) -> Bool { a.name == b.name && a.model == b.model }
    public func hash(into h: inout Hasher) { h.combine(name) }
}

/// Browses `_airplay._tcp` for audio-capable receivers (excluding this Mac).
public final class AirPlayBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    public var onChange: (([DiscoveredAirPlayDevice]) -> Void)?
    public var onLog: ((String) -> Void)?

    public init() {}

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: params)
        let ownName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? ""
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            var devices: [DiscoveredAirPlayDevice] = []
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                guard name != ownName, !seen.contains(name) else { continue }
                var model = ""
                var supportsAudio = true
                if case let .bonjour(txt) = r.metadata {
                    model = txt["model"] ?? ""
                    if let f = txt["features"]?.split(separator: ",").first,
                       let bits = UInt64(f.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                        supportsAudio = bits & 0x200 != 0
                    }
                }
                guard supportsAudio else { continue }
                seen.insert(name)
                devices.append(DiscoveredAirPlayDevice(name: name, model: model, endpoint: r.endpoint))
            }
            self?.onLog?("browser: \(results.count) results, \(devices.count) audio devices")
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.onChange?(devices) }
        }
        b.stateUpdateHandler = { [weak self] st in self?.onLog?("browser state: \(st)") }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Resolves a Bonjour service to a numeric host + port (IPv4 preferred).
    public static func resolve(_ device: DiscoveredAirPlayDevice, timeout: TimeInterval = 5) async throws -> AirPlayTarget {
        func attempt(v4Only: Bool) async throws -> AirPlayTarget {
            let params = NWParameters.tcp
            if v4Only, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let conn = NWConnection(to: device.endpoint, using: params)
            return try await withCheckedThrowingContinuation { cont in
                let once = OnceFlag()
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint, once.claim() {
                            var h = "\(host)"
                            // IPv4 never needs a scope; IPv6 link-local keeps "%iface" for getaddrinfo.
                            if case .ipv4 = host, let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                            cont.resume(returning: AirPlayTarget(name: device.name, host: h, port: port.rawValue))
                        }
                        conn.cancel()
                    case .failed(let e), .waiting(let e):
                        if once.claim() { cont.resume(throwing: AirPlayError.network("cannot reach \(device.name): \(e)")) }
                        conn.cancel()
                    default: break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if once.claim() { cont.resume(throwing: AirPlayError.network("timed out resolving \(device.name)")); conn.cancel() }
                }
            }
        }
        do { return try await attempt(v4Only: true) } catch { return try await attempt(v4Only: false) }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
