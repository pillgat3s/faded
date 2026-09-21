// TapProbe.swift — headless experiments on the process-tap machinery.
//
// `Faded --tap-probe <mode> [seconds] [pid]`, results to the trace file. Run it
// through LaunchServices (`open -n Faded.app --args …`) so the audio-capture
// permission is attributed to Faded rather than to the shell.
//
//   full       global tap, muted at the source, passed through to the default
//              device: the whole engine idea in twenty lines
//   unmuted    the same without muting (everything is heard twice)
//   notap      an aggregate of the output device alone — isolates the
//              aggregate plumbing from taps and permissions
//   excluding  what another app's capture sees: a listen-only global tap that
//              leaves out one process (pid) and measures a 1 kHz test tone.
//              This is Discord's screen share in miniature — it captures the
//              system minus itself — and answers whether audio played by the
//              excluded process still reaches the capture by way of Faded.
//   only       a tap of just one process (pid): is that process's output
//              capturable at all?
//   global     listen-only capture of everything
//   devcap     listen-only capture of ONE DEVICE'S STREAM (the default output,
//              stream 0) minus one process (pid; 0 = exclude nothing). This is
//              how Chromium's loopback capture — and with it Electron apps
//              that share system audio — taps by default: it records what
//              reaches the device, not what each process produced.
//   mini       a one-app Faded: mute-tap only <pid> and re-play it to the
//              default device, touching nothing else. Run it next to `devcap`
//              to see whether a device-level capture hears the re-played copy.
//   usage      like global, on a named device (4th argument), with the
//              device's own input streams switched off the way the engine
//              does it. `global` on the same device is the baseline.
//   inputs     for every output device: how many input buffers an aggregate
//              of [device + one tap] presents. More than one means the device
//              brings inputs of its own, which the mixer must skip.

import CoreAudio
import Foundation

final class TapProbeStats: @unchecked Sendable {
    var cycles = 0
    var peak: Float = 0
    var sumSquares = 0.0
    var samples = 0.0
    var sinSum = 0.0
    var cosSum = 0.0
    var phase = 0.0
    var phaseStep = 0.0          // 2π·f/rate, set before IO starts
    var passThrough = true
    var deviceInputBuffersWithData = 0   // sub-device inputs that were actually delivered
    var deviceInputPeak: Float = 0
    var inDesc = ""
    var outDesc = ""

    func cycle(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let inB = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outB = UnsafeMutableAudioBufferListPointer(output)
        for b in outB { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        // The tap stream is the last input buffer; a sub-device's own inputs come first.
        if let src = inB.last, let s = src.mData {
            let ch = Int(max(src.mNumberChannels, 1))
            let n = Int(src.mDataByteSize) / (4 * ch)
            let f = s.assumingMemoryBound(to: Float.self)
            if passThrough, let dst = outB.first, let d = dst.mData {
                let och = Int(max(dst.mNumberChannels, 1))
                let o = d.assumingMemoryBound(to: Float.self)
                let frames = min(n, Int(dst.mDataByteSize) / (4 * och))
                var k = 0
                while k < frames {
                    let l = f[k * ch], r = ch > 1 ? f[k * ch + 1] : l
                    if och == 1 { o[k] = 0.5 * (l + r) } else { o[k * och] = l; o[k * och + 1] = r }
                    k += 1
                }
            }
            var i = 0
            while i < n {
                let x = Double(f[i * ch])
                let a = Float(abs(x))
                if a > peak { peak = a }
                sumSquares += x * x
                sinSum += x * sin(phase)
                cosSum += x * cos(phase)
                phase += phaseStep
                i += 1
            }
            samples += Double(n)
        }
        // Everything before the last buffer belongs to the sub-device itself.
        if inB.count > 1 {
            var live = 0
            for b in inB.dropLast() {
                guard let d = b.mData else { continue }
                live += 1
                let f = d.assumingMemoryBound(to: Float.self)
                let n = Int(b.mDataByteSize) / 4
                var i = 0
                while i < n { let a = abs(f[i]); if a > deviceInputPeak { deviceInputPeak = a }; i += 1 }
            }
            if live > deviceInputBuffersWithData { deviceInputBuffersWithData = live }
        }
        if cycles == 0 {
            inDesc = inB.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
            outDesc = outB.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
        }
        cycles += 1
    }

    var rms: Double { samples > 0 ? (sumSquares / samples).squareRoot() : 0 }
    /// Amplitude of the 1 kHz test tone in the capture; ~0 when absent.
    var tone: Double { samples > 0 ? 2 * (sinSum * sinSum + cosSum * cosSum).squareRoot() / samples : 0 }
}

@MainActor
enum TapProbe {
    static var toneHz: Double { Double(ProcessInfo.processInfo.environment["FADED_PROBE_TONE"] ?? "") ?? 1000.0 }

    static func run(mode: String, seconds: Double, pid: pid_t = 0, deviceName: String? = nil,
                    completion: @escaping @MainActor () -> Void) {
        if mode == "inputs" { surveyInputs(); completion(); return }

        var chosen: AudioDevice?
        if let deviceName, !deviceName.isEmpty {
            chosen = AudioDevice.selectableOutputs().first { $0.name.localizedCaseInsensitiveContains(deviceName) }
        } else {
            chosen = AudioSystem.defaultOutputDevice.flatMap(AudioDevice.init(id:))
        }
        guard let dev = chosen else {
            trace("tap probe[\(mode)]: done — no such output device"); completion(); return
        }
        trace("tap probe[\(mode)]: begin, output=\(dev.name)")

        var excluded: [AudioObjectID] = []
        var only: [AudioObjectID] = []
        if mode == "only" {
            guard let obj = processObject(for: pid) else {
                trace("tap probe[only]: done — pid \(pid) has no CoreAudio process object"); completion(); return
            }
            only = [obj]
            trace("tap probe: tapping only pid \(pid) → process object \(obj)")
        }
        if mode == "excluding" {
            guard let obj = processObject(for: pid) else {
                trace("tap probe[excluding]: done — pid \(pid) has no CoreAudio process object"); completion(); return
            }
            excluded = [obj]
            let app = ProcessResolver.resolve(pid: pid, bundleID: AudioObject.getString(obj, .init(kAudioProcessPropertyBundleID)) ?? "")
            trace("tap probe: excluding pid \(pid) → process object \(obj), resolves to app id \(app.id) (\(app.name))")
        }

        var desc = only.isEmpty ? CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
                                : CATapDescription(stereoMixdownOfProcesses: only)
        if mode == "devcap" {
            var ex: [AudioObjectID] = []
            if pid > 0, let obj = processObject(for: pid) { ex = [obj] }
            desc = CATapDescription(excludingProcesses: ex, deviceUID: dev.uid, stream: 0)
            trace("tap probe: device-level capture of \(dev.name) stream 0, excluding \(ex)")
        }
        if mode == "mini" {
            guard let obj = processObject(for: pid) else {
                trace("tap probe[mini]: done — pid \(pid) has no CoreAudio process object"); completion(); return
            }
            desc = CATapDescription(stereoMixdownOfProcesses: [obj])
            trace("tap probe: mini engine — mute-tapping only pid \(pid) (object \(obj)) and re-playing it")
        }
        desc.name = "Faded tap probe"
        desc.isPrivate = true
        if mode == "full" || mode == "mini" { desc.muteBehavior = CATapMuteBehavior(rawValue: 1)! }   // CATapMuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var st: OSStatus = noErr
        var rate = 48000.0
        if mode != "notap" {
            st = AudioHardwareCreateProcessTap(desc, &tap)
            guard st == noErr else { trace("tap probe: create tap failed \(st)"); completion(); return }
            if let fmt = try? AudioObject.get(tap, .init(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self) {
                rate = fmt.mSampleRate
            }
        }

        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Faded Probe",
            kAudioAggregateDeviceUIDKey: "com.andri.faded.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: dev.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: dev.uid]],
        ]
        if mode != "notap" {
            // FADED_PROBE_DRIFT=0 builds the aggregate the way the engine does.
            let drift = ProcessInfo.processInfo.environment["FADED_PROBE_DRIFT"] != "0"
            aggDesc[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapDriftCompensationKey: drift,
                                                          kAudioSubTapUIDKey: desc.uuid.uuidString]]
            trace("tap probe: sub-tap drift compensation \(drift)")
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard st == noErr else {
            trace("tap probe: aggregate failed \(st)")
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
            completion(); return
        }
        Thread.sleep(forTimeInterval: 0.5)   // aggregates assemble asynchronously
        // The aggregate runs at its clock device's rate (AirPods in call mode
        // are 16 or 24 kHz), and that is the rate the tap stream arrives at.
        if let r = try? AudioObject.get(agg, .init(kAudioDevicePropertyNominalSampleRate), as: Float64.self), r > 0 { rate = r }
        trace("tap probe: aggregate rate \(rate) Hz")

        let stats = TapProbeStats()
        stats.passThrough = (mode == "full" || mode == "unmuted" || mode == "mini")   // the rest just listen
        stats.phaseStep = 2 * Double.pi * toneHz / rate
        var procID: AudioDeviceIOProcID?
        let ioQueue = DispatchQueue(label: "com.andri.faded.tapprobe.io", qos: .userInteractive)
        // @Sendable keeps the block nonisolated: it runs on the HAL's IO
        // thread, and a main-actor-inferred closure asserts and crashes there.
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) { @Sendable _, input, _, output, _ in
            stats.cycle(input, output)
        }
        if mode == "usage", let p = procID {
            let off = TapEngine.switchOffDeviceInputs(aggregate: agg, procID: p, tapCount: 1)
            trace("tap probe: switched off \(off.deviceInputs) device input stream(s), status \(off.status)")
        }
        st = AudioDeviceStart(agg, procID)
        trace("tap probe: start status=\(st), running \(Int(seconds))s")

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Task { @MainActor in
                AudioDeviceStop(agg, procID)
                if let p = procID { AudioDeviceDestroyIOProcID(agg, p) }
                AudioHardwareDestroyAggregateDevice(agg)
                if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
                trace(String(format: "tap probe[%@]: done cycles=%d peak=%.5f rms=%.5f tone=%.5f in=[%@] out=[%@] deviceInputsDelivered=%d deviceInputPeak=%.5f",
                             mode, stats.cycles, stats.peak, stats.rms, stats.tone, stats.inDesc, stats.outDesc,
                             stats.deviceInputBuffersWithData, stats.deviceInputPeak))
                completion()
            }
        }
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// No IO: just build [device + one tap] for every output device and count
    /// the input streams the aggregate ends up with.
    private static func surveyInputs() {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Faded tap probe"
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { trace("tap probe: create tap failed"); return }
        defer { AudioHardwareDestroyProcessTap(tap) }
        for dev in AudioDevice.selectableOutputs() {
            let aggDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Faded Probe",
                kAudioAggregateDeviceUIDKey: "com.andri.faded.probe.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: dev.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: dev.uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            var agg = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else {
                trace("tap probe[inputs]: \(dev.name): aggregate failed"); continue
            }
            Thread.sleep(forTimeInterval: 0.4)
            let ins = (try? AudioObject.getArray(agg, AudioObjectPropertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), of: AudioObjectID.self))?.count ?? -1
            let outs = (try? AudioObject.getArray(agg, AudioObjectPropertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), of: AudioObjectID.self))?.count ?? -1
            trace("tap probe[inputs]: \(dev.name) hasInput=\(dev.hasInput) → aggregate input streams=\(ins) (1 = just the tap), output streams=\(outs)")
            AudioHardwareDestroyAggregateDevice(agg)
        }
    }
}
