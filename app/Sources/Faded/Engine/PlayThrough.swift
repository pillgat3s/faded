// PlayThrough.swift — plays what the driver produced to the real output device.
//
//   driver (inside coreaudiod) ──▶ shared memory ring ──▶ this ──▶ target device
//
// There is exactly one audio unit here, and it is an *output* unit. That is the
// whole point: an earlier version read the audio back through a hidden input
// device, which works but makes macOS light the orange microphone indicator for
// as long as Faded is routing audio — the OS does not distinguish a hidden
// virtual device from a real microphone. Pulling the frames out of shared
// memory instead means this process never opens an input stream at all, so no
// indicator appears, and it removes a whole device and one buffer of latency
// along the way.

import AudioToolbox
import CoreAudio
import Foundation
import os

final class PlayThrough: @unchecked Sendable {
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "PlayThrough")

    private var outputUnit: AudioUnit?
    let reader = SharedRingReader()

    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown

    var stats: (underruns: UInt64, resyncs: UInt64, overruns: UInt64, producing: Bool) {
        (reader.underruns, reader.resyncs, reader.overruns, reader.producerRunning)
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// - Parameter sampleRate: the rate the *driver* is running at. The output
    ///   unit converts to whatever the target device wants.
    func start(output: AudioDeviceID, sampleRate: Double) throws {
        stop()
        guard reader.open() else {
            throw AudioError.notFound("shared audio ring (driver not installed, or too old)")
        }
        outputDeviceID = output
        // The ring publishes the rate the driver is actually producing at; the
        // caller's value is only a fallback for a driver too old to publish it.
        self.sampleRate = reader.sampleRate ?? sampleRate

        do {
            try startOutput(device: output, format: Self.clientFormat(rate: self.sampleRate))
        } catch {
            stop()
            throw error
        }
        isRunning = true
        Self.log.info("started out=\(output) rate=\(self.sampleRate)")
    }

    func stop() {
        if let u = outputUnit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        outputUnit = nil
        reader.close()
        isRunning = false
    }

    /// Swap the destination without disturbing the producer side.
    func retarget(output: AudioDeviceID) throws {
        guard isRunning else { return }
        if let u = outputUnit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        outputUnit = nil
        outputDeviceID = output
        try startOutput(device: output, format: Self.clientFormat(rate: sampleRate))
        Self.log.info("retargeted out=\(output)")
    }

    // MARK: Setup

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

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw AudioError.osStatus(status, what) }
    }

    private func startOutput(device: AudioDeviceID, format: AudioStreamBasicDescription) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw AudioError.notFound("AUHAL component") }
        var unit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
        guard let u = unit else { throw AudioError.notFound("AUHAL instance") }
        outputUnit = u

        var one: UInt32 = 1
        var zero: UInt32 = 0
        var fmt = format
        var dev = device
        try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4), "enable output")
        // Explicitly off. Leaving input enabled would open a capture stream and
        // bring the microphone indicator straight back.
        try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, 4), "disable input")
        try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                            &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set output device")
        // What we supply on bus 0's input scope; AUHAL converts to the device's
        // own format and rate.
        try Self.check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                            &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set output client format")

        var cb = AURenderCallbackStruct(inputProc: playThroughRenderProc,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render callback")
        try Self.check(AudioUnitInitialize(u), "init output unit")
        try Self.check(AudioOutputUnitStart(u), "start output unit")
    }

    /// Real-time: pull straight from shared memory into the output buffer.
    fileprivate func handleRender(frames: UInt32, data: UnsafeMutablePointer<AudioBufferList>) {
        let bl = UnsafeMutableAudioBufferListPointer(data)
        guard let out = bl[0].mData else { return }
        reader.read(into: out.assumingMemoryBound(to: Float.self), frames: frames)
    }
}

private func playThroughRenderProc(refCon: UnsafeMutableRawPointer,
                                   _: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                   _: UnsafePointer<AudioTimeStamp>,
                                   _: UInt32, frames: UInt32,
                                   data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    guard let data else { return noErr }
    Unmanaged<PlayThrough>.fromOpaque(refCon).takeUnretainedValue()
        .handleRender(frames: frames, data: data)
    return noErr
}
