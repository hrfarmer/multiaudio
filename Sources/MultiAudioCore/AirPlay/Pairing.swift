import BigInt
import CryptoKit
import Foundation

// MARK: - TLV8 (HomeKit style)

enum TLVType: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case flags = 0x13
}

struct TLV8 {
    private(set) var items: [(UInt8, Data)] = []

    init() {}

    mutating func append(_ type: TLVType, _ value: Data) { items.append((type.rawValue, value)) }
    mutating func append(_ type: TLVType, byte: UInt8) { append(type, Data([byte])) }

    func encoded() -> Data {
        var out = Data()
        for (type, value) in items {
            if value.isEmpty {
                out.append(type); out.append(0)
                continue
            }
            var offset = 0
            while offset < value.count {
                let len = min(255, value.count - offset)
                out.append(type)
                out.append(UInt8(len))
                out.append(value.subdata(in: (value.startIndex + offset)..<(value.startIndex + offset + len)))
                offset += len
            }
        }
        return out
    }

    /// Decodes and merges fragmented consecutive items of the same type.
    static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        let bytes = [UInt8](data)
        var i = 0
        var lastType: UInt8?
        while i + 2 <= bytes.count {
            let t = bytes[i], l = Int(bytes[i + 1])
            i += 2
            guard i + l <= bytes.count else { break }
            let v = Data(bytes[i..<(i + l)])
            i += l
            if lastType == t, result[t] != nil { result[t]!.append(v) } else { result[t] = v }
            lastType = t
        }
        return result
    }
}

// MARK: - SRP-6a (RFC 5054 3072-bit group, SHA-512), as used by HomeKit / AirPlay 2

struct SRPClient {
    // RFC 5054 3072-bit prime
    static let N = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
            + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
            + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
            + "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
            + "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
            + "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
            + "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
            + "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
        radix: 16)!
    static let g = BigUInt(5)
    static let nLen = 384

    let username: String
    let password: String
    private let a: BigUInt
    let A: BigUInt

    init(username: String, password: String) {
        self.username = username
        self.password = password
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        a = BigUInt(Data(bytes))
        A = SRPClient.g.power(a, modulus: SRPClient.N)
    }

    static func H(_ parts: Data...) -> Data {
        var h = SHA512()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    static func pad(_ n: BigUInt) -> Data {
        let d = n.serialize()
        if d.count >= nLen { return d }
        return Data(repeating: 0, count: nLen - d.count) + d
    }

    var publicKey: Data { SRPClient.pad(A) }

    /// Computes client proof M1 and session key K from server salt and B.
    func process(salt: Data, serverPublicKey: Data) throws -> (m1: Data, key: Data, expectedM2: Data) {
        let N = SRPClient.N, g = SRPClient.g
        let B = BigUInt(serverPublicKey)
        guard B % N != 0 else { throw AirPlayError.pairing("invalid server public key") }

        let k = BigUInt(SRPClient.H(N.serialize(), SRPClient.pad(g)))
        let u = BigUInt(SRPClient.H(SRPClient.pad(A), SRPClient.pad(B)))
        let inner = SRPClient.H(Data("\(username):\(password)".utf8))
        let x = BigUInt(SRPClient.H(salt, inner))

        let gx = g.power(x, modulus: N)
        let kgx = (k * gx) % N
        let base = (B + N - kgx) % N
        let S = base.power(a + u * x, modulus: N)
        let K = SRPClient.H(S.serialize())

        let hN = SRPClient.H(N.serialize())
        let hg = SRPClient.H(g.serialize())
        let hxor = Data(zip(hN, hg).map { $0 ^ $1 })
        let hI = SRPClient.H(Data(username.utf8))
        let m1 = SRPClient.H(hxor, hI, salt, A.serialize(), B.serialize(), K)
        let m2 = SRPClient.H(A.serialize(), m1, K)
        return (m1, K, m2)
    }
}

// MARK: - HAP framed ChaCha20-Poly1305 channel encryption

final class HAPCipher {
    private let writeKey: SymmetricKey
    private let readKey: SymmetricKey
    private var writeCounter: UInt64 = 0
    private var readCounter: UInt64 = 0
    private var pending = Data()

    init(sharedSecret: Data, salt: String, writeInfo: String, readInfo: String) {
        let ikm = SymmetricKey(data: sharedSecret)
        writeKey = HKDF<SHA512>.deriveKey(inputKeyMaterial: ikm, salt: Data(salt.utf8), info: Data(writeInfo.utf8), outputByteCount: 32)
        readKey = HKDF<SHA512>.deriveKey(inputKeyMaterial: ikm, salt: Data(salt.utf8), info: Data(readInfo.utf8), outputByteCount: 32)
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var n = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { n.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: n)
    }

    func encrypt(_ plain: Data) throws -> Data {
        var out = Data()
        var offset = 0
        while offset < plain.count {
            let len = min(1024, plain.count - offset)
            let chunk = plain.subdata(in: offset..<(offset + len))
            var aad = Data()
            withUnsafeBytes(of: UInt16(len).littleEndian) { aad.append(contentsOf: $0) }
            let box = try ChaChaPoly.seal(chunk, using: writeKey, nonce: HAPCipher.nonce(writeCounter), authenticating: aad)
            writeCounter += 1
            out.append(aad)
            out.append(box.ciphertext)
            out.append(box.tag)
            offset += len
        }
        return out
    }

    /// Feed received bytes; returns any fully decrypted plaintext.
    func decrypt(_ incoming: Data) throws -> Data {
        pending.append(incoming)
        var out = Data()
        while pending.count >= 2 {
            let len = Int(pending[pending.startIndex]) | (Int(pending[pending.startIndex + 1]) << 8)
            let total = 2 + len + 16
            guard pending.count >= total else { break }
            let s = pending.startIndex
            let aad = pending.subdata(in: s..<(s + 2))
            let ct = pending.subdata(in: (s + 2)..<(s + 2 + len))
            let tag = pending.subdata(in: (s + 2 + len)..<(s + total))
            let box = try ChaChaPoly.SealedBox(nonce: HAPCipher.nonce(readCounter), ciphertext: ct, tag: tag)
            out.append(try ChaChaPoly.open(box, using: readKey, authenticating: aad))
            readCounter += 1
            pending = pending.subdata(in: (s + total)..<pending.endIndex)
        }
        return out
    }
}

public enum AirPlayError: Error, CustomStringConvertible {
    case pairing(String)
    case rtsp(String)
    case network(String)

    public var description: String {
        switch self {
        case .pairing(let s): return "Pairing failed: \(s)"
        case .rtsp(let s): return "AirPlay: \(s)"
        case .network(let s): return "Network: \(s)"
        }
    }
}
