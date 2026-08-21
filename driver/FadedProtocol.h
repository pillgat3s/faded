// FadedProtocol.h — the contract between FadedDriver (HAL plug-in) and Faded.app.
//
// Plain C so it can be included from C++ (driver) and imported into Swift
// (via the app's bridging/module map). Keep this file dependency-free.
//
// Everything the app needs to talk to the driver goes through *custom
// properties* on the "Faded" output device object. Custom properties are the
// sanctioned AudioServerPlugIn channel for app<->driver control: no sockets,
// no XPC, no shared memory — just AudioObjectGetPropertyData/SetPropertyData
// with CFPropertyList payloads. See kFadedProp_* below.

#ifndef FADED_PROTOCOL_H
#define FADED_PROTOCOL_H

#include <CoreAudio/AudioHardwareBase.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Device identity
// ---------------------------------------------------------------------------

// The visible output device apps play into. Has a volume + mute control so
// the native Sound slider and the keyboard volume keys drive it.
#define kFadedOutputDeviceUID       "com.andri.faded.output"
#define kFadedOutputDeviceName      "Faded"

// PROTOCOL 2 REMOVED THE TAP DEVICE.
//
// v1 exposed a second, hidden *input* device that the app read the mixed output
// back from. It worked, but macOS lights the orange microphone indicator for
// any process holding an audio input stream and makes no distinction between a
// hidden virtual device and a real microphone — so the indicator was lit
// whenever Faded routed audio. The audio now travels through shared memory
// instead (see FadedShared.h) and no input device exists at all.

#define kFadedManufacturer          "andri"
#define kFadedModelUID              "com.andri.faded"

// Bundle id of the app that owns the driver (used for
// kAudioDevicePropertyConfigurationApplication so "Configure device…" in
// Audio MIDI Setup opens Faded.app).
#define kFadedAppBundleID           "com.andri.faded"

// ---------------------------------------------------------------------------
// Audio format
// ---------------------------------------------------------------------------

#define kFadedChannelCount          2
#define kFadedDefaultSampleRate     48000
// Sample rates the Faded device advertises. The app switches the device to
// whatever the *target* (real) output runs at, so the play-through path never
// resamples.
#define kFadedSampleRate44k         44100
#define kFadedSampleRate48k         48000
#define kFadedSampleRate88k         88200
#define kFadedSampleRate96k         96000

// ---------------------------------------------------------------------------
// Custom properties on the Faded output device object
// (scope = kAudioObjectPropertyScopeGlobal, element = main)
// ---------------------------------------------------------------------------

// 'fcli' — READ ONLY, CFPropertyList (CFArray of CFDictionary)
//   Every client (process) currently attached to the Faded device.
//   Each entry: { "pid": CFNumber, "bundle": CFString, "client": CFNumber,
//                 "gain": CFNumber(float), "peak": CFNumber(float 0..1) }
//   The driver fires a property-changed notification for this selector when
//   clients attach/detach, so the app can listen instead of polling.
//   ("peak" is a decaying peak meter; poll ~10 Hz if you want live meters.)
#define kFadedProp_Clients          'fcli'

// 'fapv' — READ/WRITE, CFPropertyList (CFDictionary bundleID -> CFNumber gain)
//   Per-app gain, keyed by bundle id. Range 0.0 … 1.0 (1.0 = unity).
//   No boost — attenuation only, so nothing can clip.
//   Missing key == 1.0. Applies to current AND future clients with that
//   bundle id. Setting replaces the whole map (send the full dictionary).
//   Clients with an empty bundle id (rare: raw CLI processes) are keyed by
//   "pid:<pid>" instead.
#define kFadedProp_AppGains         'fapv'

// 'fbyp' — READ/WRITE, CFPropertyList (CFBoolean)
//   Master-volume bypass. When TRUE the driver does NOT apply its own volume
//   and mute controls to the mixed output — the app mirrors the Faded
//   control's value onto the *real* device's hardware volume instead (so
//   built-in speakers / AirPods keep using their native gain stage and we
//   never attenuate twice). When FALSE (target has no hardware volume, e.g.
//   the Astro A50 base station) the driver applies the volume in software.
#define kFadedProp_BypassMaster     'fbyp'

// 'fhid' — READ/WRITE, CFPropertyList (CFBoolean)
//   Experimental. When TRUE the Faded output device sets
//   kAudioDevicePropertyIsHidden, so it disappears from Sound settings /
//   Control Center / app device pickers. Faded.app can still address it by
//   UID. Whether macOS accepts a hidden device as *default output* is what
//   tomorrow's test decides; the app falls back to visible if it doesn't.
#define kFadedProp_HideOutput       'fhid'

// 'fnam' — READ/WRITE, CFString
//   Display name the Faded device reports as kAudioObjectPropertyName.
//   Faded.app keeps this set to the name of the device it is currently playing
//   to, so macOS's own volume HUD, Sound settings and Control Center all name
//   the speakers you are actually listening on rather than saying "Faded".
//   Setting it fires a property-changed notification for the name so those UIs
//   refresh immediately. Reset to "Faded" when nothing is being routed.
#define kFadedProp_DisplayName      'fnam'

// 'fver' — READ ONLY, CFString
//   Driver protocol version, e.g. "1". App refuses to drive an incompatible
//   driver and offers reinstall.
#define kFadedProp_Version          'fver'
#define kFadedProtocolVersion       "3"

// 'fsta' — READ ONLY, CFPropertyList (CFDictionary)
//   Diagnostics AND the master output meter (polled ~15 Hz while the menu is
//   open): { "fifoFrames", "underruns", "overruns", "trims", "sampleRate",
//   "clients", "outputRunning", "tapRunning",
//     "peakL": CFNumber(0..1), "peakR": CFNumber(0..1) }
//   peakL/peakR are decaying peak-hold values of the final mixed output.
#define kFadedProp_Stats            'fsta'

#ifdef __cplusplus
}
#endif

#endif // FADED_PROTOCOL_H
