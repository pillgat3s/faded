# Faded

A personal, native-looking macOS menu bar sound control that adds what macOS
doesn't have:

- **Volume keys / Sound slider on devices that have no volume control** — USB
  headset base stations (Astro A50), HDMI/DisplayPort audio, most USB DACs.
- **Per-app volume** (with mute and up to 2× boost) for whatever is playing.
- Follows the system: pick AirPods, an AirPlay speaker or anything else in
  Control Center exactly as before — Faded notices and routes there. AirPlay
  stays 100 % native.

Built after fighting Logitech G HUB, Background Music, and a cracked SoundSource
in one evening. SoundSource is excellent — this is the "I like building my own
stuff" version, scoped to the two features I actually wanted, without the
things that bit me in the free virtual-device apps (fake microphone showing up
in Discord, device switching breaking when AirPods connect).

**Status: built, compiles clean, NOT yet run on real hardware. First live test
is the checklist at the bottom.**

---

## How it works

macOS has exactly two ways to sit between apps and a speaker: Rogue Amoeba's
proprietary ARK/ACE engine, or a virtual audio device. Faded is a virtual
device — but designed around the failure modes of the usual ones.

```
                       ┌──────────────── FadedDriver.driver (HAL plug-in, in coreaudiod) ───────────────┐
  Spotify ─┐           │  "Faded" (visible OUTPUT device)                    "Faded Tap" (HIDDEN input)   │
  Discord ─┼─ plays ─▶ │  per-client gain ▸ mix ▸ master vol/mute ▸ FIFO ─────────▶ read back            │
  Safari  ─┘  into     │  (has volume+mute controls ⇒ F11/F12 + Sound slider drive it)                  │
                       └──────────────────────────────────────────────────────────────┬─────────────────┘
                                                                                      │ AUHAL input
                                                                                      ▼
                                                                          Faded.app  RingBuffer
                                                                                      │ AUHAL output
                                                                                      ▼
                                                              real device: Astro A50 / AirPods / AirPlay / speakers
```

**Why the volume keys work:** the "Faded" device declares a real volume + mute
control. macOS happily drives it from the keyboard and Sound settings; the
driver applies it (or, if the *real* target has hardware volume, Faded.app
mirrors the value onto it and tells the driver to bypass — no double
attenuation, AirPods stem gestures still sync).

**Why Discord doesn't see a fake mic:** the readback device ("Faded Tap") is
`kAudioDevicePropertyIsHidden`. Faded.app resolves it by UID; nothing else
lists it.

**Why AirPods/AirPlay still work natively:** Faded keeps "Faded" as macOS's
default output, but *listens*. The moment anything (Control Center, auto-switch,
another app) points the default at a real device, Faded adopts that device as
its play-to target and puts itself back as default — within a listener
callback, i.e. milliseconds. Picking an AirPlay speaker in Control Center =
audio goes there through Faded.

**Per-app volume:** the AudioServerPlugIn API hands the driver every client's
buffer *before* mixing (`OnProcessClientOutput`) with its pid + bundle id.
Gain applied there; helper processes (Chrome Helper, WebKit GPU…) are
resolved to their owning app in the UI.

### Components

| Path | What |
|---|---|
| `driver/` | C++17 HAL plug-in on [libASPL](https://github.com/gavv/libASPL) (MIT, vendored in `third_party/`). `Driver.cpp` = the Faded logic, `FadedFIFO.hpp` = lock-free SPSC ring, `FadedProtocol.h` = app↔driver contract |
| `app/` | Swift 6 / SwiftUI menu bar app (`MenuBarExtra`, window style), xcodegen project like SafeKey |
| `app/Sources/Faded/CoreAudio` | typed wrappers over the HAL C API |
| `app/Sources/Faded/Driver` | driver discovery + custom-property protocol, installer (admin prompt via AppleScript) |
| `app/Sources/Faded/Engine` | `PlayThrough` (two AUHAL units + ring), `AudioRouter` (the brain), `ProcessResolver` (pid → app) |
| `app/Sources/Faded/UI` | Control-Center-style slider, menu view |
| `scripts/` | icon generator, driver install/uninstall, protocol consistency check |

App ↔ driver protocol = custom properties on the Faded device (`'fcli'` clients,
`'fapv'` per-app gains, `'fbyp'` master bypass, `'fhid'` hide device,
`'fsta'` stats, `'fver'` version). See `driver/FadedProtocol.h`.

---

## Build

Requirements: Xcode 26, `brew install cmake xcodegen`.

```bash
make            # driver + app → build/Faded.app (Release, signed w/ Apple Development id)
make driver     # just the .driver
make app        # just the app (embeds driver/build/FadedDriver.driver)
make clean
```

## Install / first run

```bash
make install    # copies build/Faded.app → /Applications and opens it
```

Then click the menu bar speaker → **Install Driver…** → macOS admin password
prompt → coreaudiod restarts (≈1 s silence) → Faded engages: it takes the
current output device as target and sets "Faded" as default output.

Manual driver install without the app: `make install-driver` (sudo).

## Uninstall

`make uninstall` — quits the app, removes `/Applications/Faded.app`, the
driver in `/Library/Audio/Plug-Ins/HAL/FadedDriver.driver`, prefs, and
restarts coreaudiod. Or in-app: gear → *Uninstall Driver…*.

Nothing else is touched. No launch agents, no daemons, no login items unless
you toggle "Launch at Login".

---

## Known limitations / design notes

- **If Faded.app isn't running while the driver is installed and "Faded" is
  the default output, audio is silent** (nothing drains the FIFO). Faded
  restores the real device as default on quit; on crash it can't. Next launch
  fixes it (it detects default==Faded and re-adopts the last target). Turn on
  "Launch at Login" once it's proven.
- Control Center / Sound settings show **"Faded"** as the selected output while
  engaged. Picking a real device there works (Faded follows) — it just doesn't
  *show* as selected afterwards. The experimental "Hide 'Faded' from device
  lists" toggle tries to make it invisible; whether macOS still lets a hidden
  device be the default output is test #7 below.
- Adds ~10–25 ms of latency (driver FIFO prime 1024 frames + two AUHAL buffers).
  Fine for music/video/games; if you notice A/V drift, that's where to tune
  (`kPrimeFrames` in `FadedFIFO.hpp`, `primeFrames` in `RingBuffer.swift`).
- Only one reader may attach to Faded Tap (the FIFO is a plain queue).
- Sample rate: the virtual devices switch to the target's rate (44.1/48/88.2/96 k)
  so nothing resamples; other rates → 48 k and AUHAL converts on output.
- Grouping multiple AirPlay/Sonos speakers is *not* a Faded feature (by design)
  — that's macOS Control Center (AirPlay 2) or Rogue Amoeba's Airfoil.
- Personal tool: unsandboxed, Apple Development signature, arm64 only.

---

## First live test (do this on a day you're not testing other audio apps)

Everything below is expected to work but has **not been run yet**. Tick as you go.

1. `make install` → menu bar icon appears (speaker with ⚠ badge = driver missing).
2. Click → **Install Driver…** → password → within ~10 s the icon becomes a
   plain speaker and the popover shows *Output* devices. Terminal check:
   `system_profiler SPAudioDataType | grep -A2 Faded` shows "Faded" only (Tap hidden).
3. Play music. Sound comes out of the current device. Diagnostics (gear →
   Diagnostics…): `underruns` should stay flat, `fifoFrames` ~1000–2000.
4. **Astro A50**: select it in Faded's Output list → row says "software volume".
   Press F11/F12 → volume changes. Sound settings slider also moves it. 🎯
5. **Built-in speakers**: select → F11/F12 → check Sound settings shows the same
   level (mirroring), driver bypass on (Diagnostics doesn't expose it directly;
   just confirm no "double" attenuation — 50 % should sound like macOS's 50 %).
6. **AirPods**: connect / pick in Control Center → Faded's header switches to
   AirPods within a second, audio follows. Stem volume gestures move Faded's slider.
7. **Hidden experiment**: gear → "Hide 'Faded' from device lists". If audio
   keeps working and Control Center no longer lists Faded → jackpot. If it
   silently unhides itself → macOS refused; leave it off.
8. **AirPlay**: pick a Sonos in Control Center → Faded follows, plays there.
9. **Per-app**: open Spotify + a YouTube tab → both appear under *Apps* with
   meters moving. Drag Spotify to 30 % → only Spotify quieter. Mute YouTube →
   only YouTube silent. Boost past middle → louder than 100 %.
10. **Discord**: open Voice settings → Faded must NOT appear in the input list.
    Output list will show "Faded" (that's fine; leave Discord on Default).
11. Quit Faded → default output returns to the real device, audio continues.
12. Relaunch → re-engages without touching volume.

If (2) fails: `log show --last 5m --predicate 'process == "coreaudiod"' | grep -i -E "faded|aspl"`
and rebuild the driver with `-DFADED_DEBUG_TRACE=ON` for verbose syslog.
If (3) has audio but crackles: raise `kPrimeFrames` (driver) and `primeFrames`
(app) to 2048 and rebuild.
