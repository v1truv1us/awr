// modern_globals.js — web-platform global constructors QuickJS-NG omits that
// SPA bundles reference at module-load time. Without these the bundle throws a
// ReferenceError on its first line and never runs, so the page renders as a
// blank shell. These are pure-JS polyfills built on primitives the engine
// already provides (timers, URLSearchParams, Text*); none mutate the DOM tree,
// so they cannot regress rendering. Each is guarded so reset() re-running this
// file is idempotent and a native impl (if ever added) wins.
//
// Anything that needs the DOM bridge (DOMParser) only touches `document` inside
// a method body, never at definition time — the bridge installs after this.
(function () {
  'use strict';
  var G = globalThis;
  function def(name, value) {
    if (typeof G[name] === 'undefined') G[name] = value;
  }

  // ── EventTarget ──────────────────────────────────────────────────────────
  def('EventTarget', (function () {
    function EventTarget() { this.__l = Object.create(null); }
    EventTarget.prototype.addEventListener = function (t, cb) {
      if (!cb) return;
      (this.__l[t] || (this.__l[t] = [])).push(cb);
    };
    EventTarget.prototype.removeEventListener = function (t, cb) {
      var a = this.__l[t]; if (!a) return;
      var i = a.indexOf(cb); if (i >= 0) a.splice(i, 1);
    };
    EventTarget.prototype.dispatchEvent = function (ev) {
      var a = this.__l[ev && ev.type]; if (!a) return true;
      for (var i = 0; i < a.length; i++) { try { a[i].call(this, ev); } catch (e) {} }
      return !(ev && ev.defaultPrevented);
    };
    return EventTarget;
  })());

  // ── Observers — no-op stubs (no layout/viewport in a terminal) ───────────
  function makeObserver() {
    function Obs(cb) { this._cb = cb; }
    Obs.prototype.observe = function () {};
    Obs.prototype.unobserve = function () {};
    Obs.prototype.disconnect = function () {};
    Obs.prototype.takeRecords = function () { return []; };
    return Obs;
  }
  def('IntersectionObserver', makeObserver());
  def('ResizeObserver', makeObserver());
  def('PerformanceObserver', (function () {
    var O = makeObserver();
    O.supportedEntryTypes = [];
    return O;
  })());

  // ── requestIdleCallback — run soon via the timer queue ───────────────────
  def('requestIdleCallback', function (cb) {
    return setTimeout(function () {
      cb({ didTimeout: false, timeRemaining: function () { return 0; } });
    }, 1);
  });
  def('cancelIdleCallback', function (id) { clearTimeout(id); });

  // ── AbortController / AbortSignal ────────────────────────────────────────
  def('AbortSignal', (function () {
    function AbortSignal() { this.aborted = false; this.reason = undefined; this.__l = []; this.onabort = null; }
    AbortSignal.prototype.addEventListener = function (t, cb) { if (t === 'abort') this.__l.push(cb); };
    AbortSignal.prototype.removeEventListener = function (t, cb) {
      if (t !== 'abort') return; var i = this.__l.indexOf(cb); if (i >= 0) this.__l.splice(i, 1);
    };
    AbortSignal.prototype.dispatchEvent = function () { return true; };
    AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
    AbortSignal.abort = function (reason) { var s = new AbortSignal(); s.aborted = true; s.reason = reason; return s; };
    AbortSignal.timeout = function () { return new AbortSignal(); };
    return AbortSignal;
  })());
  def('AbortController', (function () {
    function AbortController() { this.signal = new G.AbortSignal(); }
    AbortController.prototype.abort = function (reason) {
      var s = this.signal; if (s.aborted) return;
      s.aborted = true; s.reason = reason !== undefined ? reason : new Error('Aborted');
      var ev = { type: 'abort' };
      if (typeof s.onabort === 'function') { try { s.onabort(ev); } catch (e) {} }
      for (var i = 0; i < s.__l.length; i++) { try { s.__l[i](ev); } catch (e) {} }
    };
    return AbortController;
  })());

  // ── TextEncoder / TextDecoder (UTF-8) ────────────────────────────────────
  def('TextEncoder', (function () {
    function TextEncoder() { this.encoding = 'utf-8'; }
    TextEncoder.prototype.encode = function (str) {
      str = String(str === undefined ? '' : str);
      var out = [];
      for (var i = 0; i < str.length; i++) {
        var c = str.charCodeAt(i);
        if (c < 0x80) out.push(c);
        else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
        else if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) {
          var c2 = str.charCodeAt(++i);
          var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
          out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        } else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
      }
      return new Uint8Array(out);
    };
    TextEncoder.prototype.encodeInto = function (str, dest) {
      var enc = this.encode(str); var n = Math.min(enc.length, dest.length);
      dest.set(enc.subarray(0, n)); return { read: str.length, written: n };
    };
    return TextEncoder;
  })());
  def('TextDecoder', (function () {
    function TextDecoder(label) { this.encoding = label || 'utf-8'; this.fatal = false; }
    TextDecoder.prototype.decode = function (buf) {
      if (!buf) return '';
      var b = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf);
      var out = '', i = 0;
      while (i < b.length) {
        var c = b[i++];
        if (c < 0x80) out += String.fromCharCode(c);
        else if (c < 0xe0) out += String.fromCharCode(((c & 0x1f) << 6) | (b[i++] & 0x3f));
        else if (c < 0xf0) out += String.fromCharCode(((c & 0x0f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f));
        else {
          var cp = ((c & 0x07) << 18) | ((b[i++] & 0x3f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f);
          cp -= 0x10000;
          out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        }
      }
      return out;
    };
    return TextDecoder;
  })());

  // ── URL — absolute + relative resolution (search via URLSearchParams) ────
  def('URL', (function () {
    var RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(\/\/(?:([^/?#@]*)@)?([^/?#:]*)(?::(\d+))?)?([^?#]*)(\?[^#]*)?(#.*)?$/;
    function resolve(url, base) {
      url = String(url);
      if (RE.exec(url)[1]) return url; // already absolute
      if (!base) throw new TypeError("Invalid URL: " + url);
      var b = RE.exec(String(base));
      var origin = (b[1] || '') + (b[2] || '');
      var basePath = b[6] || '/';
      if (url.charAt(0) === '/') return origin + url;
      if (url.charAt(0) === '?') return origin + basePath + url;
      if (url.charAt(0) === '#') return origin + basePath + (b[7] ? '' : '') + url;
      var dir = basePath.slice(0, basePath.lastIndexOf('/') + 1);
      var parts = (dir + url).split('/'), stack = [];
      for (var i = 0; i < parts.length; i++) {
        if (parts[i] === '..') stack.pop();
        else if (parts[i] !== '.') stack.push(parts[i]);
      }
      return origin + stack.join('/');
    }
    function URL(url, base) {
      var m = RE.exec(resolve(url, base));
      this.protocol = m[1] || '';
      this.hostname = m[4] || '';
      this.port = m[5] || '';
      this.host = this.hostname + (this.port ? ':' + this.port : '');
      this.pathname = m[6] || '/';
      this.search = m[7] || '';
      this.hash = m[8] || '';
      this.username = ''; this.password = '';
      this.origin = this.protocol && this.host ? this.protocol + '//' + this.host : 'null';
      this.searchParams = new G.URLSearchParams(this.search);
    }
    Object.defineProperty(URL.prototype, 'href', {
      get: function () {
        var s = this.searchParams.toString();
        return (this.protocol ? this.protocol : '') + (this.host ? '//' + this.host : '') +
          this.pathname + (s ? '?' + s : '') + (this.hash || '');
      },
      set: function (v) { URL.call(this, v); }
    });
    URL.prototype.toString = function () { return this.href; };
    URL.prototype.toJSON = function () { return this.href; };
    URL.createObjectURL = function () { return 'blob:awr/' + Math.floor(1e9 * 0.5); };
    URL.revokeObjectURL = function () {};
    return URL;
  })());

  // ── Blob ─────────────────────────────────────────────────────────────────
  def('Blob', (function () {
    function Blob(parts, opts) {
      this.__parts = (parts || []).map(function (p) { return typeof p === 'string' ? p : String(p); });
      this.__s = this.__parts.join('');
      this.size = this.__s.length;
      this.type = (opts && opts.type) || '';
    }
    Blob.prototype.text = function () { return Promise.resolve(this.__s); };
    Blob.prototype.arrayBuffer = function () { return Promise.resolve(new G.TextEncoder().encode(this.__s).buffer); };
    Blob.prototype.slice = function () { return new Blob([this.__s]); };
    return Blob;
  })());

  // ── Headers ──────────────────────────────────────────────────────────────
  def('Headers', (function () {
    function Headers(init) {
      this.__m = Object.create(null);
      if (init) {
        if (typeof init.forEach === 'function' && !Array.isArray(init)) init.forEach(function (v, k) { this.append(k, v); }, this);
        else if (Array.isArray(init)) init.forEach(function (p) { this.append(p[0], p[1]); }, this);
        else for (var k in init) this.append(k, init[k]);
      }
    }
    Headers.prototype.append = function (k, v) { k = String(k).toLowerCase(); this.__m[k] = this.__m[k] != null ? this.__m[k] + ', ' + v : String(v); };
    Headers.prototype.set = function (k, v) { this.__m[String(k).toLowerCase()] = String(v); };
    Headers.prototype.get = function (k) { var v = this.__m[String(k).toLowerCase()]; return v == null ? null : v; };
    Headers.prototype.has = function (k) { return String(k).toLowerCase() in this.__m; };
    Headers.prototype['delete'] = function (k) { delete this.__m[String(k).toLowerCase()]; };
    Headers.prototype.forEach = function (cb, thisArg) { for (var k in this.__m) cb.call(thisArg, this.__m[k], k, this); };
    Headers.prototype.keys = function () { return Object.keys(this.__m); };
    return Headers;
  })());

  // ── Request / Response (construct + body accessors) ──────────────────────
  def('Request', (function () {
    function Request(input, init) {
      init = init || {};
      this.url = typeof input === 'string' ? input : (input && input.url) || '';
      this.method = (init.method || (input && input.method) || 'GET').toUpperCase();
      this.headers = new G.Headers(init.headers || (input && input.headers));
      this.__body = init.body != null ? init.body : (input && input.__body);
      this.credentials = init.credentials || 'same-origin';
      this.mode = init.mode || 'cors';
      this.signal = init.signal || null;
    }
    Request.prototype.clone = function () { return new Request(this); };
    return Request;
  })());
  def('Response', (function () {
    function Response(body, init) {
      init = init || {};
      this.__body = body == null ? '' : (typeof body === 'string' ? body : String(body));
      this.status = init.status != null ? init.status : 200;
      this.statusText = init.statusText || '';
      this.ok = this.status >= 200 && this.status < 300;
      this.headers = new G.Headers(init.headers);
      this.url = init.url || '';
      this.redirected = false;
      this.type = 'basic';
      this.bodyUsed = false;
    }
    Response.prototype.text = function () { this.bodyUsed = true; return Promise.resolve(this.__body); };
    Response.prototype.json = function () { this.bodyUsed = true; var b = this.__body; return Promise.resolve(JSON.parse(b)); };
    Response.prototype.arrayBuffer = function () { return Promise.resolve(new G.TextEncoder().encode(this.__body).buffer); };
    Response.prototype.blob = function () { return Promise.resolve(new G.Blob([this.__body])); };
    Response.prototype.clone = function () { return new Response(this.__body, { status: this.status, statusText: this.statusText }); };
    Response.error = function () { return new Response('', { status: 0 }); };
    Response.json = function (data, init) { return new Response(JSON.stringify(data), init); };
    return Response;
  })());

  // ── FormData ─────────────────────────────────────────────────────────────
  def('FormData', (function () {
    function FormData() { this.__e = []; }
    FormData.prototype.append = function (k, v) { this.__e.push([String(k), typeof v === 'string' ? v : String(v)]); };
    FormData.prototype.set = function (k, v) { this['delete'](k); this.append(k, v); };
    FormData.prototype.get = function (k) { for (var i = 0; i < this.__e.length; i++) if (this.__e[i][0] === k) return this.__e[i][1]; return null; };
    FormData.prototype.getAll = function (k) { return this.__e.filter(function (e) { return e[0] === k; }).map(function (e) { return e[1]; }); };
    FormData.prototype.has = function (k) { return this.__e.some(function (e) { return e[0] === k; }); };
    FormData.prototype['delete'] = function (k) { this.__e = this.__e.filter(function (e) { return e[0] !== k; }); };
    FormData.prototype.forEach = function (cb, thisArg) { this.__e.forEach(function (e) { cb.call(thisArg, e[1], e[0], this); }, this); };
    FormData.prototype.entries = function () { return this.__e.slice(); };
    FormData.prototype.keys = function () { return this.__e.map(function (e) { return e[0]; }); };
    FormData.prototype.toString = function () {
      return this.__e.map(function (e) { return encodeURIComponent(e[0]) + '=' + encodeURIComponent(e[1]); }).join('&');
    };
    return FormData;
  })());

  // ── getSelection — no selection model in a terminal ──────────────────────
  if (typeof G.getSelection === 'undefined') {
    G.getSelection = function () {
      return { rangeCount: 0, isCollapsed: true, type: 'None', toString: function () { return ''; },
        removeAllRanges: function () {}, addRange: function () {}, getRangeAt: function () { return null; },
        collapse: function () {}, selectAllChildren: function () {} };
    };
  }

  // ── customElements — registry stub (define keeps the bundle alive) ───────
  def('customElements', (function () {
    var reg = Object.create(null);
    return {
      define: function (name, ctor) { reg[name] = ctor; },
      get: function (name) { return reg[name]; },
      whenDefined: function () { return Promise.resolve(); },
      upgrade: function () {}
    };
  })());

  // ── DOMParser — parse via a detached element (uses the bridge at call) ───
  def('DOMParser', (function () {
    function DOMParser() {}
    DOMParser.prototype.parseFromString = function (str, type) {
      var root = G.document.createElement(/xml|svg/.test(type || '') ? 'div' : 'body');
      root.innerHTML = String(str);
      return {
        body: root, documentElement: root, nodeType: 9,
        querySelector: function (s) { return root.querySelector(s); },
        querySelectorAll: function (s) { return root.querySelectorAll(s); },
        getElementById: function (id) { return root.querySelector('#' + id); },
        getElementsByTagName: function (t) { return root.querySelectorAll(t); },
        createElement: function (t) { return G.document.createElement(t); }
      };
    };
    return DOMParser;
  })());
})();
