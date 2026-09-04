// background.js — the service worker. Owns the volume for every tab.
//
// Two layers of state, which is what makes this feel right in use:
//
//   * per tab   — what you set applies to that tab only, so two YouTube tabs
//                 can sit at different levels. Lives in session storage, so it
//                 survives the service worker being torn down but not a
//                 browser restart.
//   * per site  — the last level you chose for an origin becomes the starting
//                 point for the next tab you open on that origin. Persisted.
//
// A tab's level is pinned the first time the tab is seen (seeded from the
// site's remembered level), so changing one YouTube tab never moves another
// that is already open — only tabs opened afterwards start from the new
// level. Entries are {gain, origin, explicit}: `explicit` marks a level the
// user set for that tab, which survives navigation; a seeded one is re-seeded
// when the tab moves to a different site.
//
// MV3 service workers are killed aggressively, so nothing is cached in module
// scope; every handler reads storage. It's a few hundred bytes.

const DEFAULT_GAIN = 1;
const NATIVE_HOST = 'com.andri.faded';

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

async function siteGains() {
  const { sites = {} } = await chrome.storage.local.get('sites');
  return sites;
}

async function setSiteGain(origin, gain) {
  if (!origin) return;
  const sites = await siteGains();
  if (gain === DEFAULT_GAIN) delete sites[origin];
  else sites[origin] = gain;
  await chrome.storage.local.set({ sites });
}

async function tabGains() {
  const { tabs = {} } = await chrome.storage.session.get('tabs');
  return tabs;
}

async function setTabGain(tabId, gain, url) {
  const tabs = await tabGains();
  tabs[tabId] = { gain, origin: originOf(url), explicit: true };
  await chrome.storage.session.set({ tabs });
}

function hasUserOverrides(tabs) {
  return Object.values(tabs).some((e) => e && e.explicit && e.gain !== DEFAULT_GAIN);
}

function originOf(url) {
  try {
    const { origin, protocol } = new URL(url);
    return protocol === 'http:' || protocol === 'https:' ? origin : null;
  } catch (_) {
    return null;
  }
}

/** Effective gain for a tab: its pinned level, seeded from the site default
 * the first time the tab (or a new site in it) is seen. */
async function gainFor(tabId, url) {
  const tabs = await tabGains();
  const origin = originOf(url);
  const entry = tabs[tabId];
  if (entry && (entry.explicit || entry.origin === origin)) return entry.gain;
  let gain = DEFAULT_GAIN;
  if (origin) {
    const sites = await siteGains();
    gain = sites[origin] ?? DEFAULT_GAIN;
  }
  tabs[tabId] = { gain, origin, explicit: false };
  await chrome.storage.session.set({ tabs });
  return gain;
}

// ---------------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------------

async function applyToTab(tabId, gain) {
  try {
    // No frameId: Chrome delivers to every frame in the tab, which is what we
    // want — the audio is often in an iframe.
    await chrome.tabs.sendMessage(tabId, { type: 'setGain', gain });
  } catch (_) {
    // No content script here (chrome://, the Web Store, a PDF, a discarded
    // tab). Nothing to do.
  }
  updateBadge(tabId, gain);
}

function updateBadge(tabId, gain) {
  const text = gain === DEFAULT_GAIN ? '' : gain === 0 ? '0' : String(Math.round(gain * 100));
  chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#FF9429' }).catch(() => {});
}

async function setGain(tabId, url, gain) {
  const value = Math.max(0, Math.min(1, Number(gain) || 0));
  await setTabGain(tabId, value, url);
  await setSiteGain(originOf(url), value);
  await applyToTab(tabId, value);
  snapshotAndSend();
  return value;
}

// ---------------------------------------------------------------------------
// Native bridge to Faded.app
//
// Chrome spawns the faded-native-host relay when this port opens; the relay
// dials Faded.app's unix socket and shuttles JSON both ways. The port doubles
// as the MV3 keep-alive: the app pings every 20 s, and traffic on a native
// port resets the service worker's idle timer.
// ---------------------------------------------------------------------------

let nativePort = null;
let nativeFailures = 0;

function snapshotAndSend() {
  buildTabList()
    .then(({ tabs }) => {
      nativePort?.postMessage({
        type: 'tabs',
        tabs: tabs
          .filter((t) => t.adjustable && (t.audible || t.gain !== DEFAULT_GAIN || t.muted))
          .map(({ id, title, gain, audible, muted }) => ({ id, title, gain, audible, muted })),
      });
    })
    .catch(() => {});
}

function connectNativeBridge() {
  if (nativePort) return;
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (_) {
    nativePort = null;
    return; // host manifest not installed (Faded.app has never run) — retry later
  }
  nativeFailures = 0;
  nativePort.onMessage.addListener(async (message) => {
    switch (message?.type) {
      case 'ping':
      case 'bridge':
        snapshotAndSend();
        break;
      case 'setGain': {
        const tab = await chrome.tabs.get(message.tabId).catch(() => null);
        if (tab) await setGain(tab.id, tab.url || '', message.gain);
        snapshotAndSend();
        break;
      }
      case 'setMuted':
        await chrome.tabs.update(message.tabId, { muted: !!message.muted }).catch(() => {});
        snapshotAndSend();
        break;
    }
  });
  nativePort.onDisconnect.addListener(() => {
    // Chrome sets lastError when the host could not be launched or died;
    // reading it also keeps the "Unchecked runtime.lastError" noise out of
    // the extension's error list.
    const why = chrome.runtime.lastError?.message || 'port closed';
    nativePort = null;
    nativeFailures += 1;
    console.debug(`faded bridge disconnected (${why}), attempt ${nativeFailures}`);
    // A setTimeout would die with this service worker; the alarm below is
    // what actually brings the bridge back. Retry quickly a few times in
    // case the worker happens to stay alive, then leave it to the alarm.
    if (nativeFailures <= 3) setTimeout(connectNativeBridge, 3_000);
  });
}

// The only reliable heartbeat an MV3 service worker has: an alarm fires even
// when the worker was torn down, which is exactly when the bridge is gone.
chrome.alarms.create('faded-bridge', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'faded-bridge') connectNativeBridge();
});

chrome.runtime.onStartup.addListener(connectNativeBridge);
chrome.runtime.onInstalled.addListener(connectNativeBridge);
connectNativeBridge();

// ---------------------------------------------------------------------------
// Injecting into tabs that were already open
//
// Content scripts declared in the manifest only run on navigation, so every tab
// that existed when the extension was installed or reloaded has no hooks in it
// and its slider does nothing. Rather than telling people to reload their tabs,
// inject into them explicitly.
// ---------------------------------------------------------------------------

async function injectExistingTabs() {
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({ url: ['http://*/*', 'https://*/*'] });
  } catch (_) {
    return;
  }
  for (const tab of tabs) {
    if (tab.id === undefined) continue;
    try {
      // MAIN first, matching the manifest order: page.js installs the hooks,
      // content.js then asks the service worker for this tab's level.
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        files: ['page.js'],
        world: 'MAIN',
        injectImmediately: true,
      });
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        files: ['content.js'],
        world: 'ISOLATED',
        injectImmediately: true,
      });
    } catch (_) {
      // Chrome Web Store, chrome:// pages, PDFs, discarded tabs — all expected.
    }
  }
}

chrome.runtime.onInstalled.addListener(injectExistingTabs);
chrome.runtime.onStartup.addListener(injectExistingTabs);

/// Is a tab hooked? Used to warn in the popup rather than fail silently.
async function isHooked(tabId) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const reply = await chrome.tabs.sendMessage(tabId, { type: 'ping' }, { frameId: 0 });
      if (reply?.hooked === true) return true;
    } catch (_) {
      // A content script that is still coming up rejects rather than replying.
    }
    if (attempt === 0) await new Promise((r) => setTimeout(r, 60));
  }
  return false;
}

/** The current tab plus everything audible, with per-tab state resolved.
 * Shared by the popup and the Faded.app bridge; `probeHooks` costs a message
 * round-trip per tab and only the popup needs it. */
async function buildTabList(probeHooks = false) {
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const audible = await chrome.tabs.query({ audible: true });
  const overrides = await tabGains();

  const byId = new Map();
  for (const tab of [...(active ? [active] : []), ...audible]) {
    if (!tab || tab.id === undefined || byId.has(tab.id)) continue;
    byId.set(tab.id, {
      id: tab.id,
      title: tab.title || tab.url || 'Tab',
      favIconUrl: tab.favIconUrl || '',
      url: tab.url || '',
      audible: !!tab.audible,
      muted: !!tab.mutedInfo?.muted,
      active: tab.id === active?.id,
      gain: await gainFor(tab.id, tab.url || ''),
      adjustable: !!originOf(tab.url || ''),
      hooked: probeHooks && originOf(tab.url || '') ? await isHooked(tab.id) : true,
    });
  }
  const list = [...byId.values()].sort((a, b) => Number(b.active) - Number(a.active));
  return { tabs: list, hasOverrides: hasUserOverrides(overrides) };
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message?.type) {
      // A frame's page.js just came up and wants its level.
      case 'getGain': {
        const tabId = sender.tab?.id;
        if (tabId === undefined) return sendResponse({ gain: DEFAULT_GAIN });
        const gain = await gainFor(tabId, sender.tab.url || sender.url || '');
        updateBadge(tabId, gain);
        return sendResponse({ gain });
      }

      // Popup: give me every tab worth showing.
      case 'listTabs': {
        // lastFocusedWindow, not currentWindow: this runs in the service
        // worker, which has no window of its own, so "current" is meaningless
        // here and can come back empty.
        const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
        const audible = await chrome.tabs.query({ audible: true });
        const tabs = await tabGains();

        const byId = new Map();
        for (const tab of [...(active ? [active] : []), ...audible]) {
          if (!tab || byId.has(tab.id)) continue;
          byId.set(tab.id, {
            id: tab.id,
            title: tab.title || tab.url || 'Tab',
            favIconUrl: tab.favIconUrl || '',
            url: tab.url || '',
            audible: !!tab.audible,
            muted: !!tab.mutedInfo?.muted,
            active: tab.id === active?.id,
            gain: await gainFor(tab.id, tab.url || ''),
            adjustable: !!originOf(tab.url || ''),
            hooked: originOf(tab.url || '') ? await isHooked(tab.id) : true,
          });
        }
        // Active tab first, then whatever is making noise.
        const list = [...byId.values()].sort((a, b) => Number(b.active) - Number(a.active));
        return sendResponse({ tabs: list, hasOverrides: hasUserOverrides(tabs) });
      }

      case 'setGain': {
        const value = await setGain(message.tabId, message.url, message.gain);
        return sendResponse({ gain: value });
      }

      // From a page (via its content script): the sender identifies the tab,
      // so a page can only ever adjust itself. Runs the identical pipeline the
      // popup slider does — storage, badge, broadcast to every frame.
      case 'setGainFromPage': {
        const tab = sender.tab;
        if (!tab || tab.id === undefined) return sendResponse({});
        const value = await setGain(tab.id, tab.url || '', message.gain);
        return sendResponse({ gain: value });
      }

      // Chrome's own per-tab mute — kept separate from gain so unmuting
      // restores the level you had rather than jumping to full.
      case 'setMuted': {
        await chrome.tabs.update(message.tabId, { muted: !!message.muted });
        return sendResponse({ ok: true });
      }

      case 'resetAll': {
        await chrome.storage.session.set({ tabs: {} });
        await chrome.storage.local.set({ sites: {} });
        for (const tab of await chrome.tabs.query({})) {
          if (tab.id !== undefined) await applyToTab(tab.id, DEFAULT_GAIN);
        }
        return sendResponse({ ok: true });
      }

      default:
        return sendResponse({});
    }
  })();
  return true; // responses are async
});

// A tab that finishes loading needs its level re-applied: the content script
// asks on its own, but this also covers same-document navigations.
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  connectNativeBridge();
  if (changeInfo.audible !== undefined || changeInfo.mutedInfo !== undefined) snapshotAndSend();
});

chrome.tabs.onRemoved.addListener(() => snapshotAndSend());

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.status !== 'complete' && changeInfo.url === undefined) return;
  const gain = await gainFor(tabId, tab.url || '');
  if (gain !== DEFAULT_GAIN) await applyToTab(tabId, gain);
  else updateBadge(tabId, gain);
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const tabs = await tabGains();
  if (tabs[tabId] !== undefined) {
    delete tabs[tabId];
    await chrome.storage.session.set({ tabs });
  }
});
