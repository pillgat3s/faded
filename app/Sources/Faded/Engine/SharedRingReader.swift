// SharedRingReader.swift — the consumer end of the driver's shared-memory ring.
//
// This is what replaced reading audio back through a hidden input device. The
// mapping is PROT_READ only and the read cursor lives here, in the app's own
// memory, so nothing in the shared region is ever written by this process — and
// because no audio *input* stream is involved anywhere, macOS never lights the
// microphone indicator.
//
// DRIFT
//
// The producer is clocked by coreaudiod; this consumer is clocked by the real
// output device's own crystal. Those two clocks disagree — typically by around
// 100 ppm — so reading exactly one frame per frame written means the buffer
// between them creeps steadily toward empty or full, and eventually glitches.
// A bigger buffer only changes how long you wait for the click.
//
// So the read rate is not fixed. A slow control loop watches the buffer's fill
// level and nudges the rate by a fraction of a percent to hold it at a target,
// which cancels the drift rather than postponing it. The correction is far too
// small and too slow to hear (it is bounded at 0.3%, and real drift needs about
// a thirtieth of that).
//
// The target itself adapts. Both ends move in whole device cycles, so the
// measured fill is a stairstep: constant while the two clocks' phases happen to
// align, then a whole cycle at once when they wrap — and coreaudiod chooses
// the producer's cycle size (anywhere from 128 to 4096 frames, by device and
// clients). The target therefore tracks the largest burst actually observed,
// plus one read and slack, so the stairstep's low edge can never reach the
// underrun line. This is why the fill target is not a constant: with a fixed
// target of two bursts, a device running larger cycles would click on every
// phase wrap, and that is unpredictable-feeling in exactly the way an
// intermittent fault is.
//
// Everything below `open`/`close` runs on the output render thread: no locks,
// no allocation, no syscalls.

import Darwin
import Foundation
import os

final class SharedRingReader: @unchecked Sendable {
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "SharedRing")

    private var ring: UnsafePointer<FadedSharedRing>?
    private var mapping: UnsafeMutableRawPointer?

    /// Fractional read position, private to this process.
    private var posInt: UInt64 = 0
    private var posFrac: Double = 0
    private var primed = false
    private var generation: UInt32 = 0

    /// Smoothed buffer fill, in frames. The control loop's input.
    private var averageFill: Double = 0
    /// Last rate correction applied, exposed for diagnostics.
    private(set) var driftPPM: Double = 0

    /// C macros import as Int32; the buffer maths wants Int.
    private let channels = Int(kFadedRingChannels)

    /// Adaptive fill target (frames). See the header comment for why this is
    /// not a constant. Mirrored line for line in driver/test/harness.cpp —
    /// change both together.
    private var targetFill = Double(kFadedRingBaseTargetFrames)
    /// Largest producer burst observed, with a slow decay so a one-off spike
    /// does not pin the latency up forever.
    private var maxBurst: Double = 0
    private var lastAvailable: Double = -1
    private var lastConsumed: Double = 0

    /// Hard ceiling on the correction. Real drift is ~100 ppm; 3000 ppm is
    /// thirty times the headroom needed and still well under the threshold
    /// where a steady tone would audibly change pitch.
    private let maxCorrection = 0.003
    /// Proportional gain, deliberately weak: the loop should ease the fill back
    /// over seconds, not chase every buffer and modulate the pitch doing it.
    private let loopGain = 0.02
    /// One-pole smoothing on the fill measurement (~1 s at typical buffer sizes).
    private let fillSmoothing = 0.01

    private(set) var underruns: UInt64 = 0
    private(set) var resyncs: UInt64 = 0

    /// Output meter, measured on exactly the frames that go to the speakers.
    /// The driver no longer assembles a mix anywhere — clients sum straight
    /// into the ring — so this end is the only place the finished signal
    /// exists to be measured.
    private let meterLock = OSAllocatedUnfairLock(initialState: (l: Float(0), r: Float(0)))
    var outputPeak: (Float, Float) { meterLock.withLock { ($0.l, $0.r) } }

    var isOpen: Bool { ring != nil }

    deinit { close() }

    // MARK: Lifecycle

    @discardableResult
    func open() -> Bool {
        if ring != nil { return true }

        let fd = FadedSharedRingOpenReadOnly()
        if fd < 0 {
            Self.log.info("shared ring unavailable: errno \(errno) — is the driver installed?")
            return false
        }
        defer { Darwin.close(fd) }

        let size = MemoryLayout<FadedSharedRing>.size
        guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else {
            Self.log.error("mmap of shared ring failed: errno \(errno)")
            return false
        }

        let candidate = map.assumingMemoryBound(to: FadedSharedRing.self)
        guard candidate.pointee.magic == kFadedShmMagic,
              candidate.pointee.version == kFadedShmVersion,
              candidate.pointee.channels == UInt32(kFadedRingChannels),
              candidate.pointee.capacityFrames == UInt32(kFadedRingFrames)
        else {
            Self.log.error("shared ring header mismatch (magic \(candidate.pointee.magic))")
            munmap(map, size)
            return false
        }

        mapping = map
        ring = UnsafePointer(candidate)
        resync()
        Self.log.info("shared ring mapped")
        return true
    }

    func close() {
        if let mapping { munmap(mapping, MemoryLayout<FadedSharedRing>.size) }
        mapping = nil
        ring = nil
        primed = false
    }

    var sampleRate: Double? {
        guard let ring else { return nil }
        let rate = FadedSharedRingSampleRate(ring)
        return rate > 0 ? Double(rate) : nil
    }

    var producerRunning: Bool {
        guard let ring else { return false }
        return FadedSharedRingOutputRunning(ring) != 0
    }

    var overruns: UInt64 {
        guard let ring else { return 0 }
        return FadedSharedRingOverruns(ring)
    }

    /// How full the buffer is sitting, in frames — should hover near the target.
    var fill: Double { averageFill }
    /// Where the adaptive control loop is currently holding the fill.
    var target: Double { targetFill }

    // MARK: Reading (render thread)

    func read(into dst: UnsafeMutablePointer<Float>, frames: UInt32) {
        guard let ring else {
            silence(dst, frames)
            return
        }

        // The driver bumps `generation` when a new stream starts; anything left
        // in the buffer from the previous one is stale.
        let gen = FadedSharedRingGeneration(ring)
        if gen != generation {
            generation = gen
            resync()
        }

        let write = FadedSharedRingWriteIndex(ring)
        let availableFrames = write &- posInt
        var available = Double(availableFrames) - posFrac

        // Producer lapped us, or playback was paused long enough that the
        // buffer is stale. Jump forward rather than playing old audio or
        // sitting permanently late.
        if availableFrames > UInt64(kFadedRingMaxFrames) {
            posInt = write &- UInt64(targetFill)
            posFrac = 0
            available = targetFill
            averageFill = targetFill
            lastAvailable = -1
            resyncs &+= 1
        }

        // Track the producer's burst size: between two reads, the fill changes
        // by (produced - consumed), so produced = delta + what we consumed.
        // This runs in the unprimed state too — sitting there watching the
        // write index grow is exactly how the right target is known *before*
        // the first frame ever plays; learning it only after starting means
        // one guaranteed click on devices coreaudiod runs at large cycles.
        if lastAvailable >= 0 {
            let burst = available - lastAvailable + lastConsumed
            if burst > maxBurst {
                maxBurst = burst
            } else {
                maxBurst *= 0.9999   // halves in about a minute of callbacks
            }
            let needed = maxBurst + Double(frames) + 256
            targetFill = min(max(Double(kFadedRingBaseTargetFrames), needed),
                             Double(kFadedRingMaxTargetFrames))
        }

        if !primed {
            guard available >= targetFill else {
                silence(dst, frames)
                // Not consuming, but keep observing: burst learning stays live.
                lastAvailable = available
                lastConsumed = 0
                return
            }
            primed = true
            averageFill = available
        }

        // Control loop: ease the fill back toward target with a correction far
        // too small and slow to hear.
        averageFill += fillSmoothing * (available - averageFill)
        let error = (averageFill - targetFill) / targetFill
        let step = min(max(1.0 + error * loopGain, 1.0 - maxCorrection), 1.0 + maxCorrection)
        driftPPM = (step - 1.0) * 1_000_000

        // Interpolating needs the frame *after* the last one we touch.
        let required = Double(frames) * step + 2
        guard available >= required else {
            // Genuinely out of data — the producer stalled rather than drifted.
            silence(dst, frames)
            meterLock.withLock { $0 = (0, 0) }
            underruns &+= 1
            primed = false
            // Keep the burst estimate across the stall; only the prime state
            // resets. Relearning from scratch after every hiccup is how a
            // fault stays intermittent forever.
            lastAvailable = available
            lastConsumed = 0
            return
        }

        FadedSharedRingResample(ring, &posInt, &posFrac, step, dst, frames)
        lastConsumed = Double(frames) * step
        lastAvailable = available - lastConsumed
        measure(dst, frames)
    }

    /// Decaying peak-hold over the frames just produced.
    private func measure(_ src: UnsafePointer<Float>, _ frames: UInt32) {
        var l: Float = 0
        var r: Float = 0
        for i in 0 ..< Int(frames) {
            l = max(l, abs(src[i * 2]))
            r = max(r, abs(src[i * 2 + 1]))
        }
        let peakL = l, peakR = r   // let-bound: the lock's closure is Sendable
        meterLock.withLock { state in
            state.l = max(peakL, state.l * 0.85)
            state.r = max(peakR, state.r * 0.85)
        }
    }

    private func silence(_ dst: UnsafeMutablePointer<Float>, _ frames: UInt32) {
        dst.update(repeating: 0, count: Int(frames) * channels)
    }

    private func resync() {
        guard let ring else { return }
        posInt = FadedSharedRingWriteIndex(ring)
        posFrac = 0
        averageFill = 0
        primed = false
        lastAvailable = -1
    }
}
