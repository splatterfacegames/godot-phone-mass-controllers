// Shared helpers for the browser tests: locate Playwright + Chromium, run the Godot demo host,
// open "phones" with per-page WebSocket frame capture.
//
// Env: GODOT (Godot binary, default `godot`), PMC_PLAYWRIGHT_DIR (dir whose node_modules has playwright or
// playwright-core; default: this package), PMC_CHROMIUM (browser executable), PMC_HOST_LOG=1 (echo Godot
// output), PMC_HOST_WINDOWED=1 (run the host with a window), PMC_TEST_TUNNEL=1 (enable tunnel.test.mjs).
import { spawn, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const BROWSER_DIR = path.resolve(here, '..');
export const REPO = path.resolve(BROWSER_DIR, '../..');
export const OUT = path.join(BROWSER_DIR, 'out');
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Playwright from $PMC_PLAYWRIGHT_DIR (a dir containing node_modules) or this package's devDependency. */
export function loadPlaywright() {
  const roots = [process.env.PMC_PLAYWRIGHT_DIR, BROWSER_DIR].filter(Boolean);
  for (const root of roots) {
    const req = createRequire(path.join(path.resolve(root), 'noop.js'));
    for (const name of ['playwright', 'playwright-core']) {
      try { return req(name); } catch {}
    }
  }
  throw new Error('Playwright not found: run `npm i` in tests/browser or set PMC_PLAYWRIGHT_DIR');
}

/** Launch Chromium. $PMC_CHROMIUM overrides the executable; otherwise fall back to any installed build. */
export async function launchBrowser() {
  const { chromium } = loadPlaywright();
  const opts = { headless: true };
  if (process.env.PMC_CHROMIUM) return chromium.launch({ ...opts, executablePath: process.env.PMC_CHROMIUM });
  try {
    return await chromium.launch(opts);
  } catch (err) {
    const exe = findInstalledChromium();
    if (!exe) throw err;
    return chromium.launch({ ...opts, executablePath: exe });
  }
}

function findInstalledChromium() {
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH
    || (process.platform === 'win32' ? path.join(process.env.LOCALAPPDATA ?? '', 'ms-playwright')
      : process.platform === 'darwin' ? path.join(os.homedir(), 'Library/Caches/ms-playwright')
        : path.join(os.homedir(), '.cache/ms-playwright'));
  if (!fs.existsSync(base)) return null;
  const rev = (d) => +d.split('-').pop();
  const candidates = fs.readdirSync(base)
    .filter((d) => /^chromium(_headless_shell)?-\d+$/.test(d))
    .sort((a, b) => rev(b) - rev(a) || (a.includes('headless') ? -1 : 1));
  const exes = {
    win32: ['chrome-headless-shell-win64/chrome-headless-shell.exe', 'chrome-win64/chrome.exe', 'chrome-win/chrome.exe'],
    linux: ['chrome-headless-shell-linux64/chrome-headless-shell', 'chrome-linux64/chrome', 'chrome-linux/chrome'],
    darwin: ['chrome-headless-shell-mac-arm64/chrome-headless-shell', 'chrome-mac/Chromium.app/Contents/MacOS/Chromium'],
  }[process.platform] ?? [];
  for (const d of candidates) {
    for (const e of exes) {
      const p = path.join(base, d, e);
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => resolve(port)); });
    srv.on('error', reject);
  });
}

const GODOT = process.env.GODOT || 'godot';

/**
 * Start the Buzzer Party demo host headless.
 * @param {{code?: string, pin?: string, port?: number, args?: string[]}} opts
 * @returns {Promise<{port:number, base:string, url:string, pin:string, code:string, log:string[], stop:()=>Promise<void>}>}
 */
export async function startHost({ code = 'PLAY', pin = '2468', port, args = [] } = {}) {
  if (!fs.existsSync(path.join(REPO, '.godot'))) {
    spawnSync(GODOT, ['--headless', '--path', REPO, '--import'], { stdio: 'ignore', timeout: 180000 });
  }
  port ??= await freePort();
  const windowed = process.env.PMC_HOST_WINDOWED === '1';
  const godotArgs = [...(windowed ? [] : ['--headless']), '--path', REPO, 'res://demo/main.tscn', '--',
    `--port=${port}`, `--pin=${pin}`, ...(code ? [`--code=${code}`] : []), ...args];
  const proc = spawn(GODOT, godotArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
  const log = [];
  let exited = false;
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Godot host did not become ready:\n' + log.join(''))), 60000);
    const onData = (chunk) => {
      const s = chunk.toString();
      log.push(s);
      if (process.env.PMC_HOST_LOG === '1') process.stderr.write('[godot] ' + s);
      const m = /BUZZER_READY port=(\d+) url=(\S*) pin=(\S*)/.exec(log.join(''));
      if (m) { clearTimeout(timer); resolve({ port: +m[1], url: m[2], pin: m[3] }); }
    };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);
    proc.on('exit', (c) => { exited = true; clearTimeout(timer); reject(new Error(`Godot exited (${c}):\n` + log.join(''))); });
  });
  const info = await ready;
  await sleep(200);
  const early = scriptErrors(log);
  if (early.length) {
    proc.kill();
    throw new Error('Godot host started with script errors (is the addon compiling?):\n' + early.slice(0, 10).join('\n'));
  }
  return {
    ...info,
    code,
    base: `http://127.0.0.1:${info.port}`,
    log,
    proc,
    async stop() {
      if (exited) return;
      const gone = new Promise((r) => proc.on('exit', r));
      // SIGINT lets Godot exit normally (so the host also stops a tunnel's cloudflared); Windows has no signals.
      proc.kill(process.platform === 'win32' ? undefined : 'SIGINT');
      if (await Promise.race([gone.then(() => true), sleep(5000)])) return;
      proc.kill('SIGKILL');
      await Promise.race([gone, sleep(2000)]);
    },
  };
}

/** Runtime/script errors printed by Godot (for asserting the demo ran clean). */
export function scriptErrors(log) {
  return log.join('').split(/\r?\n/).filter((l) => /SCRIPT ERROR|Parse Error|ERROR: .*res:\/\/demo/.test(l));
}

export const PHONE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };

/**
 * A phone = browser context + page, with every WS frame captured.
 * @returns {Promise<Phone>}
 */
export async function newPhone(browser, label, context) {
  const ctx = context ?? await browser.newContext(PHONE);
  const page = await ctx.newPage();
  return wrapPage(page, label, ctx);
}

export function wrapPage(page, label, ctx) {
  const phone = { label, ctx, page, frames: [], sockets: 0, errors: [] };
  page.on('websocket', (ws) => {
    phone.sockets++;
    ws.on('framereceived', (f) => phone.frames.push({ dir: 'in', at: Date.now(), ...decode(f.payload) }));
    ws.on('framesent', (f) => phone.frames.push({ dir: 'out', at: Date.now(), ...decode(f.payload) }));
  });
  page.on('pageerror', (e) => phone.errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') phone.errors.push(m.text()); });
  phone.received = () => phone.frames.filter((f) => f.dir === 'in');
  phone.messages = (type) => phone.received().filter((f) => f.json?.t === 'msg' && (!type || f.json.d?.type === type)).map((f) => f.json.d);
  /** Wait for an incoming frame matching pred, looking only at frames after index `since`. */
  phone.waitFrame = (pred, timeout = 10000, since = 0) =>
    waitFor(() => phone.frames.slice(since).find((f) => f.dir === 'in' && pred(f)), timeout, `${label}: frame`);
  phone.shot = (name) => page.screenshot({ path: path.join(OUT, `${name}.png`) });
  return phone;
}

function decode(payload) {
  if (typeof payload === 'string') {
    try { return { text: payload, json: JSON.parse(payload) }; } catch { return { text: payload }; }
  }
  return { binary: Buffer.from(payload) };
}

export async function waitFor(fn, timeout = 10000, what = 'condition') {
  const end = Date.now() + timeout;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(50);
  }
}

/** Fill the join form and wait for the welcome. Returns the player id. */
export async function join(phone, host, { name, colorIndex = 0, emojiIndex = 0, code = host.code } = {}) {
  await phone.page.goto(`${host.base}/${code ? `?code=${code}` : ''}`);
  await phone.page.fill('#name', name);
  await phone.page.locator('#colors .swatch').nth(colorIndex).click();
  await phone.page.locator('#emojis .emoji').nth(emojiIndex).click();
  await phone.page.click('#join-btn');
  return welcomed(phone);
}

export async function welcomed(phone, timeout = 10000) {
  await phone.page.waitForFunction(() => window.pmc?.status === 'open' && window.pmc.id != null, null, { timeout });
  return phone.page.evaluate(() => window.pmc.id);
}

fs.mkdirSync(OUT, { recursive: true });
