// FadedShared.h — the shared-memory audio channel between the driver and the app.
//
// WHY THIS EXISTS
//
// The obvious way to get audio back out of a virtual output device is to expose
// a second, hidden *input* device and have the app read from it. That works,
// and it is what Faded did first — but macOS lights the orange microphone
// indicator for any process holding an audio input stream, and it makes no
// distinction between a real microphone and a hidden virtual device. The
// indicator would then be lit for as long as Faded was routing audio, which is
// unacceptable for something that never records anything.
//
// So the audio does not travel over an audio device at all. The driver — which
// lives inside coreaudiod — publishes a POSIX shared-memory ring, and the app
// maps it read-only and pulls frames straight from it inside its output render
// callback. The app therefore only ever opens an *output* stream, and no
// indicator appears.
//
// CONCURRENCY
//
// Single producer (the driver's real-time I/O thread), single consumer (the
// app's output render callback). Both are real-time threads, so there are no
// locks, no allocation and no syscalls on either side.
//
// The writer is free-running: it never waits for the reader and never reads the
// reader's position. The reader keeps its own cursor in its own address space,
// which is why the mapping can be read-only — nothing in the shared region is
// ever written by the app. If the reader falls behind by more than the buffer
// holds, it notices (write - cursor > capacity) and resynchronises.

#ifndef FADED_SHARED_H
#define FADED_SHARED_H

#include <stdint.h>

// The driver compiles this as C++ and the app imports it as C. <stdatomic.h>
// and <atomic> define colliding macros, so each language gets its own spelling
// of the same underlying lock-free types — the memory layout is identical.
#ifdef __cplusplus
#include <atomic>
#define FADED_ATOMIC(T) std::atomic<T>
#define FADED_LOAD(p, order) std::atomic_load_explicit(p, std::order)
#else
#include <stdatomic.h>
#define FADED_ATOMIC(T) _Atomic T
#define FADED_LOAD(p, order) atomic_load_explicit(p, order)
#endif

#ifdef __cplusplus
extern "C" {
#endif

// POSIX shared memory names are limited to 31 characters on macOS
// (PSHMNAMLEN), including the leading slash. This is 21.
#define kFadedShmName "/com.andri.faded.ring"

#define kFadedShmMagic 0x46414431u /* 'FAD1' */
#define kFadedShmVersion 1u

#define kFadedRingChannels 2
#define kFadedRingFrames (1u << 15) /* 32768 frames — ~680 ms at 48 kHz */
#define kFadedRingMask (kFadedRingFrames - 1u)

/// How far ahead of the reader the writer should be before playback starts.
/// Absorbs one late buffer on either side without a dropout.
#define kFadedRingPrimeFrames 1024u
/// If the reader is further behind than this, it jumps forward rather than
/// letting latency stay high forever.
#define kFadedRingMaxFrames 8192u

typedef struct {
    uint32_t magic;    // kFadedShmMagic once initialised
    uint32_t version;  // kFadedShmVersion
    uint32_t capacityFrames;
    uint32_t channels;

    // Monotonically increasing frame counter. Only the driver writes it.
    FADED_ATOMIC(uint64_t) writeIndex;

    // Published for the app's diagnostics; none of it affects audio.
    FADED_ATOMIC(uint32_t) sampleRate;
    FADED_ATOMIC(uint32_t) outputRunning;  // the Faded device has clients doing I/O
    FADED_ATOMIC(uint64_t) overruns;       // writer laps the reader could not have seen
    FADED_ATOMIC(uint32_t) generation;     // bumped whenever the stream restarts

    uint32_t _reserved[3];

    // Interleaved stereo float32, indexed by (frameIndex & kFadedRingMask).
    float samples[kFadedRingFrames * kFadedRingChannels];
} FadedSharedRing;

/// Acquire-load of the write cursor. Pairs with the driver's release-store, so
/// samples written before the store are visible once the reader sees it.
static inline uint64_t FadedSharedRingWriteIndex(const FadedSharedRing* ring)
{
    return FADED_LOAD((FADED_ATOMIC(uint64_t)*)&ring->writeIndex, memory_order_acquire);
}

static inline uint32_t FadedSharedRingSampleRate(const FadedSharedRing* ring)
{
    return FADED_LOAD((FADED_ATOMIC(uint32_t)*)&ring->sampleRate, memory_order_relaxed);
}

static inline uint32_t FadedSharedRingOutputRunning(const FadedSharedRing* ring)
{
    return FADED_LOAD((FADED_ATOMIC(uint32_t)*)&ring->outputRunning, memory_order_relaxed);
}

static inline uint32_t FadedSharedRingGeneration(const FadedSharedRing* ring)
{
    return FADED_LOAD((FADED_ATOMIC(uint32_t)*)&ring->generation, memory_order_relaxed);
}

static inline uint64_t FadedSharedRingOverruns(const FadedSharedRing* ring)
{
    return FADED_LOAD((FADED_ATOMIC(uint64_t)*)&ring->overruns, memory_order_relaxed);
}

/// Reads `frameCount` frames starting at the fractional position
/// (`*posInt` + `*posFrac`), advancing by `step` per output frame, with linear
/// interpolation between neighbouring frames.
///
/// This is what compensates for clock drift. The producer is clocked by
/// coreaudiod and the consumer by the real output device's own crystal; those
/// disagree by of the order of 100 ppm, so with a fixed read rate the buffer
/// between them inevitably drains or fills until it glitches — a click every
/// few minutes, at no predictable moment. Reading at a rate nudged very
/// slightly (a fraction of a percent) toward whatever keeps the buffer at its
/// target level removes the drift instead of postponing it.
///
/// `step` stays within a hair of 1.0, so linear interpolation is inaudible
/// here; it is doing sub-sample alignment, not real resampling.
static inline void FadedSharedRingResample(const FadedSharedRing* ring,
                                           uint64_t* posInt,
                                           double* posFrac,
                                           double step,
                                           float* dst,
                                           uint32_t frameCount)
{
    uint64_t p = *posInt;
    double frac = *posFrac;
    for (uint32_t n = 0; n < frameCount; ++n) {
        const uint32_t i0 = (uint32_t)(p & kFadedRingMask) * kFadedRingChannels;
        const uint32_t i1 = (uint32_t)((p + 1) & kFadedRingMask) * kFadedRingChannels;
        const float w = (float)frac;
        dst[n * 2] = ring->samples[i0] + (ring->samples[i1] - ring->samples[i0]) * w;
        dst[n * 2 + 1] = ring->samples[i0 + 1] + (ring->samples[i1 + 1] - ring->samples[i0 + 1]) * w;
        frac += step;
        // step is always within a few thousandths of 1.0, so this runs at most
        // twice — no need for floor() and its header.
        while (frac >= 1.0) { frac -= 1.0; p += 1; }
    }
    *posInt = p;
    *posFrac = frac;
}

/// Copies `frameCount` frames ending at `fromIndex` into `dst`, wrapping as
/// needed. The caller has already established that the range is still live.
static inline void FadedSharedRingCopyOut(const FadedSharedRing* ring,
                                          uint64_t fromIndex,
                                          float* dst,
                                          uint32_t frameCount)
{
    const uint32_t start = (uint32_t)(fromIndex & kFadedRingMask);
    const uint32_t first = frameCount < (kFadedRingFrames - start) ? frameCount : (kFadedRingFrames - start);
    for (uint32_t i = 0; i < first * kFadedRingChannels; ++i) {
        dst[i] = ring->samples[start * kFadedRingChannels + i];
    }
    for (uint32_t i = 0; i < (frameCount - first) * kFadedRingChannels; ++i) {
        dst[first * kFadedRingChannels + i] = ring->samples[i];
    }
}

#ifdef __cplusplus
}
#endif

#endif // FADED_SHARED_H
