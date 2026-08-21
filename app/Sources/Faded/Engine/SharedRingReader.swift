// SharedRingReader.swift — the consumer end of the driver's shared-memory ring.
//
// This is what replaced reading audio back through a hidden input device. The
// mapping is PROT_READ only and the read cursor lives here, in the app's own
// memory, so nothing in the shared region is ever written by this process — and
// because no audio *input* stream is involved anywhere, macOS never lights the
// microphone indicator.
//
// Every method below the `open`/`close` pair runs on the output render thread:
// no locks, no allocation, no syscalls.

import Darwin
import Foundation
import os

final class SharedRingReader: @unchecked Sendable {
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "SharedRing")

    private var ring: UnsafePointer<FadedSharedRing>?
    private var mapping: UnsafeMutableRawPointer?

    /// Frame index we will read next. Private to this process.
    private var cursor: UInt64 = 0
    private var primed = false
    private var generation: UInt32 = 0

    /// C macros import as Int32; the buffer maths wants Int.
    private let channels = Int(kFadedRingChannels)

    private(set) var underruns: UInt64 = 0
    private(set) var resyncs: UInt64 = 0

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
            Self.log.error("shared ring header mismatch (magic \(candidate.pointee.magic), version \(candidate.pointee.version))")
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

    /// Sample rate the driver is currently publishing, or nil if not mapped.
    var sampleRate: Double? {
        guard let ring else { return nil }
        let rate = FadedSharedRingSampleRate(ring)
        return rate > 0 ? Double(rate) : nil
    }

    /// True while apps are actually feeding the Faded device.
    var producerRunning: Bool {
        guard let ring else { return false }
        return FadedSharedRingOutputRunning(ring) != 0
    }

    var overruns: UInt64 {
        guard let ring else { return 0 }
        return FadedSharedRingOverruns(ring)
    }

    // MARK: Reading (render thread)

    /// Fills `dst` with `frames` frames of interleaved stereo, zero-filling
    /// whatever the producer has not supplied.
    func read(into dst: UnsafeMutablePointer<Float>, frames: UInt32) {
        guard let ring else {
            dst.update(repeating: 0, count: Int(frames) * channels)
            return
        }

        // The driver bumps `generation` when a new stream starts; anything
        // still in the buffer from the previous one is stale.
        let gen = FadedSharedRingGeneration(ring)
        if gen != generation {
            generation = gen
            resync()
        }

        let write = FadedSharedRingWriteIndex(ring)
        var available = write &- cursor

        // Producer has lapped us, or we were paused: don't play stale audio and
        // don't sit permanently late.
        if available > UInt64(kFadedRingMaxFrames) {
            cursor = write &- UInt64(kFadedRingPrimeFrames)
            available = UInt64(kFadedRingPrimeFrames)
            resyncs &+= 1
        }

        if !primed {
            guard available >= UInt64(kFadedRingPrimeFrames) else {
                dst.update(repeating: 0, count: Int(frames) * channels)
                return
            }
            primed = true
        }

        if available < UInt64(frames) {
            let have = UInt32(available)
            if have > 0 { FadedSharedRingCopyOut(ring, cursor, dst, have) }
            (dst + Int(have) * channels)
                .update(repeating: 0, count: Int(frames - have) * channels)
            cursor &+= UInt64(have)
            underruns &+= 1
            primed = false
        } else {
            FadedSharedRingCopyOut(ring, cursor, dst, frames)
            cursor &+= UInt64(frames)
        }
    }

    private func resync() {
        guard let ring else { return }
        cursor = FadedSharedRingWriteIndex(ring)
        primed = false
    }
}
