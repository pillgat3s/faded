# Faded Tabs

Per-tab volume for Chrome and Brave — the one thing [Faded](../README.md)
cannot do from the audio driver.

A browser is a single audio client as far as macOS is concerned. Chrome and
Brave mix every tab through one audio service process, and Safari routes all
media through `com.apple.WebKit.GPU`, so at the CoreAudio layer there is
literally one stream with nothing to separate. Per-tab volume can only happen
*inside* the browser, which is what this does.

<img src="../docs/extension.png" width="320" alt="The Faded Tabs popup: one row per tab with a favicon, title, percentage and slider">

## What it does

- A slider per tab: the current one, plus everything currently making sound.
- Levels stick **per tab**, so two YouTube tabs can sit at different volumes.
- The last level you chose for a site becomes the starting point for the next
  tab you open there.
- Chrome's own per-tab mute, kept separate from the slider — unmuting returns
  to the level you had rather than jumping to full.
- Toolbar badge shows the percentage whenever a tab isn't at 100 %.

Attenuation only, 0–100 %, matching Faded itself. See *Why no boost* below.

## How it works

Two scripts, one per JavaScript world:

- **`page.js`** runs in the page's own world, because everything it needs to
  touch is page state an isolated content script cannot reach. It replaces
  `HTMLMediaElement.prototype.volume` with an accessor that remembers what the
  page *asked* for and applies `asked × gain` to the real setter — so a site's
  own volume slider keeps working and keeps reading back its own value, the
  audio is just quieter. It also replaces `AudioContext.prototype.destination`
  with a `GainNode` feeding the real destination, which catches sites that
  synthesise audio and never touch a media element at all.
- **`content.js`** is the bridge between that and the extension, one per frame
  — a tab's audio is very often inside an iframe.

`background.js` owns the state and pushes changes to every frame in a tab.

### Why not `chrome.tabCapture`

Capturing the tab and replaying it through Web Audio is the other way to do
this, and it's what boost-capable extensions use. It also lights the recording
indicator, adds latency, and fights with screen sharing. It is only *necessary*
in order to amplify past 100 %, which this doesn't do — so it isn't used.

### Why no boost

`HTMLMediaElement.volume` is capped at 1.0, so boosting a media element is
impossible without routing it through Web Audio, which breaks on any
cross-origin media served without CORS headers (you get silence, not sound).
Boosting the Web Audio path instead invites clipping. Faded is attenuation-only
for the same reason, so the two behave the same way.

## Install

Not on the Chrome Web Store. Load it unpacked:

1. `chrome://extensions` → turn on **Developer mode**
2. **Load unpacked** → select this `extension/` folder

Same steps in Brave at `brave://extensions`.

## Tests

`test/hooks.html` exercises the interception logic on its own, with no
extension loaded — it stubs the messaging that `content.js` normally does and
checks the scaling maths, the getter passthrough, late-created elements and the
Web Audio destination swap.

```bash
cd extension && python3 -m http.server 8731
# then open http://localhost:8731/test/hooks.html
```

The page title reads `PASS (n)` or `FAIL (n)`.

## Known limitations

- Cross-origin `<iframe>`s are handled (the content script runs in all frames),
  but a site that sandboxes its player frame without allowing scripts is out of
  reach.
- Sites that read `ctx.destination.maxChannelCount` see a `GainNode` instead of
  an `AudioDestinationNode`. Rare, and the patch falls back to the real
  destination if anything throws.
- Per-tab levels are forgotten when the browser restarts; per-site levels are
  not.
- Chrome only (and Brave, which is the same engine). Safari needs a Safari Web
  Extension — a different package that has to be wrapped in an app and
  notarized.
