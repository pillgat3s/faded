// TapProbe.swift — is Apple's process-tap route viable for Faded?
//
// `Faded --tap-probe` builds the smallest possible version of a tap engine:
// one global tap (every process, muted at the source) feeding an aggregate
// device whose only sub-device is the current default output, with an IO
// proc that copies tap input straight to the output. If audio keeps playing
// normally while this runs, the whole "per-app control without owning the
// default device" idea is proven in one go. Results go to the trace file.

import CoreAudio
import Foundation

final class TapProbeStats: @unchecked Sendable {
    private var lock = os_unfair_lock()
    var cycles = 0
    var peak: Float = 0
    var inDesc = ""
    var outDesc = ""

    func cycle(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let inB = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outB = UnsafeMutableAudioBufferListPointer(output)
        var p: Float = 0
        if let src = inB.first, let dst = outB.first, let s = src.mData, let d = dst.mData {
            let bytes = min(Int(src.mDataByteSize), Int(dst.mDataByteSize))
            memcpy(d, s, bytes)
            let n = bytes / MemoryLayout<Float>.size
            let f = s.assumingMemoryBound(to: Float.self)
            for i in 0..<n { p = max(p, abs(f[i])) }
        }
        os_unfair_lock_lock(&lock)
        cycles += 1
        peak = max(peak, p)
        if cycles == 1 {
            inDesc = inB.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
            outDesc = outB.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
        }
        os_unfair_lock_unlock(&lock)
    }
}

@MainActor
enum TapProbe {
    /// mode: "full" = tap + default output sub-device, muted at source;
    /// "unmuted" = same without muting; "taponly" = capture-only aggregate;
    /// "speakers" = tap + built-in speakers sub-device, unmuted.
    static func run(mode: String, seconds: Double, completion: @escaping @MainActor () -> Void) {
        guard let outID = AudioSystem.defaultOutputDevice, var dev = AudioDevice(id: outID) else {
            trace("tap probe: no default output"); completion(); return
        }
        if mode == "speakers", let spk = AudioDevice.selectableOutputs().first(where: { $0.transport == .builtIn }) {
            dev = spk
        }
        trace("tap probe[\(mode)]: begin")
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Faded tap probe"
        desc.isPrivate = true
        if mode == "full" {
            desc.muteBehavior = CATapMuteBehavior(rawValue: 2)!  // CATapMutedWhenTapped
        }
        var tap = AudioObjectID(kAudioObjectUnknown)
        var st: OSStatus = noErr
        if mode != "notap" {
            st = AudioHardwareCreateProcessTap(desc, &tap)
            trace("tap probe: create tap status=\(st) id=\(tap)")
            guard st == noErr else { completion(); return }

            var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var fmt = AudioStreamBasicDescription()
            var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &fsize, &fmt)
            trace("tap probe: tap format \(fmt.mSampleRate)Hz ch=\(fmt.mChannelsPerFrame) flags=\(fmt.mFormatFlags) bytes/frame=\(fmt.mBytesPerFrame)")
        }

        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Faded Probe",
            kAudioAggregateDeviceUIDKey: "com.andri.faded.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if mode != "taponly" {
            // The output device is the clock master; a tap alone never cycles.
            aggDesc[kAudioAggregateDeviceMainSubDeviceKey] = dev.uid
            aggDesc[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: dev.uid]]
        }
        if mode == "notap" { aggDesc[kAudioAggregateDeviceTapListKey] = nil }
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        trace("tap probe: aggregate status=\(st) id=\(agg) output=\(dev.name)")
        guard st == noErr else { AudioHardwareDestroyProcessTap(tap); completion(); return }

        // Aggregates assemble asynchronously; give the HAL a moment before IO.
        Thread.sleep(forTimeInterval: 1)
        let stats = TapProbeStats()
        var procID: AudioDeviceIOProcID?
        let ioQueue = DispatchQueue(label: "com.andri.faded.tapprobe.io", qos: .userInteractive)
        // @Sendable keeps the block nonisolated: it runs on the HAL's IO
        // thread, and a main-actor-inferred closure asserts and crashes there.
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) { @Sendable _, input, _, output, _ in
            stats.cycle(input, output)
        }
        trace("tap probe: ioproc status=\(st)")
        st = AudioDeviceStart(agg, procID)
        trace("tap probe: start status=\(st) — running \(Int(seconds))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in
                func flag(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
                    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
                    var v: UInt32 = 0; var sz = UInt32(4)
                    let r = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v)
                    return r == 0 ? "\(v)" : "err\(r)"
                }
                trace("tap probe: after 2s agg running=\(flag(agg, kAudioDevicePropertyDeviceIsRunning)) runningSomewhere=\(flag(agg, kAudioDevicePropertyDeviceIsRunningSomewhere)) alive=\(flag(agg, kAudioDevicePropertyDeviceIsAlive)) sub running=\(flag(dev.id, kAudioDevicePropertyDeviceIsRunning)) cycles=\(stats.cycles)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Task { @MainActor in
                AudioDeviceStop(agg, procID)
                if let p = procID { AudioDeviceDestroyIOProcID(agg, p) }
                AudioHardwareDestroyAggregateDevice(agg)
                if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
                trace("tap probe: done cycles=\(stats.cycles) peak=\(stats.peak) in=[\(stats.inDesc)] out=[\(stats.outDesc)]")
                completion()
            }
        }
    }
}
