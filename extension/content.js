// content.js — the bridge.
//
// Runs in the isolated world, so it can talk to the extension. page.js runs in
// the page's world, so it can patch the page's own objects. Neither can see the
// other's variables, so they pass messages through the shared `window`.
//
// One of these exists per frame, and each frame reports its own gain, because a
// tab's audio often lives in an iframe (embedded YouTube, an ad, a widget).

(() => {
  'use strict';

  const CHANNEL_IN = 'faded-tabs:set';
  const CHANNEL_READY = 'faded-tabs:ready';

  function push(gain) {
    window.postMessage({ channel: CHANNEL_IN, gain }, '*');
  }

  async function pull() {
    try {
      const response = await chrome.runtime.sendMessage({ type: 'getGain' });
      if (response && typeof response.gain === 'number') push(response.gain);
    } catch (_) {
      // Service worker asleep or extension reloading — the background script
      // pushes the value again as soon as it is up.
    }
  }

  // page.js announces itself once its hooks are installed.
  window.addEventListener('message', (event) => {
    if (event.source !== window) return;
    if (event.data && event.data.channel === CHANNEL_READY) pull();
  });

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message) return;
    if (message.type === 'setGain') push(message.gain);
    // Lets the popup distinguish "this tab has no hooks" from "the slider is
    // working but you cannot hear it".
    if (message.type === 'ping') sendResponse({ hooked: true });
  });

  // page.js and this script are both injected at document_start, one into each
  // world, and their order is not guaranteed — so either the READY announcement
  // or the first push can be the one that lands in an empty room. Re-push a
  // couple of times early; page.js ignores a value it already has.
  pull();
  setTimeout(pull, 100);
  setTimeout(pull, 600);
})();
