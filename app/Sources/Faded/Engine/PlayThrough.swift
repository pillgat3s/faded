// PlayThrough.swift — moves audio from the hidden "Faded Tap" device to the
// real output device.
//
//   Faded Tap ──AUHAL(input)──▶ RingBuffer ──AUHAL(output)──▶ target device
//
// Two AUHAL units instead of AVAudioEngine because we need to pin each side to
// a specific device and keep the real-time path trivial. The output AUHAL does
// any sample-rate conversion to the target device's rate for us (we feed it
// Float32 stereo at the Tap's rate); the input AUHAL requires our client format
// rate to equal the Tap's rate, which DriverLink guarantees.

import AudioToolbox
import CoreAudio
import Foundation
import os

final class PlayThrough: @unchecked Sendable {
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "PlayThrough")

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private let ring = RingBuffer(channels: FadedProtocol.channelCount)
    private var inputBufferList: UnsafeMutableAudioBufferListPointer?
    private var inputBufferCapacity: UInt32 = 0
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    private(set) var tapDeviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown

    var stats: (available: Int, underruns: UInt64, overruns: UInt64, trims: UInt64) {
        (ring.availableFrames, ring.underruns.load(ordering: .relaxed),
         ring.overruns.load(ordering: .relaxed), ring.trims.load(ordering: .relaxed))
    }

    deinit { stop() }

    // MARK: Lifecycle

    func start(tap: AudioDeviceID, output: AudioDeviceID, sampleRate: Double) throws {
        stop()
        tapDeviceID = tap
        outputDeviceID = output
        self.sampleRate = sampleRate
        ring.reset()

        let format = Self.clientFormat(rate: sampleRate)
        do {
            try startInput(device: tap, format: format)
            try startOutput(device: output, format: format)
        } catch {
            stop()
            throw error
        }
        isRunning = true
        Self.log.info("started tap=\(tap) out=\(output) rate=\(sampleRate)")
    }

    func stop() {
        if let u = outputUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
        if let u = inputUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
        outputUnit = nil
        inputUnit = nil
        if let bl = inputBufferList {
            for b in bl { b.mData?.deallocate() }
            free(bl.unsafeMutablePointer)
            inputBufferList = nil
        }
        isRunning = false
    }

    /// Swap only the output device (e.g. user picked AirPods). Keeps the input side.
    func retarget(output: AudioDeviceID) throws {
        guard isRunning else { return }
        if let u = outputUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
        outputUnit = nil
        outputDeviceID = output
        ring.reset()
        try startOutput(device: output, format: Self.clientFormat(rate: sampleRate))
        Self.log.info("retargeted out=\(output)")
    }

    // MARK: Format

    private static func clientFormat(rate: Double) -> AudioStreamBasicDescription {
        var f = AudioStreamBasicDescription()
        f.mSampleRate = rate
        f.mFormatID = kAudioFormatLinearPCM
        f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked // interleaved float32
        f.mChannelsPerFrame = UInt32(FadedProtocol.channelCount)
        f.mBitsPerChannel = 32
        f.mBytesPerFrame = 4 * f.mChannelsPerFrame
        f.mFramesPerPacket = 1
        f.mBytesPerPacket = f.mBytesPerFrame
        return f
    }

    private static func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw AudioError.notFound("AUHAL component") }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
        guard let u = unit else { throw AudioError.notFound("AUHAL instance") }
        return u
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw AudioError.osStatus(status, what) }
    }

    // MARK: Input side (reads from Faded Tap)

    private func startInput(device: AudioDeviceID, format: AudioStreamBasicDescription) throws {
        let unit = try Self.makeHALUnit()
        inputUnit = unit
        var one: UInt32 = 1
        var zero: UInt32 = 0
        var fmt = format
        var dev = device
        // Bus 1 = input, bus 0 = output on AUHAL.
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set input device")
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set input client format")

        var maxFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
        if maxFrames == 0 { maxFrames = 4096 }
        allocateInputBuffer(frames: maxFrames, channels: format.mChannelsPerFrame)

        var cb = AURenderCallbackStruct(inputProc: playThroughInputProc,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try Self.check(AudioUnitInitialize(unit), "init input unit")
        try Self.check(AudioOutputUnitStart(unit), "start input unit")
    }

    private func allocateInputBuffer(frames: UInt32, channels: UInt32) {
        let bl = AudioBufferList.allocate(maximumBuffers: 1)
        bl[0].mNumberChannels = channels
        bl[0].mDataByteSize = frames * channels * 4
        bl[0].mData = UnsafeMutableRawPointer.allocate(byteCount: Int(frames * channels * 4), alignment: 16)
        inputBufferList = bl
        inputBufferCapacity = frames
    }

    /// Real-time: pull the freshly captured frames and push them into the ring.
    fileprivate func handleInput(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 timestamp: UnsafePointer<AudioTimeStamp>,
                                 bus: UInt32, frames: UInt32)
    {
        guard let unit = inputUnit, let bl = inputBufferList, frames <= inputBufferCapacity else { return }
        bl[0].mDataByteSize = frames * bl[0].mNumberChannels * 4
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, bl.unsafeMutablePointer)
        guard status == noErr, let data = bl[0].mData else { return }
        ring.write(data.assumingMemoryBound(to: Float.self), frames: Int(frames))
    }

    // MARK: Output side (plays to the real device)

    private func startOutput(device: AudioDeviceID, format: AudioStreamBasicDescription) throws {
        let unit = try Self.makeHALUnit()
        outputUnit = unit
        var one: UInt32 = 1
        var zero: UInt32 = 0
        var fmt = format
        var dev = device
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4), "enable output")
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, 4), "disable input")
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set output device")
        // Client format on the input scope of bus 0: what *we* provide. AUHAL
        // converts to the device's physical format & rate.
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set output client format")

        var cb = AURenderCallbackStruct(inputProc: playThroughRenderProc,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render callback")
        try Self.check(AudioUnitInitialize(unit), "init output unit")
        try Self.check(AudioOutputUnitStart(unit), "start output unit")
    }

    /// Real-time: fill the output buffer from the ring.
    fileprivate func handleRender(frames: UInt32, data: UnsafeMutablePointer<AudioBufferList>) {
        let bl = UnsafeMutableAudioBufferListPointer(data)
        guard let out = bl[0].mData else { return }
        ring.read(into: out.assumingMemoryBound(to: Float.self), frames: Int(frames))
    }
}

// MARK: - C callbacks

private func playThroughInputProc(refCon: UnsafeMutableRawPointer,
                                  flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                  timestamp: UnsafePointer<AudioTimeStamp>,
                                  bus: UInt32, frames: UInt32,
                                  _: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    let me = Unmanaged<PlayThrough>.fromOpaque(refCon).takeUnretainedValue()
    me.handleInput(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
    return noErr
}

private func playThroughRenderProc(refCon: UnsafeMutableRawPointer,
                                   _: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                   _: UnsafePointer<AudioTimeStamp>,
                                   _: UInt32, frames: UInt32,
                                   data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    guard let data else { return noErr }
    let me = Unmanaged<PlayThrough>.fromOpaque(refCon).takeUnretainedValue()
    me.handleRender(frames: frames, data: data)
    return noErr
}
