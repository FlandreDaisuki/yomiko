// ==UserScript==
// @name         __YOMIKO_USERSCRIPT_NAME__
// @namespace    https://l.flandre.tw/github
// @version      1.4.0
// @description  Reading makes a full man (server __YOMIKO_BUILD_VERSION__)
// @author       flandre.tw
// @match        https://exhentai.org/*
// @match        https://e-hentai.org/*
// @icon         __YOMIKO_API_BASE__/favicon.webp
// @connect      127.0.0.1
// @connect      __YOMIKO_CONNECT_HOST__
// @noframes
// ==/UserScript==

(async function() {
  'use strict';

  const API_BASE = '__YOMIKO_API_BASE__';
  const API_TOKEN = '__YOMIKO_API_TOKEN__';
  const COOKIE_REFRESH_INTERVAL_MS = 2 * 60 * 60 * 1000; // 2hr
  const COOKIE_REFRESH_ATTEMPTED_AT_KEY = 'yomiko-cookie-refresh-attempted-at';
  const GALLERY_POLL_INTERVAL_MS = 500;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const checkedGalleryAttr = 'data-yomiko-gid';
  let fallbackCookieRefreshAttemptedAt = 0;

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

.gld > .gl1t[data-yomiko-state] {
  position: relative;
}

.gld > .gl1t[data-yomiko-state]::after {
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
  content: attr(data-yomiko-label);
}

.gld > .gl1t[data-yomiko-state]:hover::after {
  display: none;
}

.gld > .gl1t[data-yomiko-state="hath_requested"]::after {
  background-color: hsla(210, 90%, 70%, 0.7);
}

.gld > .gl1t[data-yomiko-state="downloaded_unrated"]::after {
  background-color: hsla(125, 90%, 70%, 0.7);
}

.gld > .gl1t[data-yomiko-state="rated_non_11"]::after {
  background-color: hsla(65, 90%, 70%, 0.7);
}

.gld > .gl1t[data-yomiko-state="rated_11_canonical"]::after {
  background-color: hsla(0, 0%, 0%, 0.7);
}

.gld > .gl1t[data-yomiko-state="rated_11_alternate"]::after {
  background-color: hsla(280, 90%, 70%, 0.7);
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

  function lastCookieRefreshAttemptedAt() {
    try {
      const storedValue = Number(localStorage.getItem(COOKIE_REFRESH_ATTEMPTED_AT_KEY));
      return Number.isFinite(storedValue) ? storedValue : fallbackCookieRefreshAttemptedAt;
    } catch (err) {
      console.warn('Yomiko cannot read the cookie refresh guard', err);
      return fallbackCookieRefreshAttemptedAt;
    }
  }

  function cookieRefreshDelay() {
    const elapsed = Date.now() - lastCookieRefreshAttemptedAt();
    if (elapsed < 0 || elapsed >= COOKIE_REFRESH_INTERVAL_MS) {
      return 0;
    }

    return COOKIE_REFRESH_INTERVAL_MS - elapsed;
  }

  function claimCookieRefresh() {
    if (cookieRefreshDelay() > 0) {
      return false;
    }

    const attemptedAt = Date.now();
    fallbackCookieRefreshAttemptedAt = attemptedAt;
    try {
      localStorage.setItem(COOKIE_REFRESH_ATTEMPTED_AT_KEY, String(attemptedAt));
    } catch (err) {
      console.warn('Yomiko cannot persist the cookie refresh guard', err);
    }
    return true;
  }

  async function refreshCookiesIfDue() {
    if (!claimCookieRefresh()) {
      return true;
    }

    return refreshCookiesAsHealthcheck();
  }

  async function runCookieRefreshLoop() {
    while (true) {
      await sleep(cookieRefreshDelay());
      if (!await refreshCookiesIfDue()) {
        toast('Yomiko API down');
      }
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

    const resp = await fetch(api);
    if (!resp.ok) {
      throw new Error(`Yomiko galleries API returned HTTP ${resp.status}`);
    }

    const result = await resp.json();
    if (result?.success !== true || !Array.isArray(result.galleries)) {
      throw new Error(result?.error ?? 'Yomiko galleries API failed');
    }

    if (result.projection_version !== undefined && result.projection_version !== 2) {
      throw new Error('Yomiko galleries API contract is incompatible');
    }

    return result.galleries;
  }

  function applyGalleryStatus(galleryEl, gallery) {
    const allowedStates = new Set([
      'hath_requested', 'downloaded_unrated', 'rated_non_11',
      'rated_11_canonical', 'rated_11_alternate', 'no_local_state', 'unknown',
    ]);
    const state = gallery?.state;
    const selfRating = gallery?.self_rating;
    if (!gallery || !allowedStates.has(state) ||
      (state !== 'unknown' && (!Number.isInteger(selfRating) || selfRating < 0 || selfRating > 11))) {
      galleryEl.removeAttribute('data-yomiko-state');
      galleryEl.removeAttribute('data-yomiko-label');
      galleryEl.removeAttribute('data-yomiko-acquisition');
      return;
    }

    if (state === 'unknown' || state === 'no_local_state') {
      galleryEl.removeAttribute('data-yomiko-state');
      galleryEl.removeAttribute('data-yomiko-label');
    } else {
      const labels = {
        hath_requested: '請求過ㄌ',
        downloaded_unrated: gallery.local_state_relation === 'same_book' ? '同本下載ㄌ' : '下載ㄌ',
        rated_non_11: `評分 ${selfRating}`,
        rated_11_canonical: '封存ㄌ',
        rated_11_alternate: '替代本',
      };
      galleryEl.setAttribute('data-yomiko-state', state);
      galleryEl.setAttribute('data-yomiko-label', labels[state] ?? 'Yomiko');
    }
    if (gallery.acquisition_state) {
      galleryEl.setAttribute('data-yomiko-acquisition',
        `${gallery.acquisition_state}:${gallery.local_state_relation ?? 'exact'}`);
    } else {
      galleryEl.removeAttribute('data-yomiko-acquisition');
    }
  }

  async function runGalleryPollingLoop() {
    while (true) {
      await sleep(GALLERY_POLL_INTERVAL_MS);

      const uncheckedGalleryEls = Array.from(document.querySelectorAll(`.gl1t:not([${checkedGalleryAttr}])`));
      if (uncheckedGalleryEls.length === 0) {
        continue;
      }

      const gids = [];
      const seenGids = new Set();
      for (const galleryEl of uncheckedGalleryEls) {
        const gid = extractGid(galleryEl);
        if (!gid) {
          galleryEl.setAttribute(checkedGalleryAttr, '');
          continue;
        }

        galleryEl.setAttribute(checkedGalleryAttr, gid);
        if (!seenGids.has(gid)) {
          seenGids.add(gid);
          gids.push(gid);
        }
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
        for (const galleryEl of uncheckedGalleryEls) {
          galleryEl.removeAttribute(checkedGalleryAttr);
        }
      }
    }
  }

  installStyle();

  const apiHealthy = await refreshCookiesIfDue();
  if (!apiHealthy) {
    toast('Yomiko API down');
    return;
  }

  void runCookieRefreshLoop();
  await runGalleryPollingLoop();
})();
