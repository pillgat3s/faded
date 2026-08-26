// FadedRingWriter.hpp — the producer side of the shared audio ring.
//
// This is the code that runs on coreaudiod's real-time I/O thread, extracted
// from the driver into a standalone header for one reason: so the stress
// harness in driver/test/ can compile and torture the *exact* code that ships,
// under AddressSanitizer, outside coreaudiod. An earlier version of this logic
// had an unbounded memset that wrote past the end of the sample array — inside
// coreaudiod — and wedged the machine's entire audio system. That class of bug
// must fail in a test binary, never on someone's speakers.
//
// DESIGN
//
// The ring is addressed by the HAL's own output sample time, not by counting
// calls. The HAL delivers one buffer per *client* per cycle, so a writer that
// advances once per call runs at N× real time with N apps playing (which
// sounds robotic: the consumer is fed too fast and lives in resync). With
// absolute positions, two clients writing the same cycle land on the same
// frames and sum — the client count is irrelevant to the clock.
//
// Real-time rules: no locks, no allocation, no syscalls. Single producer
// (the HAL serialises a device's I/O operations), single consumer (the app),
// who only ever reads.

#ifndef FADED_RING_WRITER_HPP
#define FADED_RING_WRITER_HPP

#include <algorithm>
#include <atomic>
#include <cstring>

#include "FadedShared.h"

class FadedRingWriter {
public:
    // The HAL's sample time is a Float64, whose integer precision ends at
    // 2^53; anything beyond that is not a sample time, it is corruption or a
    // fuzzer. Refusing it keeps the arithmetic below overflow-free.
    static constexpr uint64_t kMaxFrameIndex = 1ull << 53;

    explicit FadedRingWriter(FadedSharedRing* ring)
        : ring_(ring)
    {
    }

    /// Mix one client's stereo buffer into the ring at an absolute frame
    /// position and publish how far the device has got. Real-time thread.
    void mixInAt(uint64_t frameIndex, const float* frames, uint32_t frameCount)
    {
        if (!ring_ || frames == nullptr) return;
        // A buffer larger than the ring cannot be represented, and an index
        // beyond Float64 precision cannot be real.
        if (frameCount == 0 || frameCount > kFadedRingFrames) return;
        if (frameIndex >= kMaxFrameIndex - kFadedRingFrames) return;

        const uint64_t end = frameIndex + frameCount;

        // Does this buffer continue the current run, or start a new one?
        //
        // The device's frame clock jumps whenever a stream stops and restarts,
        // and the gap can be arbitrarily large — there is no meaningful way to
        // "clear the frames in between" when there are more of them than the
        // ring holds. Anything further away than one ring is a new run.
        bool restart = !anchored_;
        if (!restart) {
            const uint64_t gap = frameIndex > highWater_ ? frameIndex - highWater_
                                                         : highWater_ - frameIndex;
            if (gap > kFadedRingFrames) restart = true;
        }

        if (restart) {
            anchored_ = true;
            zeroRange(frameIndex, frameCount);
            highWater_ = end;
            // Tell the reader its position is meaningless now.
            std::atomic_fetch_add_explicit(&ring_->generation, 1u, std::memory_order_relaxed);
        } else if (end > highWater_) {
            // Bounded: the restart test above caps this at one ring's worth.
            const uint64_t from = std::max(highWater_, frameIndex);
            zeroRange(from, static_cast<uint32_t>(end - from));
            highWater_ = end;
        }
        // A buffer entirely at or below the high-water mark (a second client
        // in the same cycle, or a slightly late one) sums into frames that
        // are already zeroed and published — exactly what it should do.

        for (uint32_t i = 0; i < frameCount; ++i) {
            const uint32_t slot =
                static_cast<uint32_t>((frameIndex + i) & kFadedRingMask) * kFadedRingChannels;
            ring_->samples[slot] += frames[i * kFadedRingChannels];
            ring_->samples[slot + 1] += frames[i * kFadedRingChannels + 1];
        }

        // Release-store pairs with the reader's acquire-load: the samples
        // written above are visible before the new index is.
        std::atomic_store_explicit(&ring_->writeIndex, highWater_, std::memory_order_release);
    }

    /// The stream stopped; the next buffer starts a new run at whatever
    /// position the device's clock has then. Control thread — touches only
    /// the flag the RT thread reads at the top of its next call, after the
    /// stream has already been stopped by the HAL.
    void unanchor() { anchored_ = false; }

    void setRunning(bool running)
    {
        if (!ring_) return;
        std::atomic_store_explicit(&ring_->outputRunning, running ? 1u : 0u,
            std::memory_order_relaxed);
        if (running) {
            // Fresh stream: whatever is in the buffer predates it.
            std::atomic_fetch_add_explicit(&ring_->generation, 1u, std::memory_order_relaxed);
        }
    }

    void setSampleRate(uint32_t rate)
    {
        if (ring_) {
            std::atomic_store_explicit(&ring_->sampleRate, rate, std::memory_order_relaxed);
        }
    }

private:
    void zeroRange(uint64_t index, uint32_t frameCount)
    {
        // Hard clamp, independent of the callers' care: this writes into a
        // fixed buffer inside coreaudiod's address space, and one bad length
        // here corrupts the machine's audio system, not just Faded.
        if (frameCount > kFadedRingFrames) frameCount = kFadedRingFrames;
        const uint32_t start = static_cast<uint32_t>(index & kFadedRingMask);
        const uint32_t first = std::min(frameCount, kFadedRingFrames - start);
        std::memset(&ring_->samples[start * kFadedRingChannels], 0,
            sizeof(float) * first * kFadedRingChannels);
        if (frameCount > first) {
            std::memset(&ring_->samples[0], 0,
                sizeof(float) * (frameCount - first) * kFadedRingChannels);
        }
    }

    FadedSharedRing* ring_ = nullptr;
    uint64_t highWater_ = 0;  // real-time thread only
    bool anchored_ = false;   // RT thread + unanchor(); plain bool by design
};

#endif // FADED_RING_WRITER_HPP
