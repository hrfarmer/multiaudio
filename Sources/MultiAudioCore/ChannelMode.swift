/// Which part of the stereo signal an output plays. Left and Right send that channel to both
/// sides, so a speaker that mixes to mono (HomePods, the Mac mini) plays only that channel.
public enum ChannelMode: String, CaseIterable, Sendable {
    case stereo, left, right

    /// Rewrites interleaved stereo in place.
    @inline(__always)
    func apply<Sample>(to interleaved: UnsafeMutablePointer<Sample>, frames: Int) {
        switch self {
        case .stereo: break
        case .left: for i in 0..<frames { interleaved[i * 2 + 1] = interleaved[i * 2] }
        case .right: for i in 0..<frames { interleaved[i * 2] = interleaved[i * 2 + 1] }
        }
    }
}
