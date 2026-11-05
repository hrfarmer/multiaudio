import AudioToolbox
import CoreAudio
import Foundation

/// Plays a ring buffer to one CoreAudio output device via an AUHAL unit,
/// with its own software gain. AUHAL does any sample-rate conversion.
public final class LocalOutput: @unchecked Sendable {
    public let device: OutputDeviceInfo
    public let buffer: StereoRingBuffer
    private var unit: AudioUnit?
    private var gain: Float = 1
    public var channels: ChannelMode = .stereo

    public init(device: OutputDeviceInfo, sampleRate: Double, delayFrames: Int) {
        self.device = device
        buffer = StereoRingBuffer(capacityFrames: Int(sampleRate * 8), targetFrames: delayFrames)
    }

    deinit { stop() }

    /// 0...1 slider value; mapped to a perceptual gain curve.
    public func setVolume(_ v: Float) { gain = v * v }

    public func start(sampleRate: Double) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw TapError.coreAudio("find HAL output", -1) }
        var au: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &au)
        guard status == noErr, let au else { throw TapError.coreAudio("create output unit", status) }
        unit = au

        var dev = device.deviceID
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { stop(); throw TapError.coreAudio("select \(device.name)", status) }

        var fmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                              mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                      &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { stop(); throw TapError.coreAudio("set format on \(device.name)", status) }

        var cb = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData in
            let me = Unmanaged<LocalOutput>.fromOpaque(refCon).takeUnretainedValue()
            guard let ioData else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ioData)
            guard let data = abl.first?.mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            me.buffer.read(into: out, frames: Int(frames), gain: me.gain)
            me.channels.apply(to: out, frames: Int(frames))
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                      &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { stop(); throw TapError.coreAudio("set render callback", status) }

        status = AudioUnitInitialize(au)
        guard status == noErr else { stop(); throw TapError.coreAudio("initialize \(device.name)", status) }
        status = AudioOutputUnitStart(au)
        guard status == noErr else { stop(); throw TapError.coreAudio("start \(device.name)", status) }
    }

    public func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}
