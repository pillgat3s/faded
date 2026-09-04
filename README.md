# Faded

A macOS menu bar sound control shaped like the stock Control Center Sound
module, with the parts macOS is missing.

<p align="center">
  <img src="docs/menu.png" width="352" alt="Faded's menu: Sound title, output slider, Output and Input device lists with level meters, and an Apps section with per-app sliders">
</p>

- **The volume keys work on every output device** — including the ones that
  have no volume control of their own, where macOS greys the slider out and
  F11/F12 do nothing. USB headset base stations (Astro A50 and friends),
  HDMI/DisplayPort audio, plenty of USB DACs.
- **Per-app volume and mute**, with a ⭐ to pin the apps you always want in
  reach. Everything else appears only while it is actually making sound.
- **Your real device stays the system output.** Faded never takes the default
  device away from macOS, so AirPods automatic switching, ear detection, the
  iPhone handoff, AirPlay and Control Center all behave exactly as without it.
- **Output and input devices in one panel**, the way Control Center does it —
  including paired AirPods that are currently with your iPhone: pick them and
  Faded connects them, like Control Center would.
- **Level meters** beside each device and app.
- **Hide devices** you never use — they collapse behind "Show More".
- Small Settings window, launch at login.

Deliberately **not** included: volume boost above 100 %, sample-rate switching,
balance, an equalizer, per-app device redirection. If you want those, buy
[SoundSource](https://rogueamoeba.com/soundsource/) — it is excellent and does
far more than this.

> **Status:** young. It runs on the author's machine and does what the list
> above says, but it has not been through a wide range of hardware, and the
> build is signed for local use rather than distribution. Treat it as
> something to read and build yourself, not as a product.

---

## Why

macOS decides whether the volume keys work by asking the *output device* to
change its own volume. Devices like the Astro A50 base station don't implement
a volume control at all — they expect you to use the wheel on the headset — so
macOS greys out the slider and the keyboard keys do nothing. There is no
setting that fixes this, because there is nothing to set.

Per-app volume has the same shape of problem: macOS mixes every app into the
device and offers no hook in between.

## How it works

Since macOS 14.4 Core Audio has a sanctioned way to get at an application's
audio before it reaches the device: a **process tap**. Faded is built on it.

```
 Spotify ─┐                       ┌──────────── Faded.app ────────────┐
 Discord ─┼─ process taps (muted  │ per-app gain ▸ mix ▸ master gain  │
 Safari  ─┘  at the device) ────▶ │ (software, only where the device  │
                                  │  has no volume control of its own)│
                                  └──────────────┬────────────────────┘
                                                 │ one IO cycle later, on an
                                                 │ aggregate clocked by…
                                                 ▼
                       Astro A50 / speakers / AirPods / AirPlay / USB DAC
                            ═══ still the system default device ═══
```

Every process CoreAudio knows about gets a tap the moment it appears — not
when it starts playing, because a tap created after the first buffer lets that
buffer through at full level, and on a device without hardware volume that is
an audible blip. The tap mutes the process at the device and hands Faded its
audio; Faded applies the app's gain, sums everything, and plays the result to
the very same device through a private aggregate device that uses it as the
clock master. One IO cycle of latency (about 10 ms), no resampling, no drift
compensation, no shared memory, no driver.

**Volume keys.** Devices with hardware volume are left entirely to macOS — the
keys, the Control Center slider and AirPods stem gestures all work natively
and Faded only reflects them. On a device *without* one, Faded takes the volume
keys itself (an event tap, which needs the Accessibility permission), applies
the change as a software master gain in its mix, and shows its own volume
bezel since macOS no longer draws one.

**Looking like the apps it carries.** macOS reads an open output stream as
"the Mac is playing" — it is what makes in-ear AirPods jump over from an
iPhone. Faded therefore keeps its own stream open only while some tapped
process is running output, and drops it a couple of seconds after the last one
stops, so what the system sees is exactly what it would see without Faded. The
taps are muted unconditionally rather than only while being read, so the brief
moment between an app starting and Faded's stream coming up is silence, never a
burst.

**Per-app volume.** Each tap is one process; helper processes (Chrome Helper,
WebKit GPU, Discord Helper) are resolved back to their owning app for display.
Only apps that have recently produced a signal are listed — otherwise you get
every daemon on the system that happens to hold the device open. Gains persist
per app and apply from the first sample the next time it plays.

**Meters.** Output level and per-app levels come free from the mix. Input
level does not exist as a property anywhere in CoreAudio, so it can only be
obtained by opening a capture stream, which is why that meter is opt-in and
off by default — see *Privacy* below.

**Bluetooth headphones with your phone.** Paired headphones with no CoreAudio
device yet (they are with the iPhone, or in the case) are listed too. Picking
one brings the Bluetooth link up and asks the system's routing arbiter
(`AVAudioRoutingArbiter`) for playback — the arbiter is what actually moves
AirPods audio to the Mac; the link alone never does.

### AirPlay

An AirPlay speaker is **not** a CoreAudio device while it is idle — a Sonos or
an Apple TV appears in the stock Sound menu but nowhere in the HAL device list,
because macOS discovers those over the network rather than through the audio
stack. Pick one in Control Center: macOS materialises a real CoreAudio device
called "AirPlay" and makes it the default, and Faded follows it like any other
device. If a device genuinely cannot be followed, Faded steps aside and says
so in the menu; audio keeps flowing natively, per-app volume pauses there.

### The virtual-device engine (legacy)

Faded's first engine was a HAL plug-in ([`driver/`](driver/)): a virtual
"Faded" device that every app played into, with the mix pulled out over a
shared-memory ring and played to the real device. It is still in the tree and
selectable in Settings → Engine, mainly as a reference: it works, but it makes
Faded the owner of the system default device, and a surprising amount of macOS
keys off exactly that — most visibly AirPods automatic switching, which reads
every reclaim of the default as you rejecting the AirPods. The native engine
needs none of it, and nothing has to be installed.

## Per-tab volume in the browser

A browser is one audio client as far as macOS is concerned — Chrome and Brave
mix every tab through a single audio service process, and Safari routes all
media through `com.apple.WebKit.GPU`. At the CoreAudio layer there is literally
one stream, so no audio driver, Faded's or anyone else's, can separate tabs.

[`extension/`](extension/) is a companion Chrome/Brave extension that does it
from inside the browser instead: it intercepts `HTMLMediaElement.volume` and
the Web Audio destination in each page, giving every tab its own level. Load it
unpacked from `chrome://extensions` — see [its README](extension/README.md).
With the extension installed, the tabs also appear inside Faded's own menu
through a small native-messaging bridge.

<p align="center">
  <img src="docs/extension.png" width="320" alt="The Faded Tabs popup: one row per tab with favicon, title, percentage and volume slider">
</p>

## Privacy

- **System Audio Recording** — the taps count as audio capture, so macOS asks
  once. Faded measures and mixes the audio inside its output cycle and never
  writes a sample anywhere.
- **Faded does not open the microphone.** The input level meter is the one
  exception, and it is opt-in and off by default: macOS has no way to report a
  microphone's level without listening to it, so that meter does open a
  capture stream while the menu is on screen — and the orange indicator
  appears for exactly that long. Bluetooth inputs are never metered (the
  A2DP→HFP profile switch would wreck playback).
- **Accessibility** — only asked for when you are on a device without a volume
  control, because taking the volume keys is an event tap.
- **Bluetooth** — to list paired headphones that are not connected yet.
- No network code, no analytics, no accounts. Settings live in
  `~/Library/Preferences/com.andri.faded.plist`; a plain-text trace of routing
  decisions is kept at `~/Library/Application Support/Faded/trace.log`.

## Build

Requires Xcode 26, and `brew install cmake xcodegen`.

```bash
make            # driver + app → build/Faded.app
make driver     # just the legacy HAL plug-in
make app        # just the app (embeds the driver for the legacy engine)
make clean
```

Builds are ad-hoc signed by default, which works fine. For daily use set a real
signing identity — an ad-hoc signature changes on every build, so macOS treats
each rebuild as a different app and resets its permissions and login-item
registration:

```bash
echo 'CODESIGN_ID = Apple Development: you@example.com (TEAMID)' > local.mk
```

`local.mk` is untracked.

### Looking at the UI without installing anything

Debug builds can rasterise the menu to a PNG. No audio touched:

```bash
./app/build/Build/Products/Debug/Faded.app/Contents/MacOS/Faded \
    --render-menu /tmp/menu.png --expanded --demo
```

(`--demo` substitutes invented device names, which is how the screenshot above
is generated. The Settings window can't be rendered this way — `TabView` and
grouped `Form` are AppKit-backed and come out blank.)

Two headless probes exercise the interesting paths and report to the trace
file: `Faded --tap-probe [full|unmuted|notap] [seconds]` runs a minimal tap
engine, and `Faded --bt-connect <mac>` runs the Bluetooth connect flow.

## Install

```bash
make install    # copies build/Faded.app to /Applications and opens it
```

That is all. Allow the System Audio Recording prompt and Faded is working;
nothing is installed anywhere else.

## Uninstall

```bash
make uninstall
```

Removes the app and its preferences (and the legacy driver, if you ever
installed it). No launch agents, no daemons, no login items unless you turn
one on.

## Known limitations

- **macOS 14.4 or later** for the process-tap API; the project targets 26.
- **Stereo only.** Taps are stereo mixdowns; multichannel content is folded.
- About 10 ms of latency (one IO cycle) between an app and the device.
- The first few tens of milliseconds after an app starts playing from total
  silence are muted while Faded's stream comes up. Players that keep their
  stream open (most of them) never hit this.
- Per-app gain applies to the audio an app sends to the system default
  device; an app addressing some other device directly is left alone.
- Input volume only works on devices that expose a hardware input control.
- Not suitable for bit-perfect playback chains — there is an extra hop.

## License

MIT — see [LICENSE](LICENSE). Third-party code is listed in
[THIRD-PARTY.md](THIRD-PARTY.md); the legacy driver is built on
[libASPL](https://github.com/gavv/libASPL) by Victor Gaydov, also MIT.
