// popup.js — the panel behind the toolbar button.
//
// Shows the current tab plus everything currently making noise, one slider
// each. Kept deliberately close to Faded's own menu: no boost, no effects,
// nothing to configure.

'use strict';

const list = document.getElementById('tabs');
const empty = document.getElementById('empty');
const resetButton = document.getElementById('reset');

const send = (message) => chrome.runtime.sendMessage(message).catch(() => ({}));

/** Paints the filled portion of a range input (CSS can't read `value`). */
function paint(input) {
  input.style.setProperty('--fill', `${Number(input.value)}%`);
}

const SVG_NS = 'http://www.w3.org/2000/svg';

/** Speaker glyph, with a slash when muted. Inline so it inherits currentColor. */
function speakerIcon(muted) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');

  const cone = document.createElementNS(SVG_NS, 'path');
  cone.setAttribute('d', 'M4 9v6h4l5 4V5L8 9H4z');
  svg.append(cone);

  if (muted) {
    const slash = document.createElementNS(SVG_NS, 'path');
    slash.setAttribute('d', 'M16.5 8.5l5 7m0-7l-5 7');
    slash.setAttribute('stroke', 'currentColor');
    slash.setAttribute('stroke-width', '2');
    slash.setAttribute('stroke-linecap', 'round');
    slash.setAttribute('fill', 'none');
    svg.append(slash);
  } else {
    const wave = document.createElementNS(SVG_NS, 'path');
    wave.setAttribute('d', 'M16 8.8a4.5 4.5 0 010 6.4M18.6 6a8 8 0 010 12');
    wave.setAttribute('stroke', 'currentColor');
    wave.setAttribute('stroke-width', '1.8');
    wave.setAttribute('stroke-linecap', 'round');
    wave.setAttribute('fill', 'none');
    svg.append(wave);
  }
  return svg;
}

function render(tabs) {
  list.textContent = '';
  empty.hidden = tabs.length > 0;

  for (const tab of tabs) {
    const row = document.createElement('li');
    if (tab.active) row.classList.add('active');

    const icon = document.createElement('img');
    icon.className = tab.favIconUrl ? 'icon' : 'icon blank';
    icon.alt = '';
    if (tab.favIconUrl) {
      icon.src = tab.favIconUrl;
      icon.addEventListener('error', () => icon.classList.add('blank'), { once: true });
    }
    row.append(icon);

    const title = document.createElement('div');
    title.className = 'title';
    title.textContent = tab.title;
    title.title = tab.title;
    row.append(title);

    const pct = document.createElement('div');
    pct.className = 'pct';
    const value = document.createTextNode('');
    pct.append(value);
    if (tab.audible) {
      const dot = document.createElement('span');
      dot.className = 'playing';
      dot.textContent = ' ●';
      dot.title = 'Playing';
      pct.append(dot);
    }
    row.append(pct);

    const wrap = document.createElement('div');
    wrap.className = 'slider';
    const slider = document.createElement('input');
    slider.type = 'range';
    slider.min = '0';
    slider.max = '100';
    slider.step = '1';
    slider.value = String(Math.round(tab.gain * 100));
    slider.disabled = !tab.adjustable;
    slider.setAttribute('aria-label', `Volume for ${tab.title}`);
    paint(slider);
    wrap.append(slider);
    row.append(wrap);

    if (!tab.adjustable) {
      value.nodeValue = 'n/a';
    } else {
      value.nodeValue = `${Math.round(slider.value)}%`;
      if (tab.hooked === false) {
        // Probably a tab that predates the extension being loaded. Flag it, but
        // deliberately leave the slider working: the probe is a single message
        // round-trip and can come back false for uninteresting reasons — a
        // service worker that just woke, a frame that answers late — and a
        // warning that disables the control is worse than no warning at all.
        row.title = 'This tab may not have responded — reload it if the slider has no effect';
        title.style.opacity = '0.75';
      }
    }

    const mute = document.createElement('button');
    mute.type = 'button';
    mute.className = `mute${tab.muted ? ' on' : ''}`;
    mute.append(speakerIcon(tab.muted));
    mute.title = tab.muted ? 'Unmute tab' : 'Mute tab';
    row.append(mute);

    // Live while dragging; the page follows immediately.
    slider.addEventListener('input', () => {
      paint(slider);
      value.nodeValue = `${Math.round(slider.value)}%`;
      send({ type: 'setGain', tabId: tab.id, url: tab.url, gain: Number(slider.value) / 100 });
    });

    mute.addEventListener('click', async () => {
      const next = !mute.classList.contains('on');
      await send({ type: 'setMuted', tabId: tab.id, muted: next });
      mute.classList.toggle('on', next);
      mute.textContent = '';
      mute.append(speakerIcon(next));
      mute.title = next ? 'Unmute tab' : 'Mute tab';
    });

    list.append(row);
  }
}

resetButton.addEventListener('click', async () => {
  await send({ type: 'resetAll' });
  load();
});

async function load() {
  const response = await send({ type: 'listTabs' });
  render(response?.tabs ?? []);
}

load();
