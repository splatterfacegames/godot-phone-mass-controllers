// pmc.js - phone controller SDK for godot-phone-mass-controllers (MIT).
// Zero-dependency ES module served by the Godot host at /pmc/pmc.js. Types: pmc.d.ts.
// Wire protocol: SPEC.md section 2.

const PING_MS = 5000;
const DEAD_MS = 16000; // no pong for this long => the socket is dead
const HELLO_TIMEOUT_MS = 10000;
const BACKOFF_BASE_MS = 250;
const BACKOFF_CAP_MS = 5000;
const FATAL_CLOSE = [4000, 4001, 4002]; // reject, kicked, replaced: never retry

/**
 * Connect to the host that served this page.
 * @param {{name?: string, profile?: object, code?: string, url?: string, tokenKey?: string}} [opts]
 */
export function connect(opts = {}) {
  return new PMCClient(opts);
}

export class PMCClient {
  constructor(opts = {}) {
    const loc = globalThis.location;
    this.id = null;
    this.name = opts.name ?? '';
    this.profile = opts.profile ?? {};
    this.admin = false;
    this.joinUrl = '';
    /** @type {'connecting'|'open'|'reconnecting'|'closed'} */
    this.status = 'closed';
    this.code = opts.code ?? new URLSearchParams(loc?.search).get('code') ?? '';
    this.url = opts.url ?? `${loc.protocol === 'https:' ? 'wss:' : 'ws:'}//${loc.host}/pmc/ws`;
    this._key = opts.tokenKey ?? 'pmc.token:' + new URL(this.url).host;
    this._on = new Map();
    this._ws = null;
    this._attempt = 0;
    this._timers = {};
    this._offsets = [];
    this._offset = 0;
    this._rtts = [];
    this._lastPong = 0;
    this._authWaiters = [];
    this._stopped = false;
    // Mobile browsers freeze sockets in background tabs; check or reconnect as soon as we're back.
    globalThis.document?.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'visible' || this._stopped) return;
      if (this.status === 'open') this._ping();
      else if (!this._ws) this._open();
    });
    queueMicrotask(() => this._open()); // lets callers attach handlers first
  }

  /** Stored rejoin token ('' if none). */
  get token() {
    try { return localStorage.getItem(this._key) ?? ''; } catch { return ''; }
  }
  set token(v) {
    try { v ? localStorage.setItem(this._key, v) : localStorage.removeItem(this._key); } catch {}
  }

  /** Events: welcome, message, binary, status, reject, kicked, replaced, auth, moved. */
  on(ev, fn) {
    if (!this._on.has(ev)) this._on.set(ev, new Set());
    this._on.get(ev).add(fn);
    return this;
  }

  off(ev, fn) {
    this._on.get(ev)?.delete(fn);
    return this;
  }

  _emit(ev, arg) {
    for (const fn of [...(this._on.get(ev) ?? [])]) {
      try { fn(arg); } catch (e) { console.error(`[pmc] ${ev} handler threw`, e); }
    }
  }

  /** Send a JSON game message. Returns false (dropped, not queued) when not connected. */
  send(data) {
    return this._send({ t: 'msg', d: data });
  }

  /** Send a binary frame (ArrayBuffer, typed array or Blob), passed to the host untouched. */
  sendBinary(data) {
    if (this.status !== 'open') return false;
    this._ws.send(data);
    return true;
  }

  /** Admin elevation. @returns {Promise<boolean>} false on a wrong PIN, lockout or disconnect. */
  auth(pin) {
    return new Promise((resolve) => {
      if (this._send({ t: 'pmc.auth', pin: String(pin) })) this._authWaiters.push(resolve);
      else resolve(false);
    });
  }

  /** Update name and/or profile now and for future hellos. */
  setProfile({ name, profile } = {}) {
    const m = { t: 'pmc.profile' };
    if (name !== undefined) this.name = m.name = name;
    if (profile !== undefined) this.profile = m.profile = profile;
    this._send(m);
  }

  /** Explicit leave (no grace period). Stops reconnecting; keeps the token. */
  leave() {
    this._send({ t: 'pmc.leave' });
    this._stop();
  }

  /** Start again after the client stopped (reject, kick, replaced, leave). */
  reconnect() {
    this._stopped = false;
    if (!this._ws) this._open();
  }

  /** Host clock in Unix epoch ms (median offset of the last 5 ping/pong samples). */
  serverNow() {
    return Date.now() + this._offset;
  }

  /**
   * Host-clock timestamp for stamping inputs, e.g. `pmc.send({type: 'buzz', at: pmc.timestamp()})`.
   * Lets the host order competing inputs fairly; compensation is bounded by each player's RTT.
   */
  timestamp() {
    return this.serverNow();
  }

  /** Rolling average round-trip time in ms from ping/pong (0 until the first pong). */
  get rttMs() {
    if (!this._rtts.length) return 0;
    return Math.round(this._rtts.reduce((a, b) => a + b, 0) / this._rtts.length);
  }

  _send(obj, force = false) {
    if (!force && this.status !== 'open') return false;
    try { this._ws.send(JSON.stringify(obj)); return true; } catch { return false; }
  }

  _setStatus(s) {
    if (s !== this.status) this._emit('status', (this.status = s));
  }

  _clearTimers() {
    for (const t of Object.values(this._timers)) { clearTimeout(t); clearInterval(t); }
    this._timers = {};
  }

  _open() {
    this._clearTimers();
    this._setStatus(this._attempt ? 'reconnecting' : 'connecting');
    let ws;
    try { ws = this._ws = new WebSocket(this.url); } catch { return this._retry(); }
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => {
      const hello = { t: 'pmc.hello', sdk: 1 };
      for (const k of ['token', 'name', 'code']) if (this[k]) hello[k] = this[k];
      if (Object.keys(this.profile ?? {}).length) hello.profile = this.profile;
      this._send(hello, true);
      this._timers.hello = setTimeout(() => this._drop(ws), HELLO_TIMEOUT_MS);
    };
    ws.onmessage = (e) => ws === this._ws && this._onMessage(e.data);
    ws.onclose = (e) => {
      if (ws !== this._ws) return;
      if (this._stopped || FATAL_CLOSE.includes(e.code)) this._stop();
      else this._drop(ws);
    };
  }

  // Abandon a socket without waiting for its close handshake (frozen sockets can take ages).
  _drop(ws) {
    if (ws !== this._ws) return;
    this._ws = null;
    try { ws.close(); } catch {}
    this._flushAuth();
    this._retry();
  }

  _onMessage(data) {
    if (typeof data !== 'string') return this._emit('binary', data);
    let m;
    try { m = JSON.parse(data); } catch { return; }
    switch (m.t) {
      case 'msg': return this._emit('message', m.d);
      case 'pmc.welcome':
        clearTimeout(this._timers.hello);
        this._attempt = 0;
        this.token = m.token;
        // The host accepts this cookie (or ?t=) on gated custom routes.
        try { globalThis.document && (document.cookie = `pmc_token=${m.token}; path=/; SameSite=Strict`); } catch {}
        Object.assign(this, { id: m.id, name: m.name ?? this.name, profile: m.profile ?? this.profile, admin: !!m.admin, joinUrl: m.join_url ?? '' });
        if (!this._offsets.length && typeof m.server_ms === 'number') this._offset = m.server_ms - Date.now();
        this._lastPong = Date.now();
        this._timers.ping = setInterval(() => this._ping(), PING_MS);
        this._setStatus('open');
        this._ping();
        return this._emit('welcome', m);
      case 'pmc.pong': return this._onPong(m);
      case 'pmc.auth':
        if (m.ok) this.admin = true;
        this._authWaiters.shift()?.(!!m.ok);
        return this._emit('auth', !!m.ok);
      case 'pmc.reject': this._stopped = true; return this._emit('reject', { code: m.code, reason: m.reason });
      case 'pmc.kicked': this._stopped = true; return this._emit('kicked', m.reason ?? '');
      case 'pmc.replaced': this._stopped = true; return this._emit('replaced');
      case 'pmc.moved': return this._onMoved(m.d?.url);
    }
  }

  _ping() {
    if (this.status !== 'open') return;
    if (Date.now() - this._lastPong > DEAD_MS) return this._drop(this._ws);
    this._send({ t: 'pmc.ping', c: Date.now() });
  }

  _onPong({ c, s }) {
    const now = Date.now();
    this._lastPong = now;
    if (typeof c !== 'number' || typeof s !== 'number') return;
    this._rtts = [...this._rtts, now - c].slice(-5);
    // Symmetric latency: the host clock at `now` is s + rtt/2. (s is Unix epoch ms.)
    this._offsets = [...this._offsets, s + (now - c) / 2 - now].slice(-5);
    const o = [...this._offsets].sort((a, b) => a - b), mid = o.length >> 1;
    this._offset = o.length % 2 ? o[mid] : (o[mid - 1] + o[mid]) / 2;
  }

  // The join URL moved (the host sends this before an ephemeral tunnel URL dies). Surface the
  // 'moved' event so the page can ask for a re-scan. Auto-follow only https→https after a
  // reachability check — never silently navigate a LAN (http) page.
  _onMoved(url) {
    this._emit('moved', { url: typeof url === 'string' ? url : '' });
    const loc = globalThis.location;
    if (!loc || loc.protocol !== 'https:' || typeof url !== 'string' || !url) return;
    let next;
    try { next = new URL(url, loc.href); } catch { return; }
    if (next.protocol !== 'https:' || next.origin === loc.origin) return;
    globalThis.fetch?.(next.href, { mode: 'no-cors', cache: 'no-store' })
      .then(() => loc.replace(next.href))
      .catch(() => {});
  }

  _retry() {
    this._clearTimers();
    this._setStatus('reconnecting');
    // Exponential backoff with "equal jitter", capped at 5 s.
    const ceil = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** this._attempt++);
    this._timers.retry = setTimeout(() => this._open(), ceil / 2 + Math.random() * ceil / 2);
  }

  _stop() {
    this._stopped = true;
    this._clearTimers();
    const ws = this._ws;
    this._ws = null;
    this._flushAuth();
    if (ws?.readyState <= 1) ws.close(1000);
    this._setStatus('closed');
  }

  _flushAuth() {
    for (const w of this._authWaiters.splice(0)) w(false);
  }
}

/** Feature-detected navigator.vibrate (absent on iOS Safari). Returns whether it was accepted. */
export function vibrate(pattern) {
  try { return !!navigator.vibrate?.(pattern); } catch { return false; }
}

let wakeHooked = false;

/**
 * Keep the screen on. Secure contexts only (https or localhost); resolves false silently otherwise.
 * The lock is re-requested whenever the page becomes visible again.
 * @returns {Promise<boolean>}
 */
export async function wakeLock() {
  if (!globalThis.isSecureContext || !navigator.wakeLock) return false;
  const request = () => navigator.wakeLock.request('screen').then(() => true, () => false);
  if (!wakeHooked) {
    wakeHooked = true;
    document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && request());
  }
  return request();
}
