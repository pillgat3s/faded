// FaderProtocol.h — the contract between FaderDriver (HAL plug-in) and Fader.app.
//
// Plain C so it can be included from C++ (driver) and imported into Swift
// (via the app's bridging/module map). Keep this file dependency-free.
//
// Everything the app needs to talk to the driver goes through *custom
// properties* on the "Fader" output device object. Custom properties are the
// sanctioned AudioServerPlugIn channel for app<->driver control: no sockets,
// no XPC, no shared memory — just AudioObjectGetPropertyData/SetPropertyData
// with CFPropertyList payloads. See kFaderProp_* below.

#ifndef FADER_PROTOCOL_H
#define FADER_PROTOCOL_H

#include <CoreAudio/AudioHardwareBase.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Device identity
// ---------------------------------------------------------------------------

// The visible output device apps play into. Has a volume + mute control so
// the native Sound slider and the keyboard volume keys drive it.
#define kFaderOutputDeviceUID       "com.andri.fader.output"
#define kFaderOutputDeviceName      "Fader"

// The hidden input device Fader.app reads the mixed output back from.
// Hidden => not listed in Sound settings / Discord / anything, but the app
// can still resolve it by UID (kAudioHardwarePropertyTranslateUIDToDevice).
#define kFaderTapDeviceUID          "com.andri.fader.tap"
#define kFaderTapDeviceName         "Fader Tap"

#define kFaderManufacturer          "andri"
#define kFaderModelUID              "com.andri.fader"

// Bundle id of the app that owns the driver (used for
// kAudioDevicePropertyConfigurationApplication so "Configure device…" in
// Audio MIDI Setup opens Fader.app).
#define kFaderAppBundleID           "com.andri.fader"

// ---------------------------------------------------------------------------
// Audio format
// ---------------------------------------------------------------------------

#define kFaderChannelCount          2
#define kFaderDefaultSampleRate     48000
// Sample rates the Fader device advertises. The app switches the device to
// whatever the *target* (real) output runs at, so the play-through path never
// resamples.
#define kFaderSampleRate44k         44100
#define kFaderSampleRate48k         48000
#define kFaderSampleRate88k         88200
#define kFaderSampleRate96k         96000

// ---------------------------------------------------------------------------
// Custom properties on the Fader output device object
// (scope = kAudioObjectPropertyScopeGlobal, element = main)
// ---------------------------------------------------------------------------

// 'fcli' — READ ONLY, CFPropertyList (CFArray of CFDictionary)
//   Every client (process) currently attached to the Fader device.
//   Each entry: { "pid": CFNumber, "bundle": CFString, "client": CFNumber,
//                 "gain": CFNumber(float), "peak": CFNumber(float 0..1) }
//   The driver fires a property-changed notification for this selector when
//   clients attach/detach, so the app can listen instead of polling.
//   ("peak" is a decaying peak meter; poll ~10 Hz if you want live meters.)
#define kFaderProp_Clients          'fcli'

// 'fapv' — READ/WRITE, CFPropertyList (CFDictionary bundleID -> CFNumber gain)
//   Per-app gain, keyed by bundle id. Range 0.0 … 2.0 (1.0 = unity, >1 boost).
//   Missing key == 1.0. Applies to current AND future clients with that
//   bundle id. Setting replaces the whole map (send the full dictionary).
//   Clients with an empty bundle id (rare: raw CLI processes) are keyed by
//   "pid:<pid>" instead.
#define kFaderProp_AppGains         'fapv'

// 'fbyp' — READ/WRITE, CFPropertyList (CFBoolean)
//   Master-volume bypass. When TRUE the driver does NOT apply its own volume
//   and mute controls to the mixed output — the app mirrors the Fader
//   control's value onto the *real* device's hardware volume instead (so
//   built-in speakers / AirPods keep using their native gain stage and we
//   never attenuate twice). When FALSE (target has no hardware volume, e.g.
//   the Astro A50 base station) the driver applies the volume in software.
#define kFaderProp_BypassMaster     'fbyp'

// 'fhid' — READ/WRITE, CFPropertyList (CFBoolean)
//   Experimental. When TRUE the Fader output device sets
//   kAudioDevicePropertyIsHidden, so it disappears from Sound settings /
//   Control Center / app device pickers. Fader.app can still address it by
//   UID. Whether macOS accepts a hidden device as *default output* is what
//   tomorrow's test decides; the app falls back to visible if it doesn't.
#define kFaderProp_HideOutput       'fhid'

// 'fver' — READ ONLY, CFString
//   Driver protocol version, e.g. "1". App refuses to drive an incompatible
//   driver and offers reinstall.
#define kFaderProp_Version          'fver'
#define kFaderProtocolVersion       "1"

// 'fsta' — READ ONLY, CFPropertyList (CFDictionary)
//   Diagnostics: { "fifoFrames": CFNumber, "underruns": CFNumber,
//                  "overruns": CFNumber, "outputRunning": CFBoolean,
//                  "tapRunning": CFBoolean, "sampleRate": CFNumber }
#define kFaderProp_Stats            'fsta'

#ifdef __cplusplus
}
#endif

#endif // FADER_PROTOCOL_H
