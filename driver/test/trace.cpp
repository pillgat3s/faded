// trace.cpp — deep-dive diagnostics for the simulation. Not part of the suite.
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <cstdint>
#include "../FadedShared.h"
#include "../FadedRingWriter.hpp"

int main(int argc, char** argv)
{
    const double ppm = argc > 1 ? atof(argv[1]) : 150;
    auto* ring = new FadedSharedRing();
    memset(ring, 0, sizeof(*ring));
    FadedRingWriter w(ring);

    constexpr double rate = 48000.0;
    constexpr uint32_t block = 512;
    constexpr double period = 65536.0;
    const double pDT = block / rate;
    const double cDT = block / (rate * (1.0 + ppm * 1e-6));
    double pNext = 0, cNext = pDT * 3;
    uint64_t pFrame = 10'000'000;
    std::vector<float> buf(block * 2);
    std::vector<float> out(block * 2);

    uint64_t posInt = 0; double posFrac = 0; bool primed = false;
    uint32_t gen = 0; double avg = 0; uint64_t under = 0;
    double target = kFadedRingBaseTargetFrames, maxBurst = 0, lastAvail = -1, lastCons = 0;
    double step = 1.0;

    // rate accounting
    uint64_t consumedTotal = 0, producedTotal = 0;
    double windowStart = -1;
    uint64_t discont = 0;
    double lastPos = -1; bool haveLast = false; int grace = 0;

    for (double t = 0; t < 120.0;) {
        if (pNext <= cNext) {
            t = pNext;
            for (uint32_t i = 0; i < block; ++i) {
                double pos = fmod((double)(pFrame + i), period);
                buf[i*2] = (float)(pos / period);
                buf[i*2+1] = (float)(fmod(pos + period/2, period) / period);
            }
            w.mixInAt(pFrame, buf.data(), block);
            pFrame += block; producedTotal += block; pNext += pDT;
        } else {
            t = cNext; cNext += cDT;
            uint32_t g = FadedSharedRingGeneration(ring);
            if (g != gen) { gen = g; posInt = FadedSharedRingWriteIndex(ring); posFrac = 0; avg = 0; primed = false; lastAvail = -1; }
            uint64_t wr = FadedSharedRingWriteIndex(ring);
            uint64_t af = wr - posInt;
            double avail = (double)af - posFrac;
            if (af > kFadedRingMaxFrames) { posInt = wr - (uint64_t)target; posFrac = 0; avail = target; avg = target; lastAvail = -1; }
            if (lastAvail >= 0) {
                double burst = avail - lastAvail + lastCons;
                if (burst > maxBurst) maxBurst = burst; else maxBurst *= 0.9999;
                double needed = maxBurst + block + 256;
                target = fmin(fmax((double)kFadedRingBaseTargetFrames, needed), (double)kFadedRingMaxTargetFrames);
            }
            if (!primed) { if (avail < target) { lastAvail = -1; continue; } primed = true; avg = avail; windowStart = t; consumedTotal = 0; producedTotal = 0; }
            avg += 0.01 * (avail - avg);
            double err = (avg - target) / target;
            step = fmin(fmax(1.0 + err * 0.02, 0.997), 1.003);
            double req = block * step + 2;
            if (avail < req) { under++; primed = false; lastAvail = -1; continue; }
            uint64_t posBefore = posInt; double fracBefore = posFrac;
            FadedSharedRingResample(ring, &posInt, &posFrac, step, out.data(), block);
            double consumed = (double)(posInt - posBefore) + (posFrac - fracBefore);
            consumedTotal += (uint64_t)llround(consumed * 1000); // milli-frames
            lastCons = block * step;
            lastAvail = avail - lastCons;

            if (grace > 0) { grace--; haveLast = false; continue; }
            for (uint32_t i = 0; i < block; ++i) {
                double l = out[i*2], r2 = out[i*2+1];
                double posL = l * period;
                double posR = fmod(r2 * period + period/2, period);
                double pos;
                if (haveLast) {
                    double expct = fmod(lastPos + 1.0, period);
                    double dL = fabs(fmod(posL - expct + period*1.5, period) - period/2);
                    double dR = fabs(fmod(posR - expct + period*1.5, period) - period/2);
                    pos = dL <= dR ? posL : posR;
                    double adv = pos - lastPos; if (adv < -period/2) adv += period;
                    if (fabs(adv - 1.0) > 0.5) {
                        if (discont < 5)
                            printf("t=%9.4f i=%3u DISC adv=%.4f L=%.6f R=%.6f posL=%.1f posR=%.1f last=%.1f frac=%.4f step=%+.0fppm\n",
                                   t, i, adv, l, r2, posL, posR, lastPos, posFrac, (step-1)*1e6);
                        discont++; haveLast = false; grace = 2; break;
                    }
                } else pos = posL > period*0.15 && posL < period*0.85 ? posL : posR;
                lastPos = pos; haveLast = true;
            }
        }
    }
    double window = 120.0 - windowStart;
    printf("\nconsumer ppm=%+.0f: consumed %.2f ring-frames/s (produced 48000/s), discont=%llu under=%llu\n",
           ppm, consumedTotal / 1000.0 / window, (unsigned long long)discont, (unsigned long long)under);
    printf("final: avg=%.1f target=%.1f step=%+.1fppm\n", avg, target, (step-1)*1e6);
    return 0;
}
