// FadedFIFO.hpp — single-producer / single-consumer ring buffer of interleaved
// Float32 frames, shared between the "Faded" output device (writer, its I/O
// thread) and the "Faded Tap" input device (reader, its I/O thread).
//
// Both sides run on real-time threads, so: no locks, no allocation, no
// syscalls. Positions are monotonically increasing frame counters; the buffer
// index is pos & mask (capacity is a power of two).
//
// Both devices are clocked off the same host clock at the same nominal rate,
// so there is no long-term drift — only jitter. Policy:
//   * Reader keeps a small cushion ("prime") before it starts consuming after
//     an underrun, so one late writer period doesn't produce a glitch.
//   * If the queue grows past `maxFrames` (writer got ahead — e.g. the reader
//     was stalled), the reader skips forward to `primeFrames` of latency
//     instead of letting the latency stay high forever.
//   * If the writer finds the queue full it drops the newest data. Rare, and
//     the reader's trimming makes it self-correct.

#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <algorithm>

namespace faded {

class FIFO {
public:
    static constexpr uint32_t kChannels = 2;
    static constexpr uint32_t kCapacityFrames = 1u << 15;   // 32768 frames ≈ 680 ms @ 48k
    static constexpr uint32_t kMask = kCapacityFrames - 1;
    static constexpr uint32_t kPrimeFrames = 1024;          // ≈ 21 ms @ 48k cushion
    static constexpr uint32_t kMaxFrames = 8192;            // ≈ 170 ms — trim above this

    static FIFO& shared()
    {
        static FIFO instance;
        return instance;
    }

    // Writer side ----------------------------------------------------------

    void write(const float* frames, uint32_t frameCount)
    {
        const uint64_t w = write_.load(std::memory_order_relaxed);
        const uint64_t r = read_.load(std::memory_order_acquire);
        const uint64_t used = w - r;
        uint32_t space = static_cast<uint32_t>(kCapacityFrames - used);
        if (frameCount > space) {
            overruns_.fetch_add(1, std::memory_order_relaxed);
            frameCount = space; // drop newest
        }
        if (frameCount == 0) {
            return;
        }
        copyIn(w, frames, frameCount);
        write_.store(w + frameCount, std::memory_order_release);
    }

    // Reader side ----------------------------------------------------------

    // Fills `out` with `frameCount` frames. Zero-fills on underrun.
    void read(float* out, uint32_t frameCount)
    {
        const uint64_t w = write_.load(std::memory_order_acquire);
        uint64_t r = read_.load(std::memory_order_relaxed);
        uint64_t avail = w - r;

        // Trim if we're lagging way behind (reader stalled, sample-rate change...).
        if (avail > kMaxFrames) {
            r = w - kPrimeFrames;
            avail = kPrimeFrames;
            trims_.fetch_add(1, std::memory_order_relaxed);
        }

        if (!primed_) {
            if (avail >= kPrimeFrames) {
                primed_ = true;
            } else {
                std::memset(out, 0, sizeof(float) * frameCount * kChannels);
                read_.store(r, std::memory_order_release);
                return;
            }
        }

        if (avail < frameCount) {
            // Underrun: emit what we have, zero the rest, and re-prime.
            copyOut(r, out, static_cast<uint32_t>(avail));
            std::memset(out + avail * kChannels, 0,
                sizeof(float) * (frameCount - avail) * kChannels);
            r += avail;
            underruns_.fetch_add(1, std::memory_order_relaxed);
            primed_ = false;
        } else {
            copyOut(r, out, frameCount);
            r += frameCount;
        }
        read_.store(r, std::memory_order_release);
    }

    // Reset to empty. Call from a control thread while I/O is stopped
    // (e.g. on sample-rate change).
    void reset()
    {
        read_.store(write_.load(std::memory_order_acquire), std::memory_order_release);
        primed_ = false;
    }

    // Diagnostics ----------------------------------------------------------

    uint32_t availableFrames() const
    {
        return static_cast<uint32_t>(write_.load(std::memory_order_acquire) -
                                     read_.load(std::memory_order_acquire));
    }
    uint64_t underruns() const { return underruns_.load(std::memory_order_relaxed); }
    uint64_t overruns() const { return overruns_.load(std::memory_order_relaxed); }
    uint64_t trims() const { return trims_.load(std::memory_order_relaxed); }

private:
    FIFO() = default;

    void copyIn(uint64_t pos, const float* src, uint32_t frames)
    {
        const uint32_t start = static_cast<uint32_t>(pos & kMask);
        const uint32_t first = std::min(frames, kCapacityFrames - start);
        std::memcpy(&buf_[start * kChannels], src, sizeof(float) * first * kChannels);
        if (frames > first) {
            std::memcpy(&buf_[0], src + first * kChannels,
                sizeof(float) * (frames - first) * kChannels);
        }
    }

    void copyOut(uint64_t pos, float* dst, uint32_t frames)
    {
        const uint32_t start = static_cast<uint32_t>(pos & kMask);
        const uint32_t first = std::min(frames, kCapacityFrames - start);
        std::memcpy(dst, &buf_[start * kChannels], sizeof(float) * first * kChannels);
        if (frames > first) {
            std::memcpy(dst + first * kChannels, &buf_[0],
                sizeof(float) * (frames - first) * kChannels);
        }
    }

    alignas(64) std::atomic<uint64_t> write_{0};
    alignas(64) std::atomic<uint64_t> read_{0};
    bool primed_ = false; // reader-thread only

    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> overruns_{0};
    std::atomic<uint64_t> trims_{0};

    float buf_[kCapacityFrames * kChannels] = {};
};

} // namespace faded
