// ==UserScript==
// @name         Yomiko.debug
// @namespace    https://l.flandre.tw/github
// @version      v1.0.0
// @description  Reading makes a full man
// @author       flandre.tw
// @require      https://unpkg.com/winkblue/dist/winkblue.umd.js
// @match        https://exhentai.org/*
// @match        https://e-hentai.org/*
// @icon         https://www.google.com/s2/favicons?sz=64&domain=exhentai.org
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      __YOMIKO_CONNECT_HOST__
// ==/UserScript==

(async function() {
  'use strict';
  /* global Winkblue */
  console.log('Yomiko.debug',document.cookie);
  const API_BASE = '__YOMIKO_API_BASE__';
  // curl -X POST "${API_BASE}/api/update_cookies.sh" -d 'ipb_member_id=123456; ipb_pass_hash=xxx; igneous=xxx'
  const resp = await fetch(`${API_BASE}/api/update_cookies.sh`, {
    method: 'POST',
    body: document.cookie,
  });
  console.log('resp', resp);
})();
