# Faded

A macOS menu bar sound control shaped like the stock Control Center Sound
module, with the parts macOS is missing.

<p align="center">
  <img src="docs/menu.png" width="352" alt="Faded's menu: Sound title, output slider, Output and Input device lists with level meters, an Apps section with per-app sliders, and Chrome tabs">
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
- **Browser tabs in the same menu**, with the
  [Faded Tabs](https://github.com/pillgat3s/faded-tabs) extension for Chrome
  and Brave — per-tab volume, next to the per-app sliders.
- **Level meters** beside each device and app.
- **Hide devices** you never use — they collapse behind "Show More".
- Small Settings window, launch at login. Nothing to install besides the app.

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
 Spotify ─┐  taps: every app is listened to (meters, app list) …
 Discord ─┼─────────────────────────────────────────────────────▶ device, untouched
 Safari  ─┘
            … and an app is TAKEN OVER only while it has to be:
              its level is below 100 %, it is muted, or the device
              has no volume control of its own
                  │ tap mutes it at the device
                  ▼
        ┌──────────── Faded.app ────────────┐
        │ per-app gain ▸ mix ▸ master gain  │──▶ the same device, one IO cycle later
        └───────────────────────────────────┘    (still the system default)
```

Every process CoreAudio knows about gets a tap the moment it appears. By
default the tap only *listens*: that feeds the level meters and the list of
apps that are playing, and changes nothing about the audio. An app is *taken
over* — its tap muted at the device, its audio re-played by Faded at the right
gain — only while that is needed: its level is below 100 %, it is muted, or the
device has no volume control of its own and the master gain has to be applied
in software. The re-played mix goes to the very same device through a private
aggregate device that uses it as the clock master: one IO cycle of latency
(about 10 ms), no resampling, no drift compensation, no driver. An app whose
stored level calls for it is tapped muted from birth, so it is never heard at
full level first. At 100 % everywhere on a device with its own volume control,
Faded touches nothing at all.

**Volume keys.** Devices with hardware volume are left entirely to macOS — the
keys, the Control Center slider and AirPods stem gestures all work natively
and Faded only reflects them. On a device *without* one, Faded takes the volume
keys itself (an event tap, which needs the Accessibility permission), applies
the change as a software master gain in its mix, and shows its own volume
bezel since macOS no longer draws one.

**Idle means idle.** macOS reads an open output stream as "the Mac is
playing" — it is what makes in-ear AirPods jump over from an iPhone. Faded's
own stream therefore runs only while it has a job: a taken-over app is playing
(its audio exists nowhere else), or the menu is open and wants meters.
Otherwise Faded holds no stream and costs nothing.

**Per-app volume.** Each tap is one process; helper processes (Chrome Helper,
WebKit GPU, Discord Helper) are resolved back to their owning app for display.
Only apps that have recently produced a signal are listed — otherwise you get
every daemon on the system that happens to hold the device open. Gains persist
per app and apply from the first sample the next time it plays.

**Other apps' captures — why "only when needed" matters.** Another app's
recording or screen share sees a muted original *and* Faded's re-play of it.
A taken-over app is therefore captured twice, an IO cycle apart, and an app
that captures "the system minus itself" — Discord's screen share does — gets
its own audio back through Faded's copy, which is how the people in a call end
up hearing themselves. An app that is only listened to is captured once,
exactly as without Faded. All of this is measured, not assumed:
`--tap-probe mini <pid>` is a one-app Faded, `devcap` and `excluding` are what
another app's capture sees, and a 1 kHz tone detector tells one copy from two.

**Bypassed apps.** Apps on the bypass list (Settings → Apps, or right-click an
app in the menu) are never tapped at all, even when everything else has to be
taken over for a software master volume. Discord is bypassed by default for the
reason above. The cost: no slider for it, and on a device without hardware
volume it ignores the volume keys — use its own output volume there.

**Devices with inputs of their own.** Some output devices bring a capture
stream into the aggregate (a USB headset base station does). Tap streams come
last in the aggregate's input list; the mixer reads only those and asks the HAL
to leave the device's own inputs closed.

**Meters.** Output level and per-app levels come free from the mix. Input
level does not exist as a property anywhere in CoreAudio, so it can only be
obtained by opening a capture stream, which is why that meter is opt-in and
off by default — see *Privacy* below.

**Bluetooth headphones with your phone.** Paired headphones with no CoreAudio
device yet (they are with the iPhone, or in the case) are listed too. Picking
one brings the Bluetooth link up and asks the system's routing arbiter
(`AVAudioRoutingArbiter`) for playback — the arbiter is what actually moves
AirPods audio to the Mac; the link alone never does.

**AirPlay.** An AirPlay speaker is not a CoreAudio device while it is idle —
macOS discovers those over the network — so it can't be listed here. Pick one
in Control Center: macOS materialises a real device called "AirPlay" and makes
it the default, and Faded follows it like any other device. If a device
genuinely cannot be followed, Faded steps aside and says so in the menu; audio
keeps flowing natively, per-app volume pauses there.

## Browser tabs

A browser is one audio client as far as macOS is concerned — Chrome and Brave
mix every tab through a single audio service process, and Safari routes all
media through `com.apple.WebKit.GPU`. At the CoreAudio layer there is literally
one stream, so no audio engine, Faded's or anyone else's, can separate tabs.

[Faded Tabs](https://github.com/pillgat3s/faded-tabs) is the companion
Chrome/Brave extension that does it from inside the browser instead. With both
installed, the tabs also appear in Faded's own menu: Chrome launches a tiny
relay ([`bridge/`](bridge/)) through native messaging, the relay dials the
app's unix socket, and JSON goes both ways. The app writes the native-messaging
host manifest for every Chromium-family browser it finds on each launch, so
there is nothing to configure. Either half is fully useful without the other.

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

Requires Xcode 26 and `brew install xcodegen`.

```bash
make            # → build/Faded.app
make install    # copies it to /Applications and opens it
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

### Looking at the UI without touching audio

Debug builds can rasterise the menu to a PNG:

```bash
make app CONFIG=Debug
./app/build/Build/Products/Debug/Faded.app/Contents/MacOS/Faded \
    --render-menu /tmp/menu.png --expanded --demo
```

(`--demo` substitutes invented device names, which is how the screenshot above
is generated.)

Two headless probes exercise the interesting paths and report to the trace
file. `Faded --tap-probe <mode> [seconds] [pid] [device]` runs experiments on
the tap machinery next to the real app (`full`, `unmuted`, `notap`, `global`,
`only`, `excluding`, `usage`, `inputs` — see `TapProbe.swift`), and
`Faded --bt-connect <mac>` runs the Bluetooth connect flow. Launch them through
LaunchServices (`open -n Faded.app --args …`) so the permissions are
attributed to Faded rather than to your shell.

## Install

`make install`, allow the System Audio Recording prompt, done. Nothing is
installed anywhere else.

Earlier versions of Faded routed audio through a HAL driver of their own. If
one is still on your machine, Settings shows a **Remove Old Driver…** button;
it asks for your password once and restarts the audio system.

## Uninstall

```bash
make uninstall
```

Removes the app, its preferences and its support folder (and the old driver, if
one is installed). No launch agents, no daemons, no login items unless you
turn one on.

## Known limitations

- **macOS 14.4 or later** for the process-tap API; the project targets 26.
- **Stereo only.** Taps are stereo mixdowns; multichannel content is folded.
- A taken-over app has about 10 ms of added latency (one IO cycle), and the
  first few tens of milliseconds after it starts from total silence are muted
  while Faded's stream comes up. Apps at 100 % are not delayed at all.
- A bypassed app ignores the volume keys on a device without hardware volume,
  because nothing of it passes through Faded. Use the app's own volume there.
- While an app is taken over, other apps' recordings and screen shares capture
  it twice (the original and Faded's copy). On a device with its own volume
  that is only the apps you turned down; on a device without one it is
  everything below 100 % master volume.
- Input volume only works on devices that expose a hardware input control.
- Not suitable for bit-perfect playback chains — there is an extra hop.

## License

MIT — see [LICENSE](LICENSE).
