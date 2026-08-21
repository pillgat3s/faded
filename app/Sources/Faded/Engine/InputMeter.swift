// InputMeter.swift — live level for one input device.
//
// There is no CoreAudio property that reports an input's signal level, so the
// only way to draw a mic meter is to open a capture unit and measure. This
// class does exactly that and nothing else: it computes a decaying peak per
// buffer and immediately discards the samples. Nothing is stored, buffered or
// written anywhere.
//
// It runs *only* while the menu is open (`start`/`stop` from the popover), so
// the microphone indicator isn't lit while you're not looking at Faded.
//
// Bluetooth is deliberately excluded: opening a capture stream on an AirPods-
// class device drags the link from A2DP down to the HFP profile, which audibly
// wrecks playback. Those rows show no meter — see `canMeter(_:)`.

import AudioToolbox
import CoreAudio
import Foundation
import os

final class InputMeter: @unchecked Sendable {
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "InputMeter")

    private var unit: AudioUnit?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var capacityFrames: UInt32 = 0
    private var channels: UInt32 = 1

    private let peakL = OSAllocatedUnfairLock(initialState: Float(0))
    private let peakR = OSAllocatedUnfairLock(initialState: Float(0))

    private(set) var deviceID: AudioDeviceID = kAudioObjectUnknown
    var isRunning: Bool { unit != nil }

    /// Level as (left, right), 0…1, decaying.
    var level: (Float, Float) {
        (peakL.withLock { $0 }, peakR.withLock { $0 })
    }

    /// Metering a Bluetooth device would force the HFP profile and degrade
    /// playback, so we don't.
    static func canMeter(_ device: AudioDevice) -> Bool {
        device.hasInput && device.transport != .bluetooth
    }

    deinit { stop() }

    func start(device: AudioDevice) {
        guard Self.canMeter(device) else { stop(); return }
        if isRunning, deviceID == device.id { return }
        stop()

        do {
            var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                 componentSubType: kAudioUnitSubType_HALOutput,
                                                 componentManufacturer: kAudioUnitManufacturer_Apple,
                                                 componentFlags: 0, componentFlagsMask: 0)
            guard let comp = AudioComponentFindNext(nil, &desc) else { return }
            var u: AudioUnit?
            try check(AudioComponentInstanceNew(comp, &u), "new")
            guard let u else { return }
            unit = u
            deviceID = device.id

            var one: UInt32 = 1
            var zero: UInt32 = 0
            var dev = device.id
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable in")
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable out")
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "device")

            // Match the device's own rate so no conversion is needed; mono is
            // enough for a meter unless the device is stereo.
            var deviceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size)
            channels = min(max(deviceFormat.mChannelsPerFrame, 1), 2)

            var fmt = AudioStreamBasicDescription()
            fmt.mSampleRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48000
            fmt.mFormatID = kAudioFormatLinearPCM
            fmt.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
            fmt.mChannelsPerFrame = channels
            fmt.mBitsPerChannel = 32
            fmt.mBytesPerFrame = 4 * channels
            fmt.mFramesPerPacket = 1
            fmt.mBytesPerPacket = fmt.mBytesPerFrame
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "format")

            var maxFrames: UInt32 = 0
            var s2 = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &s2)
            if maxFrames == 0 { maxFrames = 4096 }
            let bl = AudioBufferList.allocate(maximumBuffers: 1)
            bl[0].mNumberChannels = channels
            bl[0].mDataByteSize = maxFrames * channels * 4
            bl[0].mData = UnsafeMutableRawPointer.allocate(byteCount: Int(maxFrames * channels * 4), alignment: 16)
            bufferList = bl
            capacityFrames = maxFrames

            var cb = AURenderCallbackStruct(inputProc: inputMeterProc,
                                            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "callback")
            try check(AudioUnitInitialize(u), "init")
            try check(AudioOutputUnitStart(u), "start")
        } catch {
            Self.log.info("meter unavailable for \(device.name, privacy: .public): \(String(describing: error))")
            stop()
        }
    }

    func stop() {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        unit = nil
        deviceID = kAudioObjectUnknown
        if let bl = bufferList {
            for b in bl { b.mData?.deallocate() }
            free(bl.unsafeMutablePointer)
            bufferList = nil
        }
        peakL.withLock { $0 = 0 }
        peakR.withLock { $0 = 0 }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw AudioError.osStatus(status, "InputMeter \(what)") }
    }

    /// Real-time: render, measure, discard.
    fileprivate func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             timestamp: UnsafePointer<AudioTimeStamp>,
                             bus: UInt32, frames: UInt32)
    {
        guard let u = unit, let bl = bufferList, frames <= capacityFrames else { return }
        bl[0].mDataByteSize = frames * channels * 4
        guard AudioUnitRender(u, flags, timestamp, bus, frames, bl.unsafeMutablePointer) == noErr,
              let data = bl[0].mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)

        var l: Float = 0
        var r: Float = 0
        if channels == 1 {
            for i in 0 ..< Int(frames) { l = max(l, abs(samples[i])) }
            r = l
        } else {
            for i in 0 ..< Int(frames) {
                l = max(l, abs(samples[i * 2]))
                r = max(r, abs(samples[i * 2 + 1]))
            }
        }
        let newL = l, newR = r
        peakL.withLock { $0 = max(newL, $0 * 0.85) }
        peakR.withLock { $0 = max(newR, $0 * 0.85) }
        // samples go out of scope here; nothing is retained.
    }
}

private func inputMeterProc(refCon: UnsafeMutableRawPointer,
                            flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32,
                            _: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    Unmanaged<InputMeter>.fromOpaque(refCon).takeUnretainedValue()
        .capture(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
    return noErr
}
