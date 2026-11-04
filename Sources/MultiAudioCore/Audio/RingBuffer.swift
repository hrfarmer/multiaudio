import Foundation
import os

/// Interleaved stereo Float32 ring buffer with a "target delay" reader.
///
/// One writer (the tap IO thread) and one reader (an output render thread).
/// The reader keeps the buffered amount near `targetFrames`, in either direction:
/// it waits (outputs silence) when too little is queued and drops audio when too
/// much is, so changing the target takes effect mid-stream and clock drift between
/// devices is absorbed.
public final class StereoRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var writePos: Int = 0
    private var readPos: Int = 0
    private var priming = true
    /// Set when the target changes, so the next read lands exactly on the new delay.
    private var realign = false
    /// How far the backlog may wander from the target before it's corrected. Must exceed
    /// normal IO-cycle jitter, and stays small because this is also the sync error.
    private static let driftTolerance = 2048
    private let lock = OSAllocatedUnfairLock()

    /// Frames of buffered audio the reader aims to keep (sets the output delay).
    public var targetFrames: Int {
        get { lock.withLockUnchecked { _target } }
        set {
            lock.withLockUnchecked {
                let target = max(256, min(newValue, capacity - 4096))
                if target != _target { realign = true }
                _target = target
            }
        }
    }
    private var _target: Int

    public init(capacityFrames: Int, targetFrames: Int) {
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
        _target = max(256, min(targetFrames, capacityFrames - 4096))
    }

    deinit { storage.deallocate() }

    public var fill: Int { lock.withLockUnchecked { writePos - readPos } }

    /// Writes `frames` frames. `left`/`right` may point into the same interleaved buffer via `stride`.
    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, frames: Int) {
        lock.withLockUnchecked {
            for i in 0..<frames {
                let idx = (writePos + i) % capacity
                storage[idx * 2] = left[i * stride]
                storage[idx * 2 + 1] = right[i * stride]
            }
            writePos += frames
            if writePos - readPos > capacity { readPos = writePos - capacity }
        }
    }

    /// Reads up to `frames` interleaved frames into `out`, scaled by `gain`. Missing audio is zero-filled.
    public func read(into out: UnsafeMutablePointer<Float>, frames: Int, gain: Float) {
        lock.withLockUnchecked {
            var available = writePos - readPos
            let tolerance = Self.driftTolerance
            let exact = realign
            realign = false
            if available < _target - (exact ? 0 : tolerance) { priming = true }
            if priming {
                guard available >= _target else {
                    out.update(repeating: 0, count: frames * 2)
                    return
                }
                priming = false
                readPos = writePos - _target
                available = _target
            } else if available > _target + (exact ? 0 : tolerance) {
                readPos = writePos - _target
                available = _target
            }
            let n = min(frames, available)
            for i in 0..<n {
                let idx = (readPos + i) % capacity
                out[i * 2] = storage[idx * 2] * gain
                out[i * 2 + 1] = storage[idx * 2 + 1] * gain
            }
            readPos += n
            if n < frames {
                (out + n * 2).update(repeating: 0, count: (frames - n) * 2)
                priming = true // underrun: rebuild the cushion
            }
        }
    }

    public func reset() {
        lock.withLockUnchecked {
            readPos = writePos
            priming = true
        }
    }
}
