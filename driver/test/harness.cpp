// harness.cpp — stress tests for the shared audio ring, outside coreaudiod.
//
// The ring's producer runs inside coreaudiod: a memory bug there does not
// crash Faded, it wedges the machine's entire audio system (this happened).
// So the producer (FadedRingWriter.hpp) and the resampler the app reads with
// (FadedSharedRingResample in FadedShared.h) are compiled into this ordinary
// binary and beaten on under AddressSanitizer and UBSan, where that class of
// fault segfaults a test instead of someone's speakers.
//
// The consumer-side control loop lives in Swift (SharedRingReader.swift); it
// is ported here line for line, with the same constants, so the drift and
// continuity behaviour tested is the shipped algorithm. Change them together.
//
// What "working as intended" means, mechanically:
//   * the write index advances at exactly the device clock, regardless of how
//     many clients play (the 2x bug sounded like a robot);
//   * no input whatsoever can write outside the sample array (the wedge);
//   * under realistic clock drift, playback is *continuous*: no underruns, no
//     resyncs, no skipped or repeated frames;
//   * the fill target adapts to the producer's cycle size, so a device that
//     coreaudiod runs at large buffers doesn't click on every phase wrap;
//   * abrupt stream restarts (app killed, device switched) recover within one
//     resync and keep playing.
//
// Build & run:  make test-driver

#include <cassert>
#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "../FadedShared.h"
#include "../FadedRingWriter.hpp"

namespace {

int failures = 0;

#define CHECK(cond, ...)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);    \
            std::printf("       ");                                          \
            std::printf(__VA_ARGS__);                                        \
            std::printf("\n");                                               \
            ++failures;                                                      \
        }                                                                    \
    } while (0)

FadedSharedRing* newRing()
{
    auto* ring = new FadedSharedRing();
    std::memset(ring, 0, sizeof(FadedSharedRing));
    ring->magic = kFadedShmMagic;
    ring->version = kFadedShmVersion;
    ring->capacityFrames = kFadedRingFrames;
    ring->channels = kFadedRingChannels;
    return ring;
}

// ---------------------------------------------------------------------------
// Reader — line-for-line port of SharedRingReader.swift's read()/resync(),
// same constants, driving the shipped FadedSharedRingResample.
// ---------------------------------------------------------------------------

class ReaderPort {
public:
    explicit ReaderPort(const FadedSharedRing* ring)
        : ring_(ring)
    {
    }

    uint64_t underruns = 0;
    uint64_t resyncs = 0;
    double fill() const { return averageFill_; }
    double target() const { return targetFill_; }
    double driftPPM() const { return driftPPM_; }

    // Returns true if real audio was produced (false = silence emitted).
    bool read(float* dst, uint32_t frames)
    {
        const uint32_t gen = FadedSharedRingGeneration(ring_);
        if (gen != generation_) {
            generation_ = gen;
            resync();
        }

        const uint64_t write = FadedSharedRingWriteIndex(ring_);
        const uint64_t availableFrames = write - posInt_;
        double available = static_cast<double>(availableFrames) - posFrac_;

        if (availableFrames > kFadedRingMaxFrames) {
            posInt_ = write - static_cast<uint64_t>(targetFill_);
            posFrac_ = 0;
            available = targetFill_;
            averageFill_ = targetFill_;
            lastAvailable_ = -1;
            ++resyncs;
        }

        // Track the producer's burst size: between two reads, the fill changes
        // by (produced - consumed), so produced = delta + what we consumed.
        if (lastAvailable_ >= 0) {
            const double burst = available - lastAvailable_ + lastConsumed_;
            if (burst > maxBurst_) {
                maxBurst_ = burst;
            } else {
                maxBurst_ *= 0.9999;
            }
            const double needed = maxBurst_ + static_cast<double>(frames) + 256;
            targetFill_ = std::min(std::max(double(kFadedRingBaseTargetFrames), needed),
                double(kFadedRingMaxTargetFrames));
        }

        if (!primed_) {
            if (available < targetFill_) {
                std::memset(dst, 0, sizeof(float) * frames * kFadedRingChannels);
                lastAvailable_ = available;   // keep observing bursts
                lastConsumed_ = 0;
                return false;
            }
            primed_ = true;
            averageFill_ = available;
        }

        averageFill_ += kFillSmoothing * (available - averageFill_);
        const double error = (averageFill_ - targetFill_) / targetFill_;
        double step = 1.0 + error * kLoopGain;
        step = std::min(std::max(step, 1.0 - kMaxCorrection), 1.0 + kMaxCorrection);
        driftPPM_ = (step - 1.0) * 1e6;

        const double required = static_cast<double>(frames) * step + 2;
        if (available < required) {
            std::memset(dst, 0, sizeof(float) * frames * kFadedRingChannels);
            ++underruns;
            primed_ = false;
            lastAvailable_ = available;   // keep the burst estimate
            lastConsumed_ = 0;
            return false;
        }

        FadedSharedRingResample(ring_, &posInt_, &posFrac_, step, dst, frames);
        lastConsumed_ = static_cast<double>(frames) * step;
        lastAvailable_ = available - lastConsumed_;
        return true;
    }

private:
    static constexpr double kMaxCorrection = 0.003;
    static constexpr double kLoopGain = 0.02;
    static constexpr double kFillSmoothing = 0.01;

    void resync()
    {
        posInt_ = FadedSharedRingWriteIndex(ring_);
        posFrac_ = 0;
        averageFill_ = 0;
        primed_ = false;
        lastAvailable_ = -1;
    }

    const FadedSharedRing* ring_;
    uint64_t posInt_ = 0;
    double posFrac_ = 0;
    bool primed_ = false;
    uint32_t generation_ = 0;
    double averageFill_ = 0;
    double driftPPM_ = 0;
    double targetFill_ = kFadedRingBaseTargetFrames;
    double maxBurst_ = 0;
    double lastAvailable_ = -1;
    double lastConsumed_ = 0;
};

// ---------------------------------------------------------------------------
// Producer-semantics tests
// ---------------------------------------------------------------------------

void testSingleClientRealtime()
{
    std::puts("single client advances at exactly 1x");
    auto* ring = newRing();
    FadedRingWriter w(ring);
    std::vector<float> buf(512 * 2, 0.25f);

    const uint64_t base = 1'000'000;
    for (uint32_t c = 0; c < 200; ++c) {
        w.mixInAt(base + c * 512, buf.data(), 512);
    }
    const uint64_t produced = FadedSharedRingWriteIndex(ring) - base;
    CHECK(produced == 200 * 512, "produced %" PRIu64 " frames, expected %d", produced, 200 * 512);
    delete ring;
}

void testThreeClientsSameCycle()
{
    std::puts("three clients in one cycle: 1x clock, samples sum");
    auto* ring = newRing();
    FadedRingWriter w(ring);
    std::vector<float> a(512 * 2, 0.1f), b(512 * 2, 0.2f), c(512 * 2, 0.3f);

    const uint64_t base = 5'000'000;
    for (uint32_t cyc = 0; cyc < 100; ++cyc) {
        const uint64_t t = base + cyc * 512;
        w.mixInAt(t, a.data(), 512);   // the 2x bug: this used to advance...
        w.mixInAt(t, b.data(), 512);   // ...the clock once per CLIENT,
        w.mixInAt(t, c.data(), 512);   // not once per cycle.
    }
    const uint64_t produced = FadedSharedRingWriteIndex(ring) - base;
    CHECK(produced == 100 * 512, "produced %" PRIu64 ", expected %d (2x/3x bug?)", produced, 100 * 512);

    const uint32_t slot = static_cast<uint32_t>(base & kFadedRingMask) * 2;
    CHECK(std::fabs(ring->samples[slot] - 0.6f) < 1e-5,
        "clients did not sum: sample = %f, expected 0.6", ring->samples[slot]);
    delete ring;
}

void testJumpsAndGarbage()
{
    std::puts("timestamp jumps and garbage input never leave the array");
    auto* ring = newRing();
    FadedRingWriter w(ring);
    std::vector<float> buf(4096 * 2, 1.0f);

    w.mixInAt(1'000, buf.data(), 512);
    const uint32_t genBefore = FadedSharedRingGeneration(ring);

    // The wedge scenario: a forward jump far larger than the ring.
    w.mixInAt(4'000'000'000ull, buf.data(), 512);
    CHECK(FadedSharedRingGeneration(ring) == genBefore + 1, "forward jump must bump generation");
    CHECK(FadedSharedRingWriteIndex(ring) == 4'000'000'000ull + 512, "index tracks the new run");

    // Backward jump.
    w.mixInAt(7'777, buf.data(), 512);
    CHECK(FadedSharedRingGeneration(ring) == genBefore + 2, "backward jump must bump generation");

    // Small gap inside a run gets zeroed, not treated as a restart.
    w.mixInAt(7'777 + 512 + 1'000, buf.data(), 512);
    CHECK(FadedSharedRingGeneration(ring) == genBefore + 2, "small gap must NOT bump generation");
    const uint32_t holeSlot = static_cast<uint32_t>((7'777 + 512 + 100) & kFadedRingMask) * 2;
    CHECK(ring->samples[holeSlot] == 0.0f, "gap frames must be silence, got %f", ring->samples[holeSlot]);

    // Garbage that must be refused outright.
    const uint64_t before = FadedSharedRingWriteIndex(ring);
    w.mixInAt(0, buf.data(), 0);                                   // zero frames
    w.mixInAt(0, nullptr, 512);                                    // null buffer
    w.mixInAt(1'000'000, buf.data(), kFadedRingFrames + 1);        // larger than the ring
    w.mixInAt(~0ull - 40, buf.data(), 512);                        // uint64 overflow bait
    w.mixInAt(1ull << 60, buf.data(), 512);                        // beyond Float64 sample time
    CHECK(FadedSharedRingWriteIndex(ring) == before, "garbage input must not move the index");
    delete ring;
}

void testWriterFuzz()
{
    std::puts("fuzz: 300k random operations under ASan/UBSan");
    auto* ring = newRing();
    FadedRingWriter w(ring);
    std::mt19937_64 rng(0xFADED);
    std::vector<float> buf(70'000 * 2, 0.5f);

    for (int i = 0; i < 300'000; ++i) {
        const uint64_t r = rng();
        uint64_t idx;
        switch (r & 3) {
        case 0: idx = r >> 32; break;                       // plausible
        case 1: idx = r; break;                             // anywhere in uint64
        case 2: idx = (1ull << 53) + (r & 0xFFFF); break;   // around the precision guard
        default: idx = ~0ull - (r & 0xFFFF); break;         // around the overflow
        }
        const uint32_t count = static_cast<uint32_t>(rng() % 70'000);
        w.mixInAt(idx, buf.data(), count);
        if ((r & 0xFF) == 0) w.unanchor();
        if ((r & 0x1FF) == 1) w.setRunning((r & 1) != 0);
    }
    std::puts("  survived");
    delete ring;
}

// ---------------------------------------------------------------------------
// End-to-end simulation: producer and consumer on drifting clocks
// ---------------------------------------------------------------------------

struct SimResult {
    uint64_t underruns = 0;
    uint64_t resyncs = 0;
    uint64_t discontinuities = 0;
    double finalFill = 0;
    double finalTarget = 0;
    double finalDriftPPM = 0;
};

// The producer writes two phase-offset ramps (left = position, right =
// position + half period) whose values encode the absolute frame index; a
// skipped or repeated frame on the consumer side shows as a position jump.
// Two phases because linear interpolation across a ramp's wrap-around
// produces a bogus midpoint — the checker always reads whichever channel is
// far from its wrap. This is the mechanical version of listening for robo
// sounds.
SimResult simulate(double consumerPPM, int seconds, int clients, bool restartMidway,
    uint32_t producerBlock = 512)
{
    auto* ring = newRing();
    FadedRingWriter w(ring);
    ReaderPort r(ring);

    constexpr double rate = 48'000.0;
    constexpr uint32_t block = 512;      // consumer output block
    constexpr double period = 65'536.0;  // ramp period in frames

    const double producerDT = producerBlock / rate;
    const double consumerDT = block / (rate * (1.0 + consumerPPM * 1e-6));

    double producerNext = 0, consumerNext = producerDT * 3;
    uint64_t producerFrame = 10'000'000;
    double simTime = 0;

    std::vector<float> pbuf(producerBlock * 2);
    std::vector<float> cbuf(block * 2);

    SimResult res;
    double lastPos = -1;   // decoded absolute position (mod period), frames
    bool haveLast = false;
    bool restarted = false;
    int graceBlocks = 0;

    const double end = seconds;
    while (simTime < end) {
        if (producerNext <= consumerNext) {
            simTime = producerNext;
            for (uint32_t i = 0; i < producerBlock; ++i) {
                const double pos = std::fmod(static_cast<double>(producerFrame + i), period);
                pbuf[i * 2] = static_cast<float>(pos / period);
                pbuf[i * 2 + 1] =
                    static_cast<float>(std::fmod(pos + period / 2, period) / period);
            }
            for (int c = 0; c < clients; ++c) {
                w.mixInAt(producerFrame, pbuf.data(), producerBlock);
            }
            producerFrame += producerBlock;
            producerNext += producerDT;

            if (restartMidway && !restarted && simTime > end / 2) {
                w.unanchor();
                w.setRunning(false);
                w.setRunning(true);
                producerFrame = 3'000'000'000ull;
                restarted = true;
            }
        } else {
            simTime = consumerNext;
            const uint64_t resyncsBefore = r.resyncs;
            const bool audio = r.read(cbuf.data(), block);
            consumerNext += consumerDT;

            if (!audio || r.resyncs != resyncsBefore) {
                haveLast = false;
                graceBlocks = 2;
                res.resyncs = r.resyncs;
                continue;
            }
            if (graceBlocks > 0) {
                --graceBlocks;
                haveLast = false;
                continue;
            }

            for (uint32_t i = 0; i < block; ++i) {
                const double l = cbuf[i * 2] / clients;
                const double rr = cbuf[i * 2 + 1] / clients;
                const double posL = l * period;
                const double posR = std::fmod(rr * period + period / 2, period);
                double pos;
                if (haveLast) {
                    // The two channels encode the same position, half a period
                    // apart. Linear interpolation across a channel's own wrap
                    // produces a bogus midpoint, so trust whichever channel is
                    // closer to where the position is expected to be; only if
                    // BOTH are off has the audio actually jumped.
                    const double expected = std::fmod(lastPos + 1.0, period);
                    auto dist = [&](double p) {
                        double d = std::fabs(p - expected);
                        return std::min(d, period - d);
                    };
                    pos = dist(posL) <= dist(posR) ? posL : posR;
                    double advance = pos - lastPos;
                    if (advance < -period / 2) advance += period;
                    if (std::fabs(advance - 1.0) > 0.5) {
                        ++res.discontinuities;
                        haveLast = false;
                        graceBlocks = 2;
                        break;
                    }
                } else {
                    // Seed from whichever channel is far from its wrap.
                    pos = (l > 0.15 && l < 0.85) ? posL : posR;
                }
                lastPos = pos;
                haveLast = true;
            }
        }
    }

    res.underruns = r.underruns;
    res.resyncs = r.resyncs;
    res.finalFill = r.fill();
    res.finalTarget = r.target();
    res.finalDriftPPM = r.driftPPM();
    delete ring;
    return res;
}

void testSteadyPlayback(double ppm, int clients, int seconds = 300)
{
    std::printf("steady playback, consumer %+.0f ppm, %d client(s), %d s\n", ppm, clients, seconds);
    const SimResult r = simulate(ppm, seconds, clients, false);
    CHECK(r.underruns == 0, "underruns=%" PRIu64 " (each one is an audible click)", r.underruns);
    CHECK(r.resyncs == 0, "resyncs=%" PRIu64 " (each one is an audible jump)", r.resyncs);
    CHECK(r.discontinuities == 0, "discontinuities=%" PRIu64 " (this IS the robo sound)",
        r.discontinuities);
    // Uncompensated, this drift would move the fill by rate*ppm*seconds — far
    // beyond the buffer. Holding near target across the whole run IS the proof
    // the loop compensates; the instantaneous step is unmeasurable because the
    // stairstep fill makes it correct in bursts at phase-wraps.
    CHECK(std::fabs(r.finalFill - r.finalTarget) < 1200,
        "fill %.0f wandered from target %.0f — the loop is not compensating",
        r.finalFill, r.finalTarget);
    std::printf("  clean: fill=%.0f/%.0f\n", r.finalFill, r.finalTarget);
}

void testBigProducerCycles()
{
    std::puts("producer at 4096-frame cycles (coreaudiod power-saving mode), 300 s");
    const SimResult r = simulate(200, 300, 2, false, 4096);
    CHECK(r.underruns == 0, "underruns=%" PRIu64 " — the fill target failed to adapt", r.underruns);
    CHECK(r.resyncs == 0, "resyncs=%" PRIu64, r.resyncs);
    CHECK(r.discontinuities == 0, "discontinuities=%" PRIu64, r.discontinuities);
    CHECK(r.finalTarget > 4096, "target=%.0f, expected to have adapted above one 4096 burst",
        r.finalTarget);
    std::printf("  clean: fill=%.0f, adapted target=%.0f, correction=%+.0f ppm\n",
        r.finalFill, r.finalTarget, r.finalDriftPPM);
}

void testRestartRecovery()
{
    std::puts("abrupt stream restart mid-playback (the kill -9 scenario)");
    const SimResult r = simulate(150, 60, 2, true);
    CHECK(r.resyncs <= 2, "resyncs=%" PRIu64 ", expected at most 2 for one restart", r.resyncs);
    CHECK(r.underruns <= 2, "underruns=%" PRIu64 ", expected at most a couple at the restart",
        r.underruns);
    CHECK(r.discontinuities <= 3, "discontinuities=%" PRIu64 ", must not keep glitching after recovery",
        r.discontinuities);
    std::printf("  recovered: resyncs=%" PRIu64 " underruns=%" PRIu64 " discontinuities=%" PRIu64 "\n",
        r.resyncs, r.underruns, r.discontinuities);
}

} // namespace

int main()
{
    std::puts("=== Faded ring stress harness (ASan + UBSan) ===");
    testSingleClientRealtime();
    testThreeClientsSameCycle();
    testJumpsAndGarbage();
    testWriterFuzz();
    testSteadyPlayback(0, 1);        // perfect clocks
    testSteadyPlayback(+150, 1);     // consumer crystal fast (typical drift)
    testSteadyPlayback(-150, 1);     // consumer crystal slow
    testSteadyPlayback(+400, 3);     // heavy drift, three apps playing
    testSteadyPlayback(+250, 2, 600); // endurance: 10 min — uncompensated this
                                      // is 7200 frames of drift, 3.5 buffers
    testBigProducerCycles();
    testRestartRecovery();

    if (failures == 0) {
        std::puts("=== ALL TESTS PASSED ===");
        return 0;
    }
    std::printf("=== %d FAILURE(S) ===\n", failures);
    return 1;
}
