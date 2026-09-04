// TapEngine.swift — per-app volume without owning the default device.
//
// The first Faded engine put a virtual device in front of everything: apps
// played into it and Faded played the mix to the real device. It worked, but
// it made Faded the owner of the system default, and a surprising amount of
// macOS keys off exactly that — AirPods auto-switching, ear detection, the
// iPhone handoff, Control Center's own device list.
//
// This engine leaves the default device alone. Every process that CoreAudio
// knows about gets a *process tap* (macOS 14.4+): the process's audio is
// muted at the device and handed to us instead; we apply its gain, sum
// everything, apply the master gain where the device has no volume control
// of its own, and play the result to the very same device through an
// aggregate that has that device as its clock master. One IO cycle of
// latency, no resampling, no drift loop, no shared memory, no driver.
//
// Tapping every process — not just the ones playing — matters: a tap that is
// created after the first buffer lets that buffer through at full level, and
// on a device without hardware volume that is an audible blip.
//
// The engine's own output stream runs only while some tapped process is
// running output. macOS reads an open output stream as "the Mac is playing"
// — it is what makes in-ear AirPods jump over from an iPhone — so Faded must
// look exactly like the apps it carries: streaming when they stream, silent
// and stream-less when they are not. Taps are muted unconditionally (not
// only while being read) so the moment between an app starting and our
// stream coming up is a short silence, never a burst at full level.
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
    let peaks: UnsafeMutablePointer<Float>   // per slot, max-hold, reset by the reader
    var slotCount = 0
    var master: Float = 1
    var masterMuted = false
    var outPeakL: Float = 0
    var outPeakR: Float = 0
    var cycles: UInt64 = 0
    var lastInputBuffers = 0

    init() {
        gains = .allocate(capacity: Self.capacity)
        gains.initialize(repeating: 1, count: Self.capacity)
        peaks = .allocate(capacity: Self.capacity)
        peaks.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        gains.deallocate()
        peaks.deallocate()
    }
}

struct TappedProcess: Identifiable, Hashable, Sendable {
    let id: AudioObjectID         // the CoreAudio process object
    let pid: pid_t
    let bundleID: String
    let tap: AudioObjectID
    let tapUUID: String
    var slot: Int
}

@MainActor
final class TapEngine {
    private(set) var processes: [TappedProcess] = []
    private(set) var output: AudioDevice?
    private(set) var isRunning = false
    private(set) var lastError: String?
    let shared = TapEngineShared()

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

    /// Everything off: taps destroyed (which un-mutes every process at the
    /// device), aggregate gone, listeners dropped.
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

    /// Idle release: keep taps and aggregate, just stop pulling. With no IO
    /// the taps are inactive, so processes play straight to the device again
    /// and our stream on it is gone — what lets AirPods hand back to a phone.
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
        guard let p = processes.first(where: { $0.id == id }), p.slot < TapEngineShared.capacity else { return }
        shared.gains[p.slot] = min(max(gain, 0), 1)
    }

    func setMaster(_ gain: Float, muted: Bool) {
        shared.master = min(max(gain, 0), 1)
        shared.masterMuted = muted
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
        "aggregate=\(aggregate) running=\(isRunning) taps=\(processes.count) cycles=\(shared.cycles) inputs=\(shared.lastInputBuffers)"
    }

    // MARK: Processes

    private func installProcessListListener() {
        guard processListListener == nil else { return }
        processListListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            Task { @MainActor in self?.processListChanged() }
        }
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

        // Gone
        let live = Set(ids)
        for p in processes where !live.contains(p.id) {
            AudioHardwareDestroyProcessTap(p.tap)
            runningListeners[p.id] = nil
            changed = true
        }
        processes.removeAll { !live.contains($0.id) }

        // New
        let known = Set(processes.map(\.id))
        for id in ids where !known.contains(id) {
            let pid = (try? AudioObject.get(id, .init(kAudioProcessPropertyPID), as: pid_t.self)) ?? 0
            guard pid > 0, pid != me else { continue }
            let bundle = AudioObject.getString(id, .init(kAudioProcessPropertyBundleID)) ?? ""
            let desc = CATapDescription(stereoMixdownOfProcesses: [id])
            desc.name = "Faded \(pid)"
            desc.isPrivate = true
            desc.muteBehavior = CATapMuteBehavior(rawValue: 1)!  // CATapMuted — always
            var tap = AudioObjectID(kAudioObjectUnknown)
            let st = AudioHardwareCreateProcessTap(desc, &tap)
            guard st == noErr else {
                trace("tap engine: tap for pid \(pid) failed \(st)")
                continue
            }
            processes.append(TappedProcess(id: id, pid: pid, bundleID: bundle, tap: tap,
                                           tapUUID: desc.uuid.uuidString, slot: -1))
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
        var gains: [AudioObjectID: Float] = [:]
        for p in processes where p.slot >= 0 && p.slot < TapEngineShared.capacity { gains[p.id] = shared.gains[p.slot] }
        processes.sort { $0.id < $1.id }
        let n = min(processes.count, TapEngineShared.capacity)
        for i in 0 ..< n {
            processes[i].slot = i
            shared.gains[i] = gains[processes[i].id] ?? 1
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
        st = AudioDeviceStart(aggregate, pid)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, pid)
            throw AudioError.osStatus(st, "AudioDeviceStart")
        }
        procID = pid
        isRunning = true
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

        let master = s.masterMuted ? 0 : s.master
        let slots = min(s.slotCount, inB.count)
        for slot in 0 ..< slots {
            let b = inB[slot]
            guard let src = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(max(b.mNumberChannels, 1))
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            let g = s.gains[slot] * master
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
                    outL[i * outStride] += l * g
                    outR[i * outStride] += r * g
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
