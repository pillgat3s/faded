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
// MV3 service workers are killed aggressively, so nothing is cached in module
// scope; every handler reads storage. It's a few hundred bytes.

const DEFAULT_GAIN = 1;

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

async function setTabGain(tabId, gain) {
  const tabs = await tabGains();
  if (gain === DEFAULT_GAIN) delete tabs[tabId];
  else tabs[tabId] = gain;
  await chrome.storage.session.set({ tabs });
}

function originOf(url) {
  try {
    const { origin, protocol } = new URL(url);
    return protocol === 'http:' || protocol === 'https:' ? origin : null;
  } catch (_) {
    return null;
  }
}

/** Effective gain for a tab: its own override, else the site default, else 1. */
async function gainFor(tabId, url) {
  const tabs = await tabGains();
  if (tabs[tabId] !== undefined) return tabs[tabId];
  const origin = originOf(url);
  if (!origin) return DEFAULT_GAIN;
  const sites = await siteGains();
  return sites[origin] ?? DEFAULT_GAIN;
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
  await setTabGain(tabId, value);
  await setSiteGain(originOf(url), value);
  await applyToTab(tabId, value);
  return value;
}

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
  try {
    const reply = await chrome.tabs.sendMessage(tabId, { type: 'ping' }, { frameId: 0 });
    return reply?.hooked === true;
  } catch (_) {
    return false;
  }
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
        const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
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
        return sendResponse({ tabs: list, hasOverrides: Object.keys(tabs).length > 0 });
      }

      case 'setGain': {
        const value = await setGain(message.tabId, message.url, message.gain);
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
