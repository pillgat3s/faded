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
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "FadedFIFO.hpp"
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

std::vector<AudioValueRange> supportedRates()
{
    auto r = [](double v) { return AudioValueRange{v, v}; };
    return {r(kFadedSampleRate44k), r(kFadedSampleRate48k), r(kFadedSampleRate88k), r(kFadedSampleRate96k)};
}

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

    OSStatus OnStartIO() override
    {
        faded::FIFO::shared().reset();
        running_.store(true, std::memory_order_relaxed);
        return kAudioHardwareNoError;
    }

    void OnStopIO() override
    {
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

    void OnProcessMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 /*zeroTimestamp*/,
        Float64 /*timestamp*/,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
        // When bypassed, Faded.app mirrors the volume/mute controls onto the
        // real device's hardware gain instead, so we must NOT attenuate here.
        if (!bypassMaster.load(std::memory_order_relaxed)) {
            stream->ApplyProcessing(frames, frameCount, channelCount);
        }
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 /*timestamp*/,
        const void* bytes,
        UInt32 bytesCount) override
    {
        const auto* frames = static_cast<const Float32*>(bytes);
        const UInt32 frameCount = bytesCount / (sizeof(Float32) * kFadedChannelCount);

        float pl = 0.0f, pr = 0.0f;
        for (UInt32 i = 0; i < frameCount; ++i) {
            const float l = std::fabs(frames[i * 2]);
            const float r = std::fabs(frames[i * 2 + 1]);
            pl = l > pl ? l : pl;
            pr = r > pr ? r : pr;
        }
        const float prevL = masterPeakL.load(std::memory_order_relaxed) * 0.85f;
        const float prevR = masterPeakR.load(std::memory_order_relaxed) * 0.85f;
        masterPeakL.store(pl > prevL ? pl : prevL, std::memory_order_relaxed);
        masterPeakR.store(pr > prevR ? pr : prevR, std::memory_order_relaxed);

        faded::FIFO::shared().write(frames, frameCount);
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

        RegisterCustomProperty(kFadedProp_Stats,
            std::function<CFPropertyListRef()>([this] { return copyStats(); }),
            std::function<void(CFPropertyListRef)>{});
    }

    // Called by the handler when clients come and go.
    void clientsChanged() { NotifyPropertyChanged(kFadedProp_Clients); }

    // Look up the stored gain for a client key (control thread).
    float gainFor(const std::string& key)
    {
        std::lock_guard<std::mutex> lock(handler_->gainsMutex);
        auto it = handler_->gains.find(key);
        return it == handler_->gains.end() ? 1.0f : it->second;
    }

    void setTapRunning(std::atomic<bool>* flag) { tapRunning_ = flag; }

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
        auto& fifo = faded::FIFO::shared();
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        dictSet(d, "fifoFrames", makeCFNumber(static_cast<long long>(fifo.availableFrames())));
        dictSet(d, "underruns", makeCFNumber(static_cast<long long>(fifo.underruns())));
        dictSet(d, "overruns", makeCFNumber(static_cast<long long>(fifo.overruns())));
        dictSet(d, "trims", makeCFNumber(static_cast<long long>(fifo.trims())));
        dictSet(d, "sampleRate", makeCFNumber(GetNominalSampleRate()));
        dictSet(d, "clients", makeCFNumber(static_cast<long long>(GetClientCount())));
        dictSet(d, "peakL", makeCFNumber(static_cast<double>(handler_->masterPeakL.load())));
        dictSet(d, "peakR", makeCFNumber(static_cast<double>(handler_->masterPeakR.load())));
        CFBooleanRef out = handler_->isRunning() ? kCFBooleanTrue : kCFBooleanFalse;
        CFRetain(out);
        dictSet(d, "outputRunning", out);
        CFBooleanRef tap = (tapRunning_ && tapRunning_->load()) ? kCFBooleanTrue : kCFBooleanFalse;
        CFRetain(tap);
        dictSet(d, "tapRunning", tap);
        return d;
    }

    std::shared_ptr<OutputHandler> handler_;
    std::atomic<bool>* tapRunning_ = nullptr;
};

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
// The hidden Tap input device
// ---------------------------------------------------------------------------

class TapHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override
    {
        running.store(true, std::memory_order_relaxed);
        return kAudioHardwareNoError;
    }
    void OnStopIO() override { running.store(false, std::memory_order_relaxed); }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& /*client*/,
        const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 /*timestamp*/,
        void* bytes,
        UInt32 bytesCount) override
    {
        faded::FIFO::shared().read(static_cast<float*>(bytes),
            bytesCount / (sizeof(Float32) * kFadedChannelCount));
    }

    std::atomic<bool> running{false};
};

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
    outParams.EnableMixing = true;
    // Report a small, honest latency so apps' A/V sync accounts for the hop
    // through the app. Real total ≈ FIFO prime + two AUHAL buffers.
    outParams.Latency = 512;
    outParams.SafetyOffset = 64;
    outParams.ZeroTimeStampPeriod = 512;

    auto outHandler = std::make_shared<OutputHandler>();
    auto outDevice = std::make_shared<FadedOutputDevice>(context, outParams, outHandler);
    outHandler->attach(outDevice);

    aspl::StreamParameters outStream;
    outStream.Direction = aspl::Direction::Output;
    outStream.Format = floatFormat(kFadedDefaultSampleRate);
    outDevice->AddStreamWithControlsAsync(outStream); // stream + volume + mute
    outDevice->SetAvailableSampleRatesAsync(supportedRates());

    // ---- Faded Tap (input, hidden) ----
    aspl::DeviceParameters tapParams;
    tapParams.Name = kFadedTapDeviceName;
    tapParams.Manufacturer = kFadedManufacturer;
    tapParams.DeviceUID = kFadedTapDeviceUID;
    tapParams.ModelUID = kFadedModelUID;
    tapParams.CanBeDefault = false;
    tapParams.CanBeDefaultForSystemSounds = false;
    tapParams.SampleRate = kFadedDefaultSampleRate;
    tapParams.ChannelCount = kFadedChannelCount;
    tapParams.EnableMixing = false;
    tapParams.SafetyOffset = 64;
    tapParams.ZeroTimeStampPeriod = 512;

    auto tapHandler = std::make_shared<TapHandler>();
    auto tapDevice = std::make_shared<aspl::Device>(context, tapParams);
    tapDevice->SetControlHandler(tapHandler);
    tapDevice->SetIOHandler(tapHandler);

    aspl::StreamParameters tapStream;
    tapStream.Direction = aspl::Direction::Input;
    tapStream.Format = floatFormat(kFadedDefaultSampleRate);
    tapDevice->AddStreamAsync(tapStream);
    tapDevice->SetAvailableSampleRatesAsync(supportedRates());
#ifndef FADED_TAP_VISIBLE
    tapDevice->SetIsHidden(true);
#endif

    outDevice->setTapRunning(&tapHandler->running);

    // ---- plug-in ----
    aspl::PluginParameters pluginParams;
    pluginParams.Manufacturer = kFadedManufacturer;
    pluginParams.ResourceBundlePath = "";
    auto plugin = std::make_shared<aspl::Plugin>(context, pluginParams);
    plugin->AddDevice(outDevice);
    plugin->AddDevice(tapDevice);

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
