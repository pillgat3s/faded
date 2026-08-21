// FadedDriver — CoreAudio AudioServerPlugIn (HAL driver) for Faded.app.
//
// Two virtual devices in one plug-in:
//
//   "Faded"      visible OUTPUT device. Apps play into it. It exposes a real
//                volume + mute control, so macOS's Sound slider, the menu bar
//                sound item and the F11/F12 keys all "just work" on it — that
//                is what makes hardware-volume-less devices (Astro A50 base
//                station, most USB DACs, HDMI) controllable from the keyboard.
//
//   "Faded Tap"  HIDDEN input device. Faded.app reads the mixed, processed
//                output back from it and plays it to the real target device
//                (built-in speakers, AirPods, Astro, AirPlay…). Hidden means
//                Discord/Zoom/etc. never see a fake microphone.
//
// Processing chain per I/O cycle on the Faded device (all real-time thread):
//
//   client A ─┐  OnProcessClientOutput: × per-app gain, peak meter
//   client B ─┼─► libASPL mixes ─► OnProcessMixedOutput: × master vol / mute
//   client C ─┘                     (unless bypassed) ─► OnWriteMixedOutput ─► FIFO
//
//   Faded Tap: OnReadClientInput ◄─ FIFO
//
// App <-> driver control goes through custom properties on the Faded device
// (see FadedProtocol.h). Built on libASPL (MIT) which handles the enormous
// AudioServerPlugIn boilerplate; this file is only the Faded-specific logic.

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <syslog.h>
#include <unistd.h>

#include "FadedShared.h"
#include "FadedProtocol.h"

namespace {

// ---------------------------------------------------------------------------
// Small CF helpers
// ---------------------------------------------------------------------------

CFStringRef makeCFString(const std::string& s)
{
    return CFStringCreateWithCString(kCFAllocatorDefault, s.c_str(), kCFStringEncodingUTF8);
}

std::string toStdString(CFStringRef s)
{
    if (!s) {
        return {};
    }
    if (const char* fast = CFStringGetCStringPtr(s, kCFStringEncodingUTF8)) {
        return fast;
    }
    const CFIndex len = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    std::string out(static_cast<size_t>(len), '\0');
    if (CFStringGetCString(s, out.data(), len, kCFStringEncodingUTF8)) {
        out.resize(std::strlen(out.c_str()));
        return out;
    }
    return {};
}

CFNumberRef makeCFNumber(double v)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &v);
}

CFNumberRef makeCFNumber(long long v)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &v);
}

void dictSet(CFMutableDictionaryRef d, const char* key, CFTypeRef value /* consumed */)
{
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, k, value);
    CFRelease(k);
    CFRelease(value);
}

// ---------------------------------------------------------------------------
// Audio format
// ---------------------------------------------------------------------------

AudioStreamBasicDescription floatFormat(Float64 rate)
{
    AudioStreamBasicDescription f = {};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = kFadedChannelCount;
    f.mBytesPerFrame = sizeof(Float32) * kFadedChannelCount;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = f.mBytesPerFrame;
    return f;
}

// One rate, deliberately.
//
// libASPL's SetNominalSampleRateImpl only records the number; it does not
// re-format the device's streams, and asking the streams to change format
// afterwards does not take either (verified: set nominal to 44100 and the
// stream stays at 48000). coreaudiod clocks I/O from the *stream* format, so a
// re-rated device ends up advertising one rate while genuinely producing
// another — and since the shared ring carries frames with no clock of their
// own, the consumer then plays at the wrong speed and glitches continuously.
//
// Advertising a single rate makes that divergence impossible. coreaudiod
// resamples client audio into it exactly as it would for any fixed-rate
// interface, and the app's output unit converts to whatever the real device
// wants, so nothing is lost but a whole class of bug.
std::vector<AudioValueRange> supportedRates()
{
    return {AudioValueRange{kFadedDefaultSampleRate, kFadedDefaultSampleRate}};
}

// ---------------------------------------------------------------------------
// Shared-memory publisher
//
// Created once, at plug-in construction, and never torn down — coreaudiod owns
// the mapping for its own lifetime and the app maps it read-only whenever it
// likes. Created with 0644 so only this (root-owned) process can write to it;
// the app never needs write access because it keeps its read cursor privately.
// ---------------------------------------------------------------------------

class SharedRing {
public:
    static SharedRing& shared()
    {
        static SharedRing instance;
        return instance;
    }

    bool ok() const { return ring_ != nullptr; }

    void setSampleRate(UInt32 rate)
    {
        if (ring_) std::atomic_store_explicit(&ring_->sampleRate, rate, std::memory_order_relaxed);
    }

    void setRunning(bool running)
    {
        if (!ring_) return;
        std::atomic_store_explicit(&ring_->outputRunning, running ? 1u : 0u, std::memory_order_relaxed);
        if (running) {
            // A fresh stream: tell the reader to resynchronise rather than try
            // to play whatever stale frames are still sitting in the buffer.
            std::atomic_fetch_add_explicit(&ring_->generation, 1u, std::memory_order_relaxed);
        }
    }

    /// Real-time thread. Free-running writer: never waits, never reads the
    /// consumer's position.
    void write(const Float32* frames, UInt32 frameCount)
    {
        if (!ring_ || frameCount == 0) return;

        const uint64_t w = std::atomic_load_explicit(&ring_->writeIndex, std::memory_order_relaxed);
        const uint32_t start = static_cast<uint32_t>(w & kFadedRingMask);
        const uint32_t first = std::min(frameCount, kFadedRingFrames - start);

        std::memcpy(&ring_->samples[start * kFadedRingChannels], frames,
            sizeof(Float32) * first * kFadedRingChannels);
        if (frameCount > first) {
            std::memcpy(&ring_->samples[0], frames + first * kFadedRingChannels,
                sizeof(Float32) * (frameCount - first) * kFadedRingChannels);
        }

        // Release: everything above is visible before the reader sees the index.
        std::atomic_store_explicit(&ring_->writeIndex, w + frameCount, std::memory_order_release);
    }

    const char* status() const { return status_; }

private:
    SharedRing()
    {
        // Unlink first: a stale object from a previous load may have the wrong
        // size or ownership.
        shm_unlink(kFadedShmName);

        const int fd = shm_open(kFadedShmName, O_CREAT | O_RDWR, 0644);
        if (fd < 0) {
            std::snprintf(status_, sizeof(status_), "shm_open failed: %d (%s)", errno, std::strerror(errno));
            syslog(LOG_ERR, "FadedDriver: %s", status_);
            return;
        }
        if (ftruncate(fd, sizeof(FadedSharedRing)) != 0) {
            std::snprintf(status_, sizeof(status_), "ftruncate failed: %d (%s)", errno, std::strerror(errno));
            syslog(LOG_ERR, "FadedDriver: %s", status_);
            close(fd);
            return;
        }
        // shm_open honours umask, which would leave the app unable to read it.
        fchmod(fd, 0644);

        void* map = mmap(nullptr, sizeof(FadedSharedRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (map == MAP_FAILED) {
            std::snprintf(status_, sizeof(status_), "mmap failed: %d (%s)", errno, std::strerror(errno));
            syslog(LOG_ERR, "FadedDriver: %s", status_);
            return;
        }

        ring_ = static_cast<FadedSharedRing*>(map);
        std::memset(ring_, 0, sizeof(FadedSharedRing));
        ring_->capacityFrames = kFadedRingFrames;
        ring_->channels = kFadedRingChannels;
        ring_->version = kFadedShmVersion;
        // Magic last: the app treats it as the "fully initialised" signal.
        std::atomic_thread_fence(std::memory_order_release);
        ring_->magic = kFadedShmMagic;

        std::snprintf(status_, sizeof(status_), "ok (%zu bytes)", sizeof(FadedSharedRing));
        syslog(LOG_NOTICE, "FadedDriver: shared ring published at %s — %s", kFadedShmName, status_);
    }

    FadedSharedRing* ring_ = nullptr;
    char status_[160] = "uninitialised";
};

// ---------------------------------------------------------------------------
// Per-client state
// ---------------------------------------------------------------------------

class FadedClient : public aspl::Client {
public:
    explicit FadedClient(const aspl::ClientInfo& info)
        : aspl::Client(info)
    {
        key_ = info.BundleID.empty() ? ("pid:" + std::to_string(info.ProcessID)) : info.BundleID;
    }

    const std::string& key() const { return key_; }

    std::atomic<float> gain{1.0f};  // written on control thread, read on RT thread
    std::atomic<float> peak{0.0f};  // written on RT thread, read on control thread

private:
    std::string key_;
};

// ---------------------------------------------------------------------------
// The Faded output device
// ---------------------------------------------------------------------------

class FadedOutputDevice;

class OutputHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    void attach(std::weak_ptr<FadedOutputDevice> device) { device_ = std::move(device); }

    // -- clients (control thread) --------------------------------------

    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& info) override;
    void OnRemoveClient(std::shared_ptr<aspl::Client> client) override;

    // -- I/O lifecycle (control thread) ---------------------------------

    OSStatus OnStartIO() override;

    void publishSampleRate(UInt32 rate) { SharedRing::shared().setSampleRate(rate); }

    void OnStopIO() override
    {
        // Drop whatever cycle was still accumulating. It is at most one buffer
        // at the very end of a stream, and publishing it from a control thread
        // would race the I/O thread that owns the accumulator.
        mixFrames_ = 0;
        mixTimestamp_ = -1.0;
        SharedRing::shared().setRunning(false);
        running_.store(false, std::memory_order_relaxed);
        masterPeakL.store(0.0f, std::memory_order_relaxed);
        masterPeakR.store(0.0f, std::memory_order_relaxed);
    }

    // -- I/O (real-time thread) -----------------------------------------

    void OnProcessClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 /*timestamp*/,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
        auto* fc = static_cast<FadedClient*>(client.get());
        const float gain = fc->gain.load(std::memory_order_relaxed);
        const UInt32 n = frameCount * channelCount;

        float peak = 0.0f;
        if (gain == 1.0f) {
            for (UInt32 i = 0; i < n; ++i) {
                const float a = std::fabs(frames[i]);
                peak = a > peak ? a : peak;
            }
        } else {
            for (UInt32 i = 0; i < n; ++i) {
                frames[i] *= gain;
                const float a = std::fabs(frames[i]);
                peak = a > peak ? a : peak;
            }
        }
        // Decaying peak-hold: fast attack, ~0.9× per cycle release.
        const float prev = fc->peak.load(std::memory_order_relaxed) * 0.9f;
        fc->peak.store(peak > prev ? peak : prev, std::memory_order_relaxed);
    }

    /// Per-client output is only dispatched when EnableMixing is false, which
    /// means libASPL no longer mixes for us — this does.
    ///
    /// The HAL calls this once per client per I/O cycle, with the same
    /// `timestamp` for every client in a cycle. Clients are accumulated into a
    /// scratch buffer and the finished mix is pushed to the ring when the
    /// *next* cycle starts (or when I/O stops), which is the only moment we can
    /// know every client has contributed. That costs one cycle of latency and
    /// guarantees the reader never sees a half-mixed buffer.
    void OnWriteClientOutput(const std::shared_ptr<aspl::Client>& /*client*/,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 /*zeroTimestamp*/,
        Float64 timestamp,
        const Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
        if (channelCount != kFadedChannelCount) {
            return;
        }
        const UInt32 samples = frameCount * channelCount;
        if (samples > kMixCapacity) {
            return; // absurd buffer size; refuse rather than overrun
        }

        if (timestamp != mixTimestamp_ || frameCount != mixFrames_) {
            flushMix(stream);
            mixTimestamp_ = timestamp;
            mixFrames_ = frameCount;
            std::memset(mix_, 0, sizeof(Float32) * samples);
        }

        for (UInt32 i = 0; i < samples; ++i) {
            mix_[i] += frames[i];
        }
    }

    /// Publishes the accumulated cycle: master volume, meter, then the ring.
    /// Only ever called from the real-time thread, with the stream that is
    /// currently being served — the stream is deliberately not cached between
    /// calls, because assigning a shared_ptr on the I/O thread while a control
    /// thread clears it is a data race.
    void flushMix(const std::shared_ptr<aspl::Stream>& stream)
    {
        if (mixFrames_ == 0) {
            return;
        }
        const UInt32 frameCount = mixFrames_;
        mixFrames_ = 0;

        // libASPL applies the device's volume/mute controls through the
        // stream. With mixing disabled it never gets the chance, so do it here
        // — once, on the mix, not once per client. Skipped when the app is
        // mirroring the level onto real hardware instead.
        if (stream && !bypassMaster.load(std::memory_order_relaxed)) {
            stream->ApplyProcessing(mix_, frameCount, kFadedChannelCount);
        }

        float pl = 0.0f, pr = 0.0f;
        for (UInt32 i = 0; i < frameCount; ++i) {
            const float l = std::fabs(mix_[i * 2]);
            const float r = std::fabs(mix_[i * 2 + 1]);
            pl = l > pl ? l : pl;
            pr = r > pr ? r : pr;
        }
        const float prevL = masterPeakL.load(std::memory_order_relaxed) * 0.85f;
        const float prevR = masterPeakR.load(std::memory_order_relaxed) * 0.85f;
        masterPeakL.store(pl > prevL ? pl : prevL, std::memory_order_relaxed);
        masterPeakR.store(pr > prevR ? pr : prevR, std::memory_order_relaxed);

        SharedRing::shared().write(mix_, frameCount);
    }

    // -- app-facing state ---------------------------------------------

    std::atomic<bool> bypassMaster{false};
    bool isRunning() const { return running_.load(std::memory_order_relaxed); }

    // Master output meter, written on the RT thread, read by the app via
    // kFadedProp_Stats. Decaying peak-hold, same shape as the per-client one.
    std::atomic<float> masterPeakL{0.0f};
    std::atomic<float> masterPeakR{0.0f};

    // Per-app gains keyed by bundle id (or "pid:N"). Control thread only.
    std::mutex gainsMutex;
    std::map<std::string, float> gains;

private:
    // Cycle accumulator for our own mixing. Real-time thread only, so plain
    // members: the HAL serialises the per-client calls within a cycle.
    static constexpr UInt32 kMixCapacity = 8192 * kFadedChannelCount;
    Float32 mix_[kMixCapacity] = {};
    Float64 mixTimestamp_ = -1.0;
    UInt32 mixFrames_ = 0;

    std::weak_ptr<FadedOutputDevice> device_;
    std::atomic<bool> running_{false};
};

class FadedOutputDevice : public aspl::Device {
public:
    FadedOutputDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& params,
        std::shared_ptr<OutputHandler> handler)
        : aspl::Device(std::move(context), params)
        , handler_(std::move(handler))
    {
        SetControlHandler(handler_);
        SetIOHandler(handler_);

        RegisterCustomProperty(kFadedProp_Version,
            [] { return makeCFString(kFadedProtocolVersion); });

        RegisterCustomProperty(kFadedProp_Clients,
            std::function<CFPropertyListRef()>([this] { return copyClientList(); }),
            std::function<void(CFPropertyListRef)>{});

        RegisterCustomProperty(kFadedProp_AppGains,
            std::function<CFPropertyListRef()>([this] { return copyAppGains(); }),
            std::function<void(CFPropertyListRef)>([this](CFPropertyListRef v) { setAppGains(v); }));

        RegisterCustomProperty(kFadedProp_BypassMaster,
            std::function<CFPropertyListRef()>([this] {
                CFBooleanRef b = handler_->bypassMaster.load() ? kCFBooleanTrue : kCFBooleanFalse;
                CFRetain(b);
                return static_cast<CFPropertyListRef>(b);
            }),
            std::function<void(CFPropertyListRef)>([this](CFPropertyListRef v) {
                if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
                    handler_->bypassMaster.store(CFBooleanGetValue(static_cast<CFBooleanRef>(v)));
                    NotifyPropertyChanged(kFadedProp_BypassMaster);
                }
            }));

        RegisterCustomProperty(kFadedProp_HideOutput,
            std::function<CFPropertyListRef()>([this] {
                CFBooleanRef b = GetIsHidden() ? kCFBooleanTrue : kCFBooleanFalse;
                CFRetain(b);
                return static_cast<CFPropertyListRef>(b);
            }),
            std::function<void(CFPropertyListRef)>([this](CFPropertyListRef v) {
                if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
                    SetIsHidden(CFBooleanGetValue(static_cast<CFBooleanRef>(v)));
                    NotifyPropertyChanged(kFadedProp_HideOutput);
                }
            }));

        RegisterCustomProperty(kFadedProp_DisplayName,
            std::function<CFStringRef()>([this] { return makeCFString(GetName()); }),
            std::function<void(CFStringRef)>([this](CFStringRef v) {
                if (!v) return;
                {
                    std::lock_guard<std::mutex> lock(nameMutex_);
                    const std::string next = toStdString(v);
                    if (next.empty() || next == displayName_) return;
                    displayName_ = next;
                }
                // Both: the name itself, and our own property so a second
                // client can observe the change.
                NotifyPropertyChanged(kAudioObjectPropertyName);
                NotifyPropertyChanged(kFadedProp_DisplayName);
            }));

        RegisterCustomProperty(kFadedProp_Stats,
            std::function<CFPropertyListRef()>([this] { return copyStats(); }),
            std::function<void(CFPropertyListRef)>{});
    }

    // Called by the handler when clients come and go.
    void clientsChanged() { NotifyPropertyChanged(kFadedProp_Clients); }

    //! The ring carries no timing information, so the consumer has to be told
    //! what rate the frames are being produced at. coreaudiod re-rates this
    //! device to match whatever its clients want, so publishing the rate once
    //! at construction is not enough: a device running at 44.1 kHz while the
    //! app plays out at 48 kHz drains the ring ~9% too fast, which sounds like
    //! continuous glitching. Publish it on every change.
    OSStatus SetNominalSampleRateImpl(Float64 rate) override
    {
        const OSStatus status = aspl::Device::SetNominalSampleRateImpl(rate);
        // Whatever the nominal rate ends up saying, publish the rate frames are
        // genuinely produced at — the stream's. Only one rate is advertised, so
        // in practice these always agree; this is here so that if they ever
        // diverge again the consumer still hears the truth rather than a
        // property that lies.
        publishCurrentSampleRate();
        return status;
    }

    //! Belt and braces: whatever the rate is when I/O starts is what the app
    //! must open its output at.
    void publishCurrentSampleRate()
    {
        // Deliberately the *stream's* rate, not GetNominalSampleRate(): the
        // stream format is what coreaudiod clocks I/O from, so it is the rate
        // frames genuinely arrive at. The two should now always agree, and if
        // they ever diverge again the stream is the one telling the truth.
        Float64 rate = GetNominalSampleRate();
        if (auto stream = GetStreamByIndex(aspl::Direction::Output, 0)) {
            const Float64 streamRate = stream->GetPhysicalFormat().mSampleRate;
            if (streamRate > 0) {
                rate = streamRate;
            }
        }
        SharedRing::shared().setSampleRate(static_cast<UInt32>(rate));
    }

    //! Reports whatever Faded.app last set, so the system volume HUD names the
    //! real speakers instead of this device. Invoked by HAL on control threads.
    std::string GetName() const override
    {
        std::lock_guard<std::mutex> lock(nameMutex_);
        return displayName_;
    }

    // Look up the stored gain for a client key (control thread).
    float gainFor(const std::string& key)
    {
        std::lock_guard<std::mutex> lock(handler_->gainsMutex);
        auto it = handler_->gains.find(key);
        return it == handler_->gains.end() ? 1.0f : it->second;
    }

private:
    CFPropertyListRef copyClientList()
    {
        CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        for (const auto& c : GetClients()) {
            auto* fc = static_cast<FadedClient*>(c.get());
            CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            dictSet(d, "pid", makeCFNumber(static_cast<long long>(fc->GetProcessID())));
            dictSet(d, "client", makeCFNumber(static_cast<long long>(fc->GetClientID())));
            dictSet(d, "bundle", makeCFString(fc->GetBundleID()));
            dictSet(d, "key", makeCFString(fc->key()));
            dictSet(d, "gain", makeCFNumber(static_cast<double>(fc->gain.load())));
            dictSet(d, "peak", makeCFNumber(static_cast<double>(fc->peak.load())));
            CFArrayAppendValue(arr, d);
            CFRelease(d);
        }
        return arr;
    }

    CFPropertyListRef copyAppGains()
    {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        std::lock_guard<std::mutex> lock(handler_->gainsMutex);
        for (const auto& [key, gain] : handler_->gains) {
            CFStringRef k = makeCFString(key);
            CFNumberRef v = makeCFNumber(static_cast<double>(gain));
            CFDictionarySetValue(d, k, v);
            CFRelease(k);
            CFRelease(v);
        }
        return d;
    }

    void setAppGains(CFPropertyListRef value)
    {
        if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
            return;
        }
        auto dict = static_cast<CFDictionaryRef>(value);
        std::map<std::string, float> next;

        const CFIndex n = CFDictionaryGetCount(dict);
        std::vector<const void*> keys(static_cast<size_t>(n)), vals(static_cast<size_t>(n));
        CFDictionaryGetKeysAndValues(dict, keys.data(), vals.data());
        for (CFIndex i = 0; i < n; ++i) {
            auto k = static_cast<CFTypeRef>(keys[static_cast<size_t>(i)]);
            auto v = static_cast<CFTypeRef>(vals[static_cast<size_t>(i)]);
            if (CFGetTypeID(k) != CFStringGetTypeID() || CFGetTypeID(v) != CFNumberGetTypeID()) {
                continue;
            }
            double g = 1.0;
            CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberDoubleType, &g);
            g = std::fmax(0.0, std::fmin(1.0, g));
            next[toStdString(static_cast<CFStringRef>(k))] = static_cast<float>(g);
        }

        {
            std::lock_guard<std::mutex> lock(handler_->gainsMutex);
            handler_->gains = std::move(next);
        }
        // Push onto live clients.
        for (const auto& c : GetClients()) {
            auto* fc = static_cast<FadedClient*>(c.get());
            fc->gain.store(gainFor(fc->key()), std::memory_order_relaxed);
        }
        NotifyPropertyChanged(kFadedProp_AppGains);
    }

    CFPropertyListRef copyStats()
    {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        dictSet(d, "sampleRate", makeCFNumber(GetNominalSampleRate()));
        dictSet(d, "clients", makeCFNumber(static_cast<long long>(GetClientCount())));
        dictSet(d, "peakL", makeCFNumber(static_cast<double>(handler_->masterPeakL.load())));
        dictSet(d, "peakR", makeCFNumber(static_cast<double>(handler_->masterPeakR.load())));
        dictSet(d, "sharedRing", makeCFString(SharedRing::shared().status()));
        CFBooleanRef out = handler_->isRunning() ? kCFBooleanTrue : kCFBooleanFalse;
        CFRetain(out);
        dictSet(d, "outputRunning", out);
        return d;
    }

    std::shared_ptr<OutputHandler> handler_;
    mutable std::mutex nameMutex_;
    std::string displayName_ = kFadedOutputDeviceName;
};

OSStatus OutputHandler::OnStartIO()
{
    // Publish the rate the device is actually running at before any frames are
    // written, so the app opens its output to match.
    if (auto dev = device_.lock()) {
        dev->publishCurrentSampleRate();
    }
    mixTimestamp_ = -1.0;
    mixFrames_ = 0;
    SharedRing::shared().setRunning(true);
    running_.store(true, std::memory_order_relaxed);
    return kAudioHardwareNoError;
}

std::shared_ptr<aspl::Client> OutputHandler::OnAddClient(const aspl::ClientInfo& info)
{
    auto client = std::make_shared<FadedClient>(info);
    if (auto dev = device_.lock()) {
        client->gain.store(dev->gainFor(client->key()), std::memory_order_relaxed);
        dev->clientsChanged();
    }
    return client;
}

void OutputHandler::OnRemoveClient(std::shared_ptr<aspl::Client> /*client*/)
{
    if (auto dev = device_.lock()) {
        dev->clientsChanged();
    }
}

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

std::shared_ptr<aspl::Driver> CreateFadedDriver()
{
#ifdef FADED_DEBUG_TRACE
    auto tracer = std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Syslog, aspl::Tracer::Style::Flat);
#else
    auto tracer = std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop);
#endif
    auto context = std::make_shared<aspl::Context>(tracer);

    // ---- Faded (output) ----
    aspl::DeviceParameters outParams;
    outParams.Name = kFadedOutputDeviceName;
    outParams.Manufacturer = kFadedManufacturer;
    outParams.DeviceUID = kFadedOutputDeviceUID;
    outParams.ModelUID = kFadedModelUID;
    outParams.ConfigurationApplicationBundleID = kFadedAppBundleID;
    outParams.CanBeDefault = true;
    outParams.CanBeDefaultForSystemSounds = true;
    outParams.SampleRate = kFadedDefaultSampleRate;
    outParams.ChannelCount = kFadedChannelCount;
    // False, deliberately. With mixing enabled libASPL declines the HAL's
    // per-client "MixOutput" operation entirely, which is the only place
    // OnProcessClientOutput is dispatched from — so per-app gain was never
    // applied and every client's peak stayed at zero, leaving the Apps list
    // permanently empty. Taking the per-client callbacks means mixing the
    // clients together ourselves; see OnWriteClientOutput.
    outParams.EnableMixing = false;
    // Report a small, honest latency so apps' A/V sync accounts for the hop
    // through the app. Real total ≈ FIFO prime + two AUHAL buffers.
    outParams.Latency = 512;
    outParams.SafetyOffset = 64;
    outParams.ZeroTimeStampPeriod = 512;

    // Touch the singleton early so the ring exists (and its status is logged)
    // before any I/O starts.
    SharedRing::shared().setSampleRate(kFadedDefaultSampleRate);

    auto outHandler = std::make_shared<OutputHandler>();
    auto outDevice = std::make_shared<FadedOutputDevice>(context, outParams, outHandler);
    outHandler->attach(outDevice);

    aspl::StreamParameters outStream;
    outStream.Direction = aspl::Direction::Output;
    outStream.Format = floatFormat(kFadedDefaultSampleRate);
    outDevice->AddStreamWithControlsAsync(outStream); // stream + volume + mute
    outDevice->SetAvailableSampleRatesAsync(supportedRates());

    // ---- plug-in ----
    aspl::PluginParameters pluginParams;
    pluginParams.Manufacturer = kFadedManufacturer;
    pluginParams.ResourceBundlePath = "";
    auto plugin = std::make_shared<aspl::Plugin>(context, pluginParams);
    plugin->AddDevice(outDevice);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" __attribute__((visibility("default"))) void* FadedDriverEntryPoint(CFAllocatorRef /*allocator*/, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateFadedDriver();
    return driver->GetReference();
}
