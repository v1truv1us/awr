// URLSearchParams polyfill — required by spec/subspecs/agent-browser.md §2.
//
// QuickJS-NG does not ship URLSearchParams (it's a WHATWG/browser API,
// not part of ES). The fetch() and XHR polyfills accept URLSearchParams
// bodies and stringify them to application/x-www-form-urlencoded; without
// this polyfill, callers cannot construct that body shape.
//
// Surface implemented: append, set, get, has, delete, getAll, toString,
// entries/keys/values iterators, size, forEach, Symbol.iterator. String
// and array-of-pairs init forms. `sort()` is omitted (not in MVP scope).
(function () {
  if (typeof globalThis.URLSearchParams === 'function') return;
  function pctEncode(s) {
    return encodeURIComponent(String(s)).replace(/%20/g, '+').replace(/!/g, '%21')
      .replace(/'/g, '%27').replace(/\(/g, '%28').replace(/\)/g, '%29').replace(/~/g, '%7E');
  }
  function pctDecode(s) {
    return decodeURIComponent(String(s).replace(/\+/g, ' '));
  }
  function parseQuery(q) {
    var out = [];
    if (q.length > 0 && q.charAt(0) === '?') q = q.slice(1);
    if (q.length === 0) return out;
    var pairs = q.split('&');
    for (var i = 0; i < pairs.length; i++) {
      var pair = pairs[i];
      if (pair.length === 0) continue;
      var eq = pair.indexOf('=');
      var k = eq < 0 ? pair : pair.slice(0, eq);
      var v = eq < 0 ? '' : pair.slice(eq + 1);
      out.push([pctDecode(k), pctDecode(v)]);
    }
    return out;
  }
  function URLSearchParams(init) {
    if (!(this instanceof URLSearchParams)) return new URLSearchParams(init);
    this._items = [];
    if (init == null) return;
    if (typeof init === 'string') {
      this._items = parseQuery(init);
      return;
    }
    if (Array.isArray(init)) {
      for (var i = 0; i < init.length; i++) {
        var p = init[i];
        if (!p || p.length !== 2) throw new TypeError('URLSearchParams: pair must have length 2');
        this._items.push([String(p[0]), String(p[1])]);
      }
      return;
    }
    if (typeof init === 'object') {
      for (var k in init) {
        if (Object.prototype.hasOwnProperty.call(init, k)) {
          this._items.push([String(k), String(init[k])]);
        }
      }
      return;
    }
    throw new TypeError('URLSearchParams: invalid init');
  }
  URLSearchParams.prototype.append = function (name, value) {
    this._items.push([String(name), String(value)]);
  };
  URLSearchParams.prototype.delete = function (name) {
    name = String(name);
    var kept = [];
    for (var i = 0; i < this._items.length; i++) {
      if (this._items[i][0] !== name) kept.push(this._items[i]);
    }
    this._items = kept;
  };
  URLSearchParams.prototype.get = function (name) {
    name = String(name);
    for (var i = 0; i < this._items.length; i++) {
      if (this._items[i][0] === name) return this._items[i][1];
    }
    return null;
  };
  URLSearchParams.prototype.getAll = function (name) {
    name = String(name);
    var out = [];
    for (var i = 0; i < this._items.length; i++) {
      if (this._items[i][0] === name) out.push(this._items[i][1]);
    }
    return out;
  };
  URLSearchParams.prototype.has = function (name) {
    name = String(name);
    for (var i = 0; i < this._items.length; i++) {
      if (this._items[i][0] === name) return true;
    }
    return false;
  };
  URLSearchParams.prototype.set = function (name, value) {
    name = String(name); value = String(value);
    var found = false;
    var kept = [];
    for (var i = 0; i < this._items.length; i++) {
      if (this._items[i][0] === name) {
        if (!found) { kept.push([name, value]); found = true; }
      } else {
        kept.push(this._items[i]);
      }
    }
    if (!found) kept.push([name, value]);
    this._items = kept;
  };
  URLSearchParams.prototype.toString = function () {
    var parts = [];
    for (var i = 0; i < this._items.length; i++) {
      parts.push(pctEncode(this._items[i][0]) + '=' + pctEncode(this._items[i][1]));
    }
    return parts.join('&');
  };
  URLSearchParams.prototype.forEach = function (fn, thisArg) {
    for (var i = 0; i < this._items.length; i++) {
      fn.call(thisArg, this._items[i][1], this._items[i][0], this);
    }
  };
  function makeIterator(items, kind) {
    var idx = 0;
    var it = {
      next: function () {
        if (idx >= items.length) return { value: undefined, done: true };
        var pair = items[idx++];
        var v = kind === 'keys' ? pair[0] : kind === 'values' ? pair[1] : [pair[0], pair[1]];
        return { value: v, done: false };
      },
    };
    it[Symbol.iterator] = function () { return it; };
    return it;
  }
  URLSearchParams.prototype.entries = function () { return makeIterator(this._items, 'entries'); };
  URLSearchParams.prototype.keys = function () { return makeIterator(this._items, 'keys'); };
  URLSearchParams.prototype.values = function () { return makeIterator(this._items, 'values'); };
  URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;
  Object.defineProperty(URLSearchParams.prototype, 'size', {
    get: function () { return this._items.length; },
  });
  globalThis.URLSearchParams = URLSearchParams;
})();
