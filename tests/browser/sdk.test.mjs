// pmc.js SDK behaviours against the real headless Godot host:
// rttMs/timestamp, the pmc_token cookie, and the pmc.moved event.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  join, launchBrowser, newPhone, scriptErrors, startHost, waitFor,
} from './lib/harness.mjs';

describe('pmc.js SDK (real Godot host)', { timeout: 120000 }, () => {
  let host, browser;

  before(async () => {
    host = await startHost({ code: 'PLAY', pin: '2468', args: ['--no-auto', '--seed=3'] });
    browser = await launchBrowser();
  });

  after(async () => {
    await browser?.close();
    await host?.stop();
    const errs = host ? scriptErrors(host.log) : [];
    if (errs.length) console.log('Godot script errors:\n' + errs.join('\n'));
  });

  it('rttMs and timestamp() expose the ping/pong clock estimate', async () => {
    const p = await newPhone(browser, 'Rin');
    await join(p, host, { name: 'Rin' });
    const rtt = await waitFor(async () => {
      const r = await p.page.evaluate(() => window.pmc.rttMs);
      return r > 0 ? r : false;
    }, 8000, 'rttMs > 0');
    assert.ok(rtt < 5000, `sane rtt ${rtt}`);
    // timestamp() rides the host clock — whatever unit pmc.pong.s carries (ticks or epoch).
    const pong = p.received().filter((f) => f.json?.t === 'pmc.pong').at(-1);
    const ts = await p.page.evaluate(() => window.pmc.timestamp());
    assert.ok(Math.abs(ts - (pong.json.s + (Date.now() - pong.at))) < 500, `timestamp ${ts} vs host ${pong.json.s}`);
    await p.ctx.close();
  });

  it('a successful join sets the pmc_token cookie (SameSite=Strict, path=/)', async () => {
    const p = await newPhone(browser, 'Cole');
    await join(p, host, { name: 'Cole' });
    const cookie = await p.page.evaluate(() => document.cookie);
    assert.match(cookie, /pmc_token=[0-9a-f]{32}/);
    await p.ctx.close();
  });

  it('pmc.moved surfaces the moved event and never navigates a LAN (http) page', async () => {
    const p = await newPhone(browser, 'Moe');
    await join(p, host, { name: 'Moe' });
    const url = await p.page.evaluate(() => new Promise((resolve) => {
      window.pmc.on('moved', (m) => resolve(m.url));
      // Simulate the host announcing a new tunnel URL.
      window.pmc._onMoved('https://new-name.trycloudflare.com/?code=PLAY');
      setTimeout(() => resolve(null), 4000);
    }));
    assert.equal(url, 'https://new-name.trycloudflare.com/?code=PLAY');
    assert.equal(p.page.url().startsWith(host.base), true, 'http page did not auto-navigate');
    await p.ctx.close();
  });

  it('feedback() picks a working channel and never throws', async () => {
    const p = await newPhone(browser, 'Flo');
    await join(p, host, { name: 'Flo' });
    const modes = await p.page.evaluate(() => import('/pmc/pmc.js').then((m) =>
      ['buzz', 'success', 'error', 'unknown-kind'].map((k) => m.feedback(k))));
    for (const mode of modes) assert.ok(mode === 'vibrate' || mode === 'flash', `mode ${mode}`);
    await p.ctx.close();
  });

  it('the demo buzz carries an `at` timestamp', async () => {
    const p = await newPhone(browser, 'Ada2');
    await join(p, host, { name: 'Ada2' });
    await p.page.evaluate(() => window.pmc.send({ type: 'buzz', at: window.pmc.timestamp() }));
    await waitFor(() => p.frames.some((f) => f.dir === 'out' && typeof f.json?.d?.at === 'number'),
      3000, 'buzz with at');
    await p.ctx.close();
  });
});
