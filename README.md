# Faded

A personal macOS menu bar sound control, shaped like the stock Control Center
Sound module but with the parts SoundSource has and macOS doesn't:

- **Volume keys work on every output device** — including ones with no volume
  control of their own (Astro A50 base station, HDMI/DisplayPort, most USB DACs).
- **Per-app volume and mute**, with a **star** to pin the apps you always want
  to see. Everything else stays behind a dropdown.
- **Output *and* input devices in one panel**, with input volume/mute.
- **Level meters** to the left of each device and app, the way SoundSource
  shows them.
- **Hide devices** you never use; they collapse behind "Show More".
- Clean Settings window, launch at login.

Deliberately **not** included: boost above 100 %, sample-rate switching,
balance, an equalizer, per-app device redirection.

**Status: built and compiling clean. Not yet run against real audio hardware —
the checklist at the bottom is the first live test.**

---

## How it works

macOS has two ways to sit between apps and a speaker: Rogue Amoeba's
proprietary ARK engine, or a virtual audio device. Faded is a virtual device,
designed around the failure modes of the usual ones (fake microphones showing
up in Discord, device switching breaking when AirPods connect).

```
                  ┌──────── FadedDriver.driver (HAL plug-in, inside coreaudiod) ────────┐
 Spotify ─┐       │  "Faded"  (visible OUTPUT device)          "Faded Tap"  (HIDDEN in) │
 Discord ─┼─ into ▶  per-app gain ▸ mix ▸ volume/mute ▸ FIFO ───────────▶ read back     │
 Safari  ─┘       │  (has volume+mute controls ⇒ F11/F12 drive it)                      │
                  └───────────────────────────────────────────────┬────────────────────┘
                                                                  ▼  AUHAL in
                                                       Faded.app  RingBuffer
                                                                  ▼  AUHAL out
                                          Astro A50 / speakers / AirPods / USB DAC
```

**Volume keys.** The "Faded" device declares a real volume + mute control, so
macOS drives it from the keyboard and the Sound slider like any other device.
If the *real* target has hardware volume, Faded mirrors the value onto it and
tells the driver to bypass its own gain (no double attenuation — and AirPods
stem gestures still sync back). If it doesn't, the driver applies the gain in
software. Either way F11/F12 work.

**No fake microphone.** The readback device is `kAudioDevicePropertyIsHidden`;
Faded resolves it by UID and nothing else lists it. Input is not interposed at
all — Faded just selects the system input device and drives its hardware
volume/mute directly, so no app ever sees anything unusual in its mic list.

**Per-app volume.** The AudioServerPlugIn API hands the driver each client's
buffer *before* mixing, with its pid and bundle id. Gain is applied there.
Helper processes (Chrome Helper, WebKit GPU, Discord Helper) are resolved back
to their owning app for the UI.

**Meters.** Output level comes free from the driver (it already has the mixed
buffer). Input level has no equivalent property anywhere in CoreAudio, so it
requires opening a capture unit — Faded does that only while the menu is open,
measures the peak and discards the samples immediately. Bluetooth inputs are
deliberately skipped: capturing from them forces the A2DP→HFP profile switch
that wrecks playback quality.

### AirPlay — read this

**AirPlay speakers are not CoreAudio devices.** Verified on this machine: with
a Sonos and an Apple TV visible in the stock Sound menu, neither appears in the
HAL device list. macOS routes AirPlay above the HAL, through a private path.

So Faded cannot list them, and cannot play to them. What it does instead is
**step aside**: when the system default output moves to something Faded can't
adopt, it disengages rather than fighting for the default (which would yank you
straight back off your AirPlay speaker). The menu says "macOS is routing audio
directly. Faded is standing by." When an adoptable device becomes the default
again, Faded re-engages by itself.

Practical result: pick AirPlay in Control Center exactly like you do now, and
it behaves exactly like it does now — Faded gets out of the way. You lose
per-app volume for that period, because nothing of ours is in the path.

*(Open question for the live test: it is possible macOS materialises a
transient CoreAudio device with transport type `airplay` while an AirPlay
target is active — the constant exists. If it does, Faded will simply adopt it
like any other device and everything keeps working. Step 8 of the checklist
settles it.)*

### Components

| Path | What |
|---|---|
| `driver/` | C++17 HAL plug-in on [libASPL](https://github.com/gavv/libASPL) (MIT, vendored). `Driver.cpp` = Faded logic, `FadedFIFO.hpp` = lock-free SPSC ring, `FadedProtocol.h` = app↔driver contract |
| `app/Sources/Faded/CoreAudio` | typed wrappers over the HAL C API, output + input |
| `app/Sources/Faded/Driver` | driver discovery, custom-property protocol, installer (admin prompt) |
| `app/Sources/Faded/Engine` | `PlayThrough` (two AUHAL units + ring), `InputMeter`, `AudioRouter` (the brain), `ProcessResolver` (pid → app) |
| `app/Sources/Faded/UI` | `Controls` (slider, meter, badge), `MenuView`, `SettingsView` |
| `scripts/` | icon generator, driver install/uninstall, protocol consistency check |

App ↔ driver protocol = custom properties on the Faded device: `'fcli'` clients
+ per-app peaks, `'fapv'` per-app gains, `'fbyp'` master bypass, `'fhid'` hide
device, `'fsta'` stats + master meter, `'fver'` version.

---

## Build

Requirements: Xcode 26, `brew install cmake xcodegen`.

```bash
make            # driver + app → build/Faded.app
make driver     # just the .driver
make app        # just the app (embeds the driver)
make clean
```

### Looking at the UI without installing anything

Debug builds can rasterise the menu to a PNG — no driver, no audio touched:

```bash
./app/build/Build/Products/Debug/Faded.app/Contents/MacOS/Faded --render-menu /tmp/menu.png --expanded
```

(The Settings window can't be rendered this way — `TabView` and grouped `Form`
are AppKit-backed and come out blank. Open it for real instead.)

## Install / first run

```bash
make install    # copies build/Faded.app → /Applications and opens it
```

Menu bar speaker → **Install Driver…** → admin password → coreaudiod restarts
(~1 s of silence) → Faded engages on whatever device you were already using.

Manual driver install without the app: `make install-driver` (sudo).

## Uninstall

`make uninstall` — quits the app, removes `/Applications/Faded.app`, the driver
in `/Library/Audio/Plug-Ins/HAL/`, prefs, and restarts coreaudiod. Or in-app:
Settings → General → Uninstall.

---

## Known limitations

- **If Faded.app isn't running while the driver is installed and "Faded" is the
  default output, audio is silent** (nothing drains the FIFO). Faded restores
  the real device on quit; it can't on a crash. Next launch fixes it. Turn on
  Launch at Login once it's proven.
- Control Center shows **"Faded"** as the selected output while engaged.
  Picking a real device there works (Faded follows) — it just won't *show* as
  selected. The experimental "Hide Faded from device lists" toggle tries to
  make it invisible; whether macOS accepts a hidden default output is test #7.
- Adds ~10–25 ms of latency. Tune `kPrimeFrames` (driver) / `primeFrames`
  (app) if it ever matters.
- Input volume only works on devices that expose a hardware input control.
  The Astro A50 Voice probably doesn't; the menu says so rather than pretending.
- Personal tool: unsandboxed, Apple Development signature, arm64 only.

---

## First live test

Nothing below has been run yet. Tick as you go.

1. `make install` → menu bar icon appears (speaker with ⚠ = driver missing).
2. Click → **Install Driver…** → password → within ~10 s the popover shows the
   Output list. `system_profiler SPAudioDataType | grep Faded` shows "Faded"
   only (the Tap stays hidden).
3. Play music → sound continues on the current device. Settings → General →
   Diagnostics: `underruns` flat, `fifoFrames` ~1000–2000.
4. **Astro A50** — select it under Output. Press F11/F12 → volume changes. 🎯
   The Sound slider in Control Center moves it too.
5. **Built-in speakers** — select → F11/F12 → Sound settings shows the same
   level (mirroring), and 50 % sounds like macOS's 50 % (no double attenuation).
6. **AirPods** — connect / pick in Control Center → Faded's header follows
   within a second. Stem volume gestures move Faded's slider.
7. **Hidden experiment** — Settings → "Hide Faded from device lists". If audio
   keeps working and Control Center no longer lists Faded → jackpot. If the
   toggle flips itself back off → macOS refused; leave it off.
8. **AirPlay** — pick the Sonos in Control Center. Expected: the menu shows
   "macOS is routing audio directly. Faded is standing by," and audio plays on
   the Sonos normally. Then pick a local device again → Faded re-engages.
   *If instead a device with an AirPlay icon appears in Faded's Output list and
   audio flows through it, even better — tell me and I'll drop the standby path.*
9. **Meters** — play something: the bar left of the selected output device
   moves. Speak: the bar left of the selected input moves (not for Bluetooth
   inputs, by design).
10. **Input** — select MacBook Pro Microphone → the mic slider moves it (check
    in System Settings → Sound → Input). Select Astro A50 Voice → if it has no
    hardware control, the slider greys out and the menu says so.
11. **Per-app** — open Spotify + a YouTube tab → expand **Apps** → both listed
    with moving meters. Drag Spotify to 30 % → only Spotify quieter. Mute
    YouTube → only YouTube silent. Star Spotify → collapse Apps → Spotify still
    visible, YouTube gone. Quit Spotify → still listed (starred), greyed.
12. **Hiding** — Settings → Devices → untick U32R59x → it disappears from the
    menu and "Show More" appears. Click it → hidden devices show, dimmed.
13. **Discord** — Voice settings → Faded must NOT appear in the input list.
14. Quit Faded → default output returns to the real device, audio continues.
15. Relaunch → re-engages without touching volume.

If (2) fails: `log show --last 5m --predicate 'process == "coreaudiod"' | grep -i -E "faded|aspl"`,
and rebuild the driver with `-DFADED_DEBUG_TRACE=ON` for verbose syslog.
If (3) has audio but crackles: raise `kPrimeFrames` (driver) and `primeFrames`
(app) to 2048 and rebuild.
