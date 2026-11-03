import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captures all system audio (except our own process) with a Core Audio process tap
/// and fans it out to registered ring buffers. While running, the tapped audio is
/// muted at its original destination so it only plays where we route it.
public final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let sinksLock = OSAllocatedUnfairLock()
    private var sinks: [StereoRingBuffer] = []
    private let ioQueue = DispatchQueue(label: "multiaudio.tap", qos: .userInteractive)

    public private(set) var sampleRate: Double = 48000
    public private(set) var isRunning = false

    public init() {}

    public func setSinks(_ buffers: [StereoRingBuffer]) {
        sinksLock.withLockUnchecked { sinks = buffers }
    }

    public func start() throws {
        guard !isRunning else { return }
        let desc: CATapDescription
        if let me = CA.ownProcessObject() {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        } else {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        desc.name = "MultiAudio System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        desc.uuid = UUID()

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw TapError.coreAudio("create tap", status) }
        tapID = tap

        var format = CA.get(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }

        // The aggregate needs a real device for its clock; use the current system output.
        let outputUID = CA.string(CA.defaultOutputDevice, kAudioDevicePropertyDeviceUID) ?? ""
        let aggUID = "MultiAudio-Tap-\(UUID().uuidString)"
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MultiAudio Tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if !outputUID.isEmpty {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard status == noErr else { stop(); throw TapError.coreAudio("create aggregate device", status) }
        aggregateID = agg

        let channels = Int(format.mChannelsPerFrame == 0 ? 2 : format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        format.mChannelsPerFrame = UInt32(channels)

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, agg, ioQueue) { [weak self] _, inInput, _, _, _ in
            self?.handle(inInput, channels: channels, interleaved: interleaved)
        }
        guard status == noErr else { stop(); throw TapError.coreAudio("create IO proc", status) }
        status = AudioDeviceStart(agg, ioProcID)
        guard status == noErr else { stop(); throw TapError.coreAudio("start capture", status) }
        isRunning = true
    }

    private func handle(_ list: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, let data = first.mData else { return }
        let targets = sinksLock.withLockUnchecked { sinks }
        guard !targets.isEmpty else { return }

        if interleaved || abl.count == 1 {
            let ch = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let p = data.assumingMemoryBound(to: Float.self)
            let right = ch > 1 ? p + 1 : p
            for s in targets { s.write(left: p, right: right, stride: ch, frames: frames) }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let l = data.assumingMemoryBound(to: Float.self)
            let r = (abl.count > 1 ? abl[1].mData : data)!.assumingMemoryBound(to: Float.self)
            for s in targets { s.write(left: l, right: r, stride: 1, frames: frames) }
        }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    deinit { stop() }
}

public enum TapError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    public var description: String {
        switch self {
        case .coreAudio(let what, let s):
            if s == 0x77686174 /* 'what' */ || s == -1 { return "Couldn't \(what) — check System Audio Recording permission" }
            return "Couldn't \(what) (error \(s))"
        }
    }
}
