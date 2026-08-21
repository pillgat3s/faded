// RingBuffer.swift — SPSC ring of interleaved Float32 frames for the
// play-through path (input AUHAL thread → output AUHAL thread).
//
// Same policy as the driver's FIFO: prime a small cushion after underrun,
// trim if we fall too far behind. No locks, no allocation on the audio threads.

import Foundation
import Synchronization

final class RingBuffer: @unchecked Sendable {
    let channels: Int
    let capacityFrames: Int
    private let mask: Int
    private let primeFrames: Int
    private let maxFrames: Int

    private let buffer: UnsafeMutablePointer<Float>
    private let writePos = Atomic<UInt64>(0)
    private let readPos = Atomic<UInt64>(0)
    private var primed = false // reader thread only

    let underruns = Atomic<UInt64>(0)
    let overruns = Atomic<UInt64>(0)
    let trims = Atomic<UInt64>(0)

    init(channels: Int = 2, capacityFrames: Int = 1 << 15, primeFrames: Int = 512, maxFrames: Int = 4096) {
        precondition(capacityFrames > 0 && (capacityFrames & (capacityFrames - 1)) == 0, "capacity must be a power of two")
        self.channels = channels
        self.capacityFrames = capacityFrames
        mask = capacityFrames - 1
        self.primeFrames = primeFrames
        self.maxFrames = maxFrames
        buffer = .allocate(capacity: capacityFrames * channels)
        buffer.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit { buffer.deallocate() }

    var availableFrames: Int {
        Int(writePos.load(ordering: .acquiring) &- readPos.load(ordering: .acquiring))
    }

    func reset() {
        readPos.store(writePos.load(ordering: .acquiring), ordering: .releasing)
        primed = false
    }

    // MARK: Producer

    func write(_ src: UnsafePointer<Float>, frames: Int) {
        let w = writePos.load(ordering: .relaxed)
        let r = readPos.load(ordering: .acquiring)
        let used = Int(w &- r)
        var n = frames
        if n > capacityFrames - used {
            overruns.wrappingAdd(1, ordering: .relaxed)
            n = capacityFrames - used
        }
        guard n > 0 else { return }
        copyIn(at: w, from: src, frames: n)
        writePos.store(w &+ UInt64(n), ordering: .releasing)
    }

    // MARK: Consumer

    /// Fills `dst` with `frames` frames; zero-fills what it can't supply.
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) {
        let w = writePos.load(ordering: .acquiring)
        var r = readPos.load(ordering: .relaxed)
        var avail = Int(w &- r)

        if avail > maxFrames {
            r = w &- UInt64(primeFrames)
            avail = primeFrames
            trims.wrappingAdd(1, ordering: .relaxed)
        }

        if !primed {
            if avail >= primeFrames {
                primed = true
            } else {
                dst.update(repeating: 0, count: frames * channels)
                readPos.store(r, ordering: .releasing)
                return
            }
        }

        if avail < frames {
            copyOut(at: r, to: dst, frames: avail)
            (dst + avail * channels).update(repeating: 0, count: (frames - avail) * channels)
            r &+= UInt64(avail)
            underruns.wrappingAdd(1, ordering: .relaxed)
            primed = false
        } else {
            copyOut(at: r, to: dst, frames: frames)
            r &+= UInt64(frames)
        }
        readPos.store(r, ordering: .releasing)
    }

    // MARK: Internals

    private func copyIn(at pos: UInt64, from src: UnsafePointer<Float>, frames: Int) {
        let start = Int(pos) & mask
        let first = min(frames, capacityFrames - start)
        (buffer + start * channels).update(from: src, count: first * channels)
        if frames > first {
            buffer.update(from: src + first * channels, count: (frames - first) * channels)
        }
    }

    private func copyOut(at pos: UInt64, to dst: UnsafeMutablePointer<Float>, frames: Int) {
        let start = Int(pos) & mask
        let first = min(frames, capacityFrames - start)
        dst.update(from: buffer + start * channels, count: first * channels)
        if frames > first {
            (dst + first * channels).update(from: buffer, count: (frames - first) * channels)
        }
    }
}
