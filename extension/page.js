// page.js — runs in the page's own JavaScript realm (MAIN world), because
// everything it touches is page state that an isolated content script cannot
// reach: HTMLMediaElement.prototype, and the page's AudioContexts.
//
// Two interception points, which between them cover essentially all web audio:
//
//   1. <video>/<audio> elements. The `volume` property is replaced with an
//      accessor that remembers what the page *asked* for and applies
//      `asked x gain` to the real setter. The page keeps reading back its own
//      value, so a site's volume slider (YouTube's, say) still behaves and
//      still shows the position the site set — it just comes out quieter.
//
//   2. AudioContext.destination. Sites that synthesise audio (games, some
//      players, anything using the Web Audio API directly) never touch a media
//      element. Their `destination` now returns a GainNode that feeds the real
//      destination, so everything routed to it passes through our gain.
//
// Deliberately *not* used: chrome.tabCapture. Capturing the tab would light the
// recording indicator, add latency, and fight with screen sharing. It is only
// needed to amplify above 100%, which this extension does not do.
//
// Attenuation only, 0.0 – 1.0. Boosting a media element is impossible anyway
// (`volume` is capped at 1) and boosting Web Audio invites clipping.

(() => {
  'use strict';

  // Content scripts run once per frame, but be defensive about double-install.
  const FLAG = '__fadedTabsInstalled';
  if (window[FLAG]) return;
  window[FLAG] = true;

  const CHANNEL_IN = 'faded-tabs:set';
  const CHANNEL_READY = 'faded-tabs:ready';

  let gain = 1;
  const clamp = (v) => (Number.isFinite(v) ? Math.max(0, Math.min(1, v)) : 1);

  // ---------------------------------------------------------------------
  // 1. Media elements
  // ---------------------------------------------------------------------

  /** Volume the page believes it set, per element. */
  const asked = new WeakMap();
  /** Weak registry of elements we've seen, so a gain change can re-apply. */
  let seen = [];

  function remember(el) {
    if (!(el instanceof HTMLMediaElement)) return;
    if (seen.some((ref) => ref.deref() === el)) return;
    seen.push(new WeakRef(el));
    if (seen.length > 64) seen = seen.filter((ref) => ref.deref());
  }

  const mediaProto = HTMLMediaElement.prototype;
  const volumeDesc = Object.getOwnPropertyDescriptor(mediaProto, 'volume');

  if (volumeDesc && volumeDesc.get && volumeDesc.set) {
    Object.defineProperty(mediaProto, 'volume', {
      configurable: true,
      enumerable: volumeDesc.enumerable,
      get() {
        // Hand the page back its own number, not our scaled one, so sites that
        // read volume back (to draw their slider) don't drift downwards.
        return asked.has(this) ? asked.get(this) : volumeDesc.get.call(this);
      },
      set(value) {
        const v = clamp(Number(value));
        asked.set(this, v);
        remember(this);
        try {
          volumeDesc.set.call(this, clamp(v * gain));
        } catch (_) {
          /* element may be in a bad state; nothing useful to do */
        }
      },
    });
  }

  // Elements the page never assigns `volume` on still need scaling, so catch
  // them when they start playing.
  const realPlay = mediaProto.play;
  mediaProto.play = function play(...args) {
    remember(this);
    applyToElement(this);
    return realPlay.apply(this, args);
  };

  function applyToElement(el) {
    if (!volumeDesc || !volumeDesc.set) return;
    let base = asked.get(el);
    if (base === undefined) {
      // First time we've seen it: whatever it is now *is* the page's intent.
      base = clamp(volumeDesc.get.call(el));
      asked.set(el, base);
    }
    try {
      volumeDesc.set.call(el, clamp(base * gain));
    } catch (_) {}
  }

  function applyToAllElements() {
    for (const ref of seen) {
      const el = ref.deref();
      if (el) applyToElement(el);
    }
    // Anything currently in the DOM that we haven't registered yet.
    try {
      for (const el of document.querySelectorAll('video, audio')) {
        remember(el);
        applyToElement(el);
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // 2. Web Audio
  // ---------------------------------------------------------------------

  /** ctx -> the GainNode we hand out in place of its destination. */
  const contextGain = new WeakMap();
  let contexts = [];

  /**
   * `destination` is declared on BaseAudioContext, not on AudioContext, so the
   * descriptor has to be found by walking up the chain. The override is then
   * defined as an *own* property of AudioContext.prototype, which shadows it
   * for live contexts while leaving OfflineAudioContext untouched.
   */
  function ownerDescriptor(proto, name) {
    for (let p = proto; p; p = Object.getPrototypeOf(p)) {
      const d = Object.getOwnPropertyDescriptor(p, name);
      if (d) return d;
    }
    return null;
  }

  function patchAudioContext(Ctor) {
    if (!Ctor || !Ctor.prototype) return;
    const desc = ownerDescriptor(Ctor.prototype, 'destination');
    if (!desc || !desc.get) return;

    Object.defineProperty(Ctor.prototype, 'destination', {
      configurable: true,
      enumerable: desc.enumerable,
      get() {
        let node = contextGain.get(this);
        if (!node) {
          const real = desc.get.call(this);
          try {
            node = this.createGain();
            node.gain.value = gain;
            node.connect(real);
            contextGain.set(this, node);
            contexts.push(new WeakRef(this));
            if (contexts.length > 32) contexts = contexts.filter((r) => r.deref());
          } catch (_) {
            return real; // if anything goes wrong, never break the page's audio
          }
        }
        return node;
      },
    });
  }

  // Only live contexts — OfflineAudioContext renders to a buffer, and quietly
  // attenuating an offline render would corrupt whatever the page does with it.
  patchAudioContext(window.AudioContext);
  patchAudioContext(window.webkitAudioContext);

  function applyToAllContexts() {
    for (const ref of contexts) {
      const ctx = ref.deref();
      if (!ctx) continue;
      const node = contextGain.get(ctx);
      if (node) {
        try {
          node.gain.value = gain;
        } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------

  function setGain(value) {
    const next = clamp(Number(value));
    // Recorded even when unchanged: this is the only externally visible proof
    // that a level actually reached the page, which makes "the slider does
    // nothing" answerable without guessing at which link in the chain broke.
    window.__fadedTabs = { gain: next, receivedAt: Date.now(), applied: next !== gain };
    if (next === gain) return;
    gain = next;
    applyToAllElements();
    applyToAllContexts();
  }

  window.addEventListener('message', (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.channel !== CHANNEL_IN) return;
    setGain(data.gain);
  });

  // New media elements appearing later (SPAs, ads, lazy players).
  const startObserver = () => {
    try {
      new MutationObserver((records) => {
        if (gain === 1) return;
        for (const record of records) {
          for (const node of record.addedNodes) {
            if (node instanceof HTMLMediaElement) {
              remember(node);
              applyToElement(node);
            } else if (node instanceof Element) {
              const found = node.querySelectorAll?.('video, audio');
              if (found) {
                for (const el of found) {
                  remember(el);
                  applyToElement(el);
                }
              }
            }
          }
        }
      }).observe(document.documentElement, { childList: true, subtree: true });
    } catch (_) {}
  };

  if (document.documentElement) startObserver();
  else document.addEventListener('readystatechange', startObserver, { once: true });

  // Tell the content script we're live so it can push this frame's gain.
  window.postMessage({ channel: CHANNEL_READY }, '*');
})();
