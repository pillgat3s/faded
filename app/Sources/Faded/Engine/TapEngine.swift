// TapEngine.swift — per-app volume without owning the default device.
//
// The first Faded engine put a virtual device in front of everything: apps
// played into it and Faded played the mix to the real device. It worked, but
// it made Faded the owner of the system default, and a surprising amount of
// macOS keys off exactly that — AirPods auto-switching, ear detection, the
// iPhone handoff, Control Center's own device list.
//
// This engine leaves the default device alone, and leaves every app alone
// until there is a reason not to. Each process CoreAudio knows about gets a
// *process tap* (macOS 14.4+). By default the tap only listens: that is what
// feeds the level meters and the list of apps that are playing, and it changes
// nothing about the audio. An app is *taken over* — its tap muted at the
// device, its audio re-played by Faded at the right gain — only while that is
// needed: its level is below 100 %, it is muted, or the device has no volume
// control of its own and the master gain has to be applied in software. The
// re-played mix goes to the very same device through an aggregate that has
// that device as its clock master: one IO cycle of latency, no resampling, no
// drift loop, no driver.
//
// Why not simply take everything over (the first version of this engine did):
// other apps' captures see BOTH a muted original and Faded's re-play. A screen
// share or recording therefore gets a taken-over app twice, ~an IO cycle
// apart — and an app that captures "the system minus itself", as Discord's
// screen share does, gets its own audio back through Faded's copy, which is
// how people in a call end up hearing themselves. Measured with
// `--tap-probe mini` + `devcap`; an app that is merely listened to is captured
// once, exactly as without Faded.
//
// A tap is created the moment a process appears, already muted if the app's
// stored level calls for it — a tap muted only after the first buffer lets
// that buffer through at full level, which on a device without hardware
// volume is an audible blip.
//
// IO runs only while it has a job: some taken-over app is running output (its
// audio exists nowhere else — muted taps are muted whether or not anyone
// reads them), or the menu is open and wants meters. macOS reads an open
// output stream as "the Mac is playing" — it is what makes in-ear AirPods jump
// over from an iPhone — so an idle Faded holds no stream at all.
//
// Real-time rules in `ioBlock`: no allocation, no locks, no Swift runtime
// calls that could take a lock. Tables are fixed-capacity and written from
// the main thread with plain aligned 32-bit stores, which are atomic on
// every Apple CPU; a torn read is impossible and a stale one is harmless.

import CoreAudio
import Foundation

/// Values shared between the main thread and the IO thread.
final class TapEngineShared: @unchecked Sendable {
    static let capacity = 256

    let gains: UnsafeMutablePointer<Float>   // per slot, 0…1, already muted-aware
    let replay: UnsafeMutablePointer<UInt32> // per slot, 1 = taken over: mix it into the output
    let peaks: UnsafeMutablePointer<Float>   // per slot, max-hold, reset by the reader
    var slotCount = 0
    var master: Float = 1
    var masterMuted = false
    var outPeakL: Float = 0
    var outPeakR: Float = 0
    var cycles: UInt64 = 0
    var lastInputBuffers = 0
    var lastOutputDesc = 0          // channels of the first output buffer × 100 + buffer count

    init() {
        gains = .allocate(capacity: Self.capacity)
        gains.initialize(repeating: 1, count: Self.capacity)
        replay = .allocate(capacity: Self.capacity)
        replay.initialize(repeating: 0, count: Self.capacity)
        peaks = .allocate(capacity: Self.capacity)
        peaks.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        gains.deallocate()
        replay.deallocate()
        peaks.deallocate()
    }
}

struct TappedProcess: Identifiable, Hashable, Sendable {
    let id: AudioObjectID         // the CoreAudio process object
    let pid: pid_t
    let bundleID: String
    var tap: AudioObjectID
    var tapUUID: String
    var slot: Int
    /// Muted at the device and re-played by Faded. False = only listened to.
    var takenOver: Bool
}

@MainActor
final class TapEngine {
    private(set) var processes: [TappedProcess] = []
    private(set) var output: AudioDevice?
    private(set) var isRunning = false
    private(set) var lastError: String?
    let shared = TapEngineShared()

    /// Decides whether a process gets a tap at all. An untapped process plays
    /// straight to its device: no gain, no meter, and — the reason this exists
    /// — none of its audio in Faded's own output. An app that captures the
    /// system "minus itself" (Discord's screen share) would otherwise capture
    /// its own voices coming back out of Faded and send them to the people
    /// speaking.
    var shouldTap: (@MainActor (pid_t, String) -> Bool)?

    /// The stored level for a process's app (0 when muted). Asked when a tap is
    /// created, so an app that must be quieter is never heard at full level.
    var gainFor: (@MainActor (pid_t, String) -> Float)?

    /// Fired after the process set changes (new app, app quit).
    var onProcessesChanged: (@MainActor () -> Void)?
    /// Fired whenever any process starts or stops running output.
    var onOutputActivity: (@MainActor () -> Void)?

    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.andri.faded.tapengine.io", qos: .userInteractive)
    private var processListListener: ListenerToken?
    private var runningListeners: [AudioObjectID: ListenerToken] = [:]
    private var pendingRefresh = false
    private var pendingGains: [AudioObjectID: Float] = [:]   // levels of taps not yet in a slot

    // MARK: Lifecycle

    /// Tap everything and play to `device`. Idempotent for the same device.
    func start(output device: AudioDevice) throws {
        if isRunning, output?.uid == device.uid { return }
        stopIO()
        output = device
        installProcessListListener()
        refreshProcesses(notify: false)
        try buildAggregate(for: device)
        try startIO()
        trace("tap engine: running → \(device.name) with \(processes.count) taps")
    }

    /// Follow the default device somewhere else. Taps survive; only the
    /// aggregate is rebuilt around the new clock master.
    func retarget(_ device: AudioDevice) throws {
        guard output?.uid != device.uid else { return }
        stopIO()
        output = device
        try buildAggregate(for: device)
        try startIO()
        trace("tap engine: retargeted → \(device.name)")
    }

    /// Everything off: taps destroyed (which gives every taken-over app back
    /// to the device), aggregate gone, listeners dropped.
    func stop() {
        stopIO()
        destroyAggregate()
        for p in processes { AudioHardwareDestroyProcessTap(p.tap) }
        processes.removeAll()
        shared.slotCount = 0
        runningListeners.removeAll()
        processListListener = nil
        output = nil
        trace("tap engine: stopped")
    }

    /// Idle release: keep taps and aggregate, just stop pulling, so our stream
    /// on the device is gone — what lets AirPods hand back to a phone. Only
    /// safe while no taken-over app is playing; the router checks.
    func pauseIO() {
        guard isRunning else { return }
        stopIO()
        trace("tap engine: IO paused")
    }

    /// Is any tapped process running output right now? (Faded's own stream
    /// is not a tapped process, so it never counts.)
    var anyProcessRunningOutput: Bool {
        processes.contains { isRunningOutput($0.id) }
    }

    /// Is any *taken-over* process running output? Its audio exists nowhere
    /// but in our mix, so this is when IO is not optional.
    var anyTakenOverRunningOutput: Bool {
        processes.contains { $0.takenOver && isRunningOutput($0.id) }
    }

    var takenOverCount: Int { processes.filter(\.takenOver).count }

    private func isRunningOutput(_ id: AudioObjectID) -> Bool {
        ((try? AudioObject.get(id, .init(kAudioProcessPropertyIsRunningOutput), as: UInt32.self)) ?? 0) != 0
    }

    func resumeIO() throws {
        guard !isRunning, aggregate != kAudioObjectUnknown else { return }
        try startIO()
        trace("tap engine: IO resumed")
    }

    // MARK: Gains and meters

    func setGain(forProcess id: AudioObjectID, _ gain: Float) {
        guard let i = processes.firstIndex(where: { $0.id == id }), processes[i].slot >= 0,
              processes[i].slot < TapEngineShared.capacity else { return }
        shared.gains[processes[i].slot] = min(max(gain, 0), 1)
        updateTakeover(at: i)
    }

    func setMaster(_ gain: Float, muted: Bool) {
        shared.master = min(max(gain, 0), 1)
        shared.masterMuted = muted
        for i in processes.indices { updateTakeover(at: i) }
    }

    // MARK: Taking an app over, and giving it back

    /// Software master gain in play? Then everything has to come through us.
    private var masterNeedsSoftware: Bool { shared.masterMuted || shared.master != 1 }

    private func needsTakeover(gain: Float) -> Bool { gain != 1 || masterNeedsSoftware }

    private func updateTakeover(at i: Int) {
        let slot = processes[i].slot
        guard slot >= 0, slot < TapEngineShared.capacity else { return }
        let want = needsTakeover(gain: shared.gains[slot])
        guard want != processes[i].takenOver else { return }
        if want {
            // Mute first, then start re-playing: a gap of a cycle at most,
            // rather than a cycle of the app at double level.
            setTapMuted(at: i, true)
            shared.replay[slot] = 1
        } else {
            setTapMuted(at: i, false)
            shared.replay[slot] = 0
        }
        processes[i].takenOver = want
        onOutputActivity?()   // IO may have just become necessary, or idle
    }

    /// Flip a live tap between listening and muting. The tap's description is
    /// a settable property; if this system refuses, the tap is replaced.
    private func setTapMuted(at i: Int, _ muted: Bool) {
        let behavior = CATapMuteBehavior(rawValue: muted ? 1 : 0)!   // CATapMuted : CATapUnmuted
        let tap = processes[i].tap
        if let desc = try? AudioObject.getCF(tap, .init(kAudioTapPropertyDescription), as: CATapDescription.self) {
            desc.muteBehavior = behavior
            if (try? AudioObject.setCF(tap, .init(kAudioTapPropertyDescription), desc)) != nil { return }
        }
        trace("tap engine: live mute change refused for pid \(processes[i].pid) — replacing the tap")
        let desc = CATapDescription(stereoMixdownOfProcesses: [processes[i].id])
        desc.name = "Faded \(processes[i].pid)"
        desc.isPrivate = true
        desc.muteBehavior = behavior
        var fresh = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &fresh) == noErr else { return }
        AudioHardwareDestroyProcessTap(tap)
        processes[i].tap = fresh
        processes[i].tapUUID = desc.uuid.uuidString
        if aggregate != kAudioObjectUnknown { applyTapList() }
    }

    /// Per-process peak since the last call (max-hold, then cleared).
    func takePeaks() -> [AudioObjectID: Float] {
        var out: [AudioObjectID: Float] = [:]
        for p in processes where p.slot < TapEngineShared.capacity {
            out[p.id] = shared.peaks[p.slot]
            shared.peaks[p.slot] = 0
        }
        return out
    }

    func takeOutputPeak() -> (Float, Float) {
        let v = (shared.outPeakL, shared.outPeakR)
        shared.outPeakL = 0
        shared.outPeakR = 0
        return v
    }

    var stats: String {
        "aggregate=\(aggregate) running=\(isRunning) taps=\(processes.count) takenOver=\(takenOverCount) cycles=\(shared.cycles) inputs=\(shared.lastInputBuffers) outPeak=\(max(shared.outPeakL, shared.outPeakR)) outBuffers=\(shared.lastOutputDesc)"
    }

    // MARK: Processes

    private func installProcessListListener() {
        guard processListListener == nil else { return }
        processListListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            Task { @MainActor in self?.processListChanged() }
        }
    }

    /// Re-run the tap/no-tap decision for every process (the bypass list
    /// changed). Only meaningful while the engine is up: a taken-over tap is
    /// muted whether or not anyone reads it, so creating one with no engine
    /// behind it would silence that app.
    func reevaluateTaps() {
        guard output != nil else { return }
        refreshProcesses(notify: true)
    }

    private func processListChanged() {
        // Process births come in bursts (an app plus its helpers); coalesce.
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Task { @MainActor in
                self?.pendingRefresh = false
                self?.refreshProcesses(notify: true)
            }
        }
    }

    /// Reconcile taps with CoreAudio's process list.
    private func refreshProcesses(notify: Bool) {
        let ids = (try? AudioObject.getArray(AudioSystem.object, .init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var changed = false

        // Gone, or no longer ours to touch (its app was put on the bypass list)
        let live = Set(ids)
        let dropped = processes.filter { !live.contains($0.id) || !(shouldTap?($0.pid, $0.bundleID) ?? true) }
        for p in dropped {
            AudioHardwareDestroyProcessTap(p.tap)
            runningListeners[p.id] = nil
            changed = true
        }
        let droppedIDs = Set(dropped.map(\.id))
        processes.removeAll { droppedIDs.contains($0.id) }

        // New
        let known = Set(processes.map(\.id))
        for id in ids where !known.contains(id) {
            let pid = (try? AudioObject.get(id, .init(kAudioProcessPropertyPID), as: pid_t.self)) ?? 0
            guard pid > 0, pid != me else { continue }
            let bundle = AudioObject.getString(id, .init(kAudioProcessPropertyBundleID)) ?? ""
            guard shouldTap?(pid, bundle) ?? true else { continue }
            let gain = min(max(gainFor?(pid, bundle) ?? 1, 0), 1)
            let takeOver = needsTakeover(gain: gain)
            let desc = CATapDescription(stereoMixdownOfProcesses: [id])
            desc.name = "Faded \(pid)"
            desc.isPrivate = true
            desc.muteBehavior = CATapMuteBehavior(rawValue: takeOver ? 1 : 0)!   // CATapMuted : CATapUnmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            let st = AudioHardwareCreateProcessTap(desc, &tap)
            guard st == noErr else {
                trace("tap engine: tap for pid \(pid) failed \(st)")
                continue
            }
            processes.append(TappedProcess(id: id, pid: pid, bundleID: bundle, tap: tap,
                                           tapUUID: desc.uuid.uuidString, slot: -1, takenOver: takeOver))
            pendingGains[id] = gain
            runningListeners[id] = AudioObject.listen(id, .init(kAudioProcessPropertyIsRunningOutput)) { [weak self] in
                Task { @MainActor in self?.outputRunningChanged(id) }
            }
            changed = true
        }

        guard changed else { return }
        assignSlots()
        if aggregate != kAudioObjectUnknown { applyTapList() }
        if notify {
            onProcessesChanged?()
            // A process born playing (say, afplay, a game launching) shows no
            // 0→1 edge on its listener: it was already running when we looked.
            onOutputActivity?()
        }
    }

    private func outputRunningChanged(_ id: AudioObjectID) {
        onOutputActivity?()
    }

    /// Slots follow the tap-list order, which is the order the aggregate
    /// presents the tap streams in. Gains are carried over by process.
    private func assignSlots() {
        var gains = pendingGains
        pendingGains.removeAll()
        for p in processes where p.slot >= 0 && p.slot < TapEngineShared.capacity { gains[p.id] = shared.gains[p.slot] }
        processes.sort { $0.id < $1.id }
        let n = min(processes.count, TapEngineShared.capacity)
        for i in 0 ..< n {
            processes[i].slot = i
            shared.gains[i] = gains[processes[i].id] ?? 1
            shared.replay[i] = processes[i].takenOver ? 1 : 0
            shared.peaks[i] = 0
        }
        if processes.count > n {
            trace("tap engine: \(processes.count - n) processes beyond capacity are untapped")
        }
        shared.slotCount = n
    }

    // MARK: Aggregate

    private func buildAggregate(for device: AudioDevice) throws {
        destroyAggregate()
        var desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Faded Engine",
            kAudioAggregateDeviceUIDKey: "com.andri.faded.engine",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
        ]
        desc[kAudioAggregateDeviceTapListKey] = tapListEntries()
        var agg = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard st == noErr else {
            lastError = "aggregate device failed (\(st))"
            throw AudioError.osStatus(st, "AudioHardwareCreateAggregateDevice")
        }
        aggregate = agg
        // Aggregates assemble asynchronously; a start issued in the same
        // breath is silently ignored.
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func tapListEntries() -> [[String: Any]] {
        processes.prefix(TapEngineShared.capacity).map {
            [kAudioSubTapDriftCompensationKey: false, kAudioSubTapUIDKey: $0.tapUUID]
        }
    }

    /// Push the current tap set to the live aggregate; rebuild if refused.
    private func applyTapList() {
        let uuids = processes.prefix(TapEngineShared.capacity).map(\.tapUUID) as NSArray
        do {
            try AudioObject.setCF(aggregate, .init(kAudioAggregateDevicePropertyTapList), uuids)
            // The stream list just changed length; the usage map must follow.
            if let pid = procID {
                _ = Self.switchOffDeviceInputs(aggregate: aggregate, procID: pid,
                                               tapCount: min(processes.count, TapEngineShared.capacity))
            }
        } catch {
            trace("tap engine: live tap list refused (\(error)) — rebuilding")
            if let dev = output {
                let wasRunning = isRunning
                stopIO()
                try? buildAggregate(for: dev)
                if wasRunning { try? startIO() }
            }
        }
    }

    private func destroyAggregate() {
        guard aggregate != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(aggregate)
        aggregate = kAudioObjectUnknown
    }

    // MARK: IO

    private func startIO() throws {
        guard aggregate != kAudioObjectUnknown, !isRunning else { return }
        let shared = self.shared
        var pid: AudioDeviceIOProcID?
        var st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregate, ioQueue) { @Sendable _, input, _, output, _ in
            TapEngine.ioCycle(shared, input, output)
        }
        guard st == noErr, let pid else { throw AudioError.osStatus(st, "AudioDeviceCreateIOProcIDWithBlock") }
        let off = Self.switchOffDeviceInputs(aggregate: aggregate, procID: pid,
                                             tapCount: min(processes.count, TapEngineShared.capacity))
        if off.deviceInputs > 0 {
            trace("tap engine: \(off.deviceInputs) input stream(s) of \(output?.name ?? "the device") kept closed (status \(off.status))")
        }
        st = AudioDeviceStart(aggregate, pid)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, pid)
            throw AudioError.osStatus(st, "AudioDeviceStart")
        }
        procID = pid
        isRunning = true
    }

    /// An output device can bring inputs of its own into the aggregate — a
    /// USB headset base station's capture stream, for one. Faded has no use
    /// for them, and an IOProc that leaves them enabled opens that input for
    /// as long as it runs: a live capture stream and the orange indicator,
    /// for nothing. This tells the HAL our IOProc wants only the tap streams,
    /// which come last in the aggregate's input list.
    static func switchOffDeviceInputs(aggregate: AudioObjectID, procID: AudioDeviceIOProcID,
                                      tapCount: Int) -> (deviceInputs: Int, status: OSStatus) {
        let streams = (try? AudioObject.getArray(aggregate,
            AudioObjectPropertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
            of: AudioObjectID.self))?.count ?? 0
        let deviceInputs = streams - tapCount
        guard deviceInputs > 0, tapCount >= 0 else { return (0, noErr) }

        // AudioHardwareIOProcStreamUsage ends in a variable-length array.
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let size = flagsOffset + streams * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        memset(raw, 0, size)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streams)
        let flags = raw.advanced(by: flagsOffset).assumingMemoryBound(to: UInt32.self)
        for i in 0 ..< streams { flags[i] = i < deviceInputs ? 0 : 1 }
        var addr = AudioObjectPropertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let st = AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(size), raw)
        return (deviceInputs, st)
    }

    private func stopIO() {
        guard let pid = procID else { isRunning = false; return }
        if aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, pid)
            AudioDeviceDestroyIOProcID(aggregate, pid)
        }
        procID = nil
        isRunning = false
    }

    /// The real-time mixer. Static and nonisolated on purpose.
    nonisolated private static func ioCycle(_ s: TapEngineShared,
                                            _ input: UnsafePointer<AudioBufferList>,
                                            _ output: UnsafeMutablePointer<AudioBufferList>) {
        let inB = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outB = UnsafeMutableAudioBufferListPointer(output)
        s.cycles &+= 1
        s.lastInputBuffers = inB.count
        s.lastOutputDesc = Int(outB.first?.mNumberChannels ?? 0) * 100 + outB.count

        // Output geometry: interleaved stereo in one buffer, or one buffer per
        // channel. Zero it all, then find where left and right live.
        for b in outB { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        guard let first = outB.first, let firstData = first.mData else { return }
        let outL: UnsafeMutablePointer<Float>
        let outR: UnsafeMutablePointer<Float>
        let outStride: Int
        let frames: Int
        if first.mNumberChannels == 1, outB.count >= 2, let second = outB[1].mData {
            outL = firstData.assumingMemoryBound(to: Float.self)
            outR = second.assumingMemoryBound(to: Float.self)
            outStride = 1
            frames = Int(first.mDataByteSize) / 4
        } else {
            let ch = Int(max(first.mNumberChannels, 1))
            outL = firstData.assumingMemoryBound(to: Float.self)
            outR = ch > 1 ? outL + 1 : outL
            outStride = ch
            frames = Int(first.mDataByteSize) / (4 * ch)
        }

        let mono = outStride == 1 && outL == outR
        let master = s.masterMuted ? 0 : s.master
        // Tap streams come last in the aggregate's input list. A sub-device
        // with inputs of its own (a USB headset's microphone) puts those
        // first, and they must never be mistaken for an app.
        let slots = min(s.slotCount, inB.count)
        let base = inB.count - slots
        for slot in 0 ..< slots {
            let b = inB[base + slot]
            guard let src = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(max(b.mNumberChannels, 1))
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            // Listened-to apps are metered and left alone; only a taken-over
            // app's audio is ours to play.
            let g = s.replay[slot] != 0 ? s.gains[slot] * master : 0
            var peak: Float = 0
            var i = 0
            while i < n {
                let l = src[i * ch]
                let r = ch > 1 ? src[i * ch + 1] : l
                let al = l < 0 ? -l : l
                let ar = r < 0 ? -r : r
                if al > peak { peak = al }
                if ar > peak { peak = ar }
                if g != 0 {
                    if mono {
                        // A mono device (AirPods in call mode) gets the
                        // average, as macOS's own downmix does — not L+R,
                        // which is 6 dB hot and clips.
                        outL[i] += 0.5 * (l + r) * g
                    } else {
                        outL[i * outStride] += l * g
                        outR[i * outStride] += r * g
                    }
                }
                i += 1
            }
            if peak > s.peaks[slot] { s.peaks[slot] = peak }
        }

        var pl: Float = 0
        var pr: Float = 0
        var i = 0
        while i < frames {
            let l = outL[i * outStride]
            let r = outR[i * outStride]
            let al = l < 0 ? -l : l
            let ar = r < 0 ? -r : r
            if al > pl { pl = al }
            if ar > pr { pr = ar }
            i += 1
        }
        if pl > s.outPeakL { s.outPeakL = pl }
        if pr > s.outPeakR { s.outPeakR = pr }
    }
}
