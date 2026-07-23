// ==UserScript==
// @name         Yomiko.debug
// @namespace    https://l.flandre.tw/github
// @version      v1.1.0
// @description  Reading makes a full man
// @author       flandre.tw
// @match        https://exhentai.org/*
// @match        https://e-hentai.org/*
// @icon         https://www.google.com/s2/favicons?sz=64&domain=exhentai.org
// @connect      127.0.0.1
// @connect      __YOMIKO_CONNECT_HOST__
// @noframes
// ==/UserScript==

(async function() {
  'use strict';

  const API_BASE = '__YOMIKO_API_BASE__';
  const API_TOKEN = __YOMIKO_API_TOKEN__;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const checkedGalleryAttr = 'data-yomiko-gid';

  function mutationHeaders() {
    if (!API_TOKEN) {
      return {};
    }

    return { Authorization: `Bearer ${API_TOKEN}` };
  }

  function installStyle() {
    const styleEl = document.createElement('style');
    document.head.appendChild(styleEl);
    styleEl.textContent = `
.yomiko-toast {
  position: fixed;
  top: 12px;
  right: 12px;
  z-index: 2147483647;
  max-width: 320px;
  padding: 10px 12px;
  border-radius: 6px;
  background: rgba(25, 25, 25, 0.92);
  color: #fff;
  font: 13px/1.4 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
}

.gld > .gl1t:is(.📦, .🛖, .⭐) {
  position: relative;
}

.gld > .gl1t:is(.📦, .🛖, .⭐)::after {
  display: grid;
  height: 100%;
  width: 100%;
  position: absolute;
  inset: 0;
  font-size: 4rem;
  align-items: center;
  justify-content: center;
  text-shadow: 1px 1px black, 1px -1px black, -1px 1px black, -1px -1px black;
  visibility: visible;
}

.gld > .gl1t:is(.📦, .🛖, .⭐):hover::after {
  display: none;
}

.gld > .gl1t:is(.🛖:not(.⭐):not(.📦))::after {
  content: "下載ㄌ";
  background-color: hsla(125, 90%, 70%, 0.7);
}

.gld > .gl1t:is(.⭐:not(.📦))::after {
  content: "評分過ㄌ";
  background-color: hsla(65, 90%, 70%, 0.7);
}

.gld > .gl1t:is(.📦)::after {
  content: "封存ㄌ";
  background-color: hsla(0, 0%, 0%, 0.7);
}
`;
  }

  function toast(message) {
    const toastEl = document.createElement('div');
    toastEl.className = 'yomiko-toast';
    toastEl.textContent = message;
    document.body.appendChild(toastEl);
    setTimeout(() => toastEl.remove(), 3000);
  }

  async function refreshCookiesAsHealthcheck() {
    try {
      const resp = await fetch(`${API_BASE}/api/update_cookies.sh`, {
        method: 'POST',
        headers: mutationHeaders(),
        body: document.cookie,
      });

      if (!resp.ok) {
        return false;
      }

      const result = await resp.json().catch(() => null);
      return result?.success === true;
    } catch (err) {
      console.error('Yomiko API unavailable', err);
      return false;
    }
  }

  function extractGid(galleryEl) {
    const linkEl = galleryEl.querySelector('a[href*="/g/"]');
    const href = linkEl?.href ?? '';
    const match = href.match(/\/g\/(\d+)/);
    return match?.[1] ?? '';
  }

  async function fetchGalleryStatuses(gids) {
    const api = new URL(`${API_BASE}/api/galleries.sh`);
    api.searchParams.set('gids', gids.join(','));
    api.searchParams.set('fields', 'gid,self_rating,rated_then_deleted_at,file_path');

    const resp = await fetch(api);
    if (!resp.ok) {
      throw new Error(`Yomiko galleries API returned HTTP ${resp.status}`);
    }

    const result = await resp.json();
    if (result?.success !== true) {
      throw new Error(result?.error ?? 'Yomiko galleries API failed');
    }

    return result.galleries ?? [];
  }

  function applyGalleryStatus(galleryEl, gallery) {
    if (galleryEl.querySelector('.ir:is(.irb,.irr,.irg)')) {
      galleryEl.classList.add('⭐');
    }

    if (!gallery) {
      return;
    }

    if (gallery.self_rating && !gallery.rated_then_deleted_at) {
      galleryEl.classList.add('📦');
    }

    if (gallery.file_path && !gallery.rated_then_deleted_at) {
      galleryEl.classList.add('🛖');
    }
  }

  async function runGalleryPollingLoop() {
    while (true) {
      await sleep(1000);

      const uncheckedGalleryEls = Array.from(document.querySelectorAll(`.gl1t:not([${checkedGalleryAttr}])`));
      if (uncheckedGalleryEls.length === 0) {
        continue;
      }

      const gids = [];
      for (const galleryEl of uncheckedGalleryEls) {
        const gid = extractGid(galleryEl);
        if (!gid) {
          galleryEl.setAttribute(checkedGalleryAttr, '');
          continue;
        }

        galleryEl.setAttribute(checkedGalleryAttr, gid);
        gids.push(gid);
      }

      if (gids.length === 0) {
        continue;
      }

      try {
        const galleries = await fetchGalleryStatuses(gids);
        const gidGalleryMap = new Map(galleries.map((gallery) => [String(gallery.gid), gallery]));

        for (const galleryEl of uncheckedGalleryEls) {
          const gid = galleryEl.getAttribute(checkedGalleryAttr);
          applyGalleryStatus(galleryEl, gidGalleryMap.get(gid));
        }
      } catch (err) {
        console.error('Yomiko gallery status request failed', err);
        toast('Yomiko API down');
        return;
      }
    }
  }

  installStyle();

  const apiHealthy = await refreshCookiesAsHealthcheck();
  if (!apiHealthy) {
    toast('Yomiko API down');
    return;
  }

  await runGalleryPollingLoop();
})();
