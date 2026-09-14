// Buzzer Party end to end: 6 Chromium "phones" against the real headless Godot host.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  join, launchBrowser, newPhone, scriptErrors, sleep, startHost, waitFor, welcomed, wrapPage,
} from './lib/harness.mjs';

const NAMES = ['Ada', 'Bo', 'Cy', 'Dee', 'Eli', 'Fay'];

describe('Buzzer Party demo (real Godot host)', { timeout: 240000 }, () => {
  let host, browser;
  const phones = [];
  const ids = [];
  let admin; // phones[0]

  const stateOf = (phone) => phone.messages('state').at(-1);

  before(async () => {
    host = await startHost({ code: 'PLAY', pin: '2468', args: ['--flash-ms=2500', '--lead-ms=600', '--no-auto', '--seed=7'] });
    browser = await launchBrowser();
  });

  after(async () => {
    await browser?.close();
    await host?.stop();
    const errs = host ? scriptErrors(host.log) : [];
    if (errs.length) console.log('Godot script errors:\n' + errs.join('\n'));
  });

  it('six phones join with name, colour and emoji', async () => {
    for (let i = 0; i < 6; i++) {
      const phone = await newPhone(browser, NAMES[i]);
      phones.push(phone);
      if (i === 0) {
        await phone.page.goto(`${host.base}/?code=${host.code}`);
        await phone.shot('01-join-form');
        await phone.page.goto('about:blank');
      }
      ids.push(await join(phone, host, { name: NAMES[i], colorIndex: i, emojiIndex: i * 2 }));
    }
    admin = phones[0];
    assert.equal(new Set(ids).size, 6, 'distinct ids');
    const last = phones[5];
    const st = await waitFor(() => { const s = stateOf(last); return s?.players.length === 6 && s; }, 5000, 'roster of 6');
    for (let i = 0; i < 6; i++) {
      const p = st.players.find((x) => x.id === ids[i]);
      assert.equal(p.name, NAMES[i]);
      assert.equal(p.connected, true);
      assert.match(p.color, /^#[0-9a-f]{6}$/i);
      assert.ok(p.emoji.length > 0);
    }
    await phones[2].page.waitForFunction(() => document.querySelectorAll('#scores li').length === 6);
    await phones[2].shot('02-lobby-phone');
    for (const p of phones) assert.deepEqual(p.errors, [], `${p.label} page errors`);
  });

  it('admin: wrong PIN refused, non-admin commands ignored, right PIN unlocks', async () => {
    const pg = admin.page;
    assert.equal(await pg.isVisible('#admin-tools'), false);
    assert.equal(await pg.evaluate(() => window.pmc.auth('0000')), false);
    // A non-admin trying to start the game is ignored by the host.
    await phones[1].page.evaluate(() => window.pmc.send({ type: 'admin', action: 'start' }));
    await sleep(500);
    assert.equal(stateOf(phones[1]).phase, 'lobby');
    await pg.fill('#pin', host.pin);
    await pg.click('#pin-form button');
    await pg.waitForSelector('#admin-tools', { state: 'visible' });
    assert.equal(await pg.evaluate(() => window.pmc.admin), true);
    await waitFor(() => stateOf(phones[3])?.players.find((p) => p.id === ids[0])?.admin, 3000, 'admin flag in state');
    await pg.locator('#admin').scrollIntoViewIfNeeded();
    await admin.shot('03-admin-panel');
  });

  it('round start: each phone gets exactly one private secret, addressed to itself', async () => {
    const marks = phones.map((p) => p.frames.length);
    await admin.page.click('#adm-start');
    const secrets = [];
    for (let i = 0; i < 6; i++) {
      const f = await phones[i].waitFrame((fr) => fr.json?.d?.type === 'secret', 5000, marks[i]);
      secrets.push(f.json.d);
    }
    await sleep(600); // let any stray frames arrive
    for (let i = 0; i < 6; i++) {
      const mine = phones[i].frames.slice(marks[i]).filter((f) => f.dir === 'in' && f.json?.d?.type === 'secret');
      assert.equal(mine.length, 1, `${NAMES[i]} got exactly one secret`);
      assert.equal(mine[0].json.d.for, ids[i], `${NAMES[i]}'s secret is addressed to them`);
      // No other phone's secret payload ever reaches this socket.
      const allText = phones[i].frames.filter((f) => f.dir === 'in' && f.text?.includes('"secret"')).map((f) => f.json.d.for);
      assert.deepEqual([...new Set(allText)], [ids[i]]);
    }
    assert.equal(new Set(secrets.map((s) => s.symbol.id)).size, 6, 'secrets are distinct');
    await phones[1].page.waitForSelector('#secret', { state: 'visible' });
    assert.equal(await phones[1].page.textContent('#secret-label'), secrets[1].symbol.label);
    await phones[1].shot('04-round-secret');
  });

  it('wrong buzz locks out, first correct buzz scores', async () => {
    const secretOf = (i) => phones[i].messages('secret').at(-1).symbol.id;
    // Wait for a flash showing a symbol one of the phones holds.
    let winnerIdx = -1, flash;
    // Only act on a fresh flash (flash-ms is 2500), so both buzzes land while it's still showing.
    await waitFor(() => {
      const fr = phones[0].received().filter((f) => f.json?.d?.type === 'flash').at(-1);
      if (!fr || Date.now() - fr.at > 300) return false;
      const idx = [0, 1, 2, 3, 4, 5].findIndex((i) => secretOf(i) === fr.json.d.symbol);
      if (idx < 0) return false;
      flash = fr.json.d; winnerIdx = idx;
      return true;
    }, 40000, 'a fresh flash matching a held secret');
    const wrongIdx = winnerIdx === 5 ? 4 : 5;
    const w = phones[wrongIdx], r = phones[winnerIdx];
    let mark = w.frames.length;
    await w.page.click('#buzzer');
    const wrong = await w.waitFrame((f) => f.json?.d?.type === 'buzz', 3000, mark);
    assert.equal(wrong.json.d.result, 'wrong');
    await w.page.waitForSelector('#buzzer.locked');
    await w.shot('05-wrong-buzz');
    mark = r.frames.length;
    await r.page.click('#buzzer');
    const win = await r.waitFrame((f) => f.json?.d?.type === 'buzz', 3000, mark);
    assert.equal(win.json.d.result, 'win');
    const st = await waitFor(() => { const s = stateOf(phones[0]); return s?.phase === 'reveal' && s; }, 3000, 'reveal state');
    assert.equal(st.winner, ids[winnerIdx]);
    assert.equal(st.players.find((p) => p.id === ids[winnerIdx]).score, 1);
    assert.equal(st.players.find((p) => p.id === ids[wrongIdx]).score, 0);
    await r.page.waitForFunction(() => document.querySelector('#me-score').textContent === '1');
    await r.shot('06-round-won');
    phones.winnerIdx = winnerIdx;
  });

  it('reload rejoins with the same id and score', async () => {
    const i = phones.winnerIdx;
    const p = phones[i];
    const mark = p.frames.length;
    await p.page.reload();
    const id = await welcomed(p);
    assert.equal(id, ids[i]);
    const welcome = (await p.waitFrame((f) => f.json?.t === 'pmc.welcome', 5000, mark)).json;
    assert.equal(welcome.rejoined, true);
    await p.page.waitForFunction(() => document.querySelector('#me-score').textContent === '1');
    const st = await waitFor(() => stateOf(phones[0])?.players.find((x) => x.id === id && x.connected), 5000);
    assert.equal(st.score, 1);
  });

  it('a mid-round rejoin gets its own secret again', async () => {
    const p = phones[3];
    const prevRound = stateOf(p).round;
    await admin.page.click('#adm-next');
    const st = await waitFor(() => { const s = stateOf(p); return s?.phase === 'round' && s.round > prevRound && s; }, 5000, 'next round');
    const before = await waitFor(() => p.messages('secret').find((s) => s.round === st.round), 5000, 'secret for new round');
    const mark = p.frames.length;
    await p.page.reload();
    await welcomed(p);
    const again = await p.waitFrame((f) => f.json?.d?.type === 'secret', 5000, mark);
    assert.equal(again.json.d.for, ids[3]);
    assert.equal(again.json.d.round, st.round);
    assert.equal(again.json.d.symbol.id, before.symbol.id, 'same secret after rejoin');
    await p.page.waitForSelector('#secret', { state: 'visible' });
  });

  it('binary frames round-trip untouched (1 KB and 900 KB)', async () => {
    for (const size of [1000, 900000]) {
      const res = await phones[2].page.evaluate((n) => new Promise((resolve) => {
        const bytes = new Uint8Array(n).map((_, i) => (i * 37 + 11) & 255);
        const onBin = (buf) => {
          if (buf.byteLength !== n) return; // skip the controller's 8-byte latency probes
          window.pmc.off('binary', onBin);
          resolve({ same: new Uint8Array(buf).every((b, i) => b === bytes[i]), len: buf.byteLength });
        };
        window.pmc.on('binary', onBin);
        window.pmc.sendBinary(bytes);
      }), size);
      assert.deepEqual(res, { same: true, len: size });
    }
  });

  it('serverNow() tracks the host clock', async () => {
    const p = phones[2];
    const pong = await p.waitFrame((f) => f.json?.t === 'pmc.pong', 8000, p.frames.length);
    const est = await p.page.evaluate(() => window.pmc.serverNow());
    const expected = pong.json.s + (Date.now() - pong.at);
    assert.ok(Math.abs(est - expected) < 300, `serverNow ${est} vs host ${expected}`);
  });

  it('kick from the admin panel closes that phone for good', async () => {
    const victim = phones[4];
    await admin.page.click(`#adm-players button[data-kick="${ids[4]}"]`);
    await victim.page.waitForSelector('#ended', { state: 'visible' });
    assert.equal(await victim.page.textContent('#ended-title'), 'Removed by the host');
    assert.ok(victim.frames.some((f) => f.json?.t === 'pmc.kicked'));
    const sockets = victim.sockets;
    await sleep(2500);
    assert.equal(victim.sockets, sockets, 'no reconnect after kick');
    assert.equal(await victim.page.evaluate(() => window.pmc.status), 'closed');
    await waitFor(() => !stateOf(phones[0]).players.some((x) => x.id === ids[4]), 3000, 'kicked player gone from roster');
    await victim.shot('07-kicked');
    // "Join again" uses pmc.reconnect(); a kick doesn't ban, so the phone gets back in.
    await victim.page.click('#ended-btn');
    await welcomed(victim);
    await victim.page.waitForSelector('#play', { state: 'visible' });
  });

  it('same token in a second tab replaces the first', async () => {
    const first = phones[1];
    const second = wrapPage(await first.ctx.newPage(), 'Bo-tab2', first.ctx);
    await second.page.goto(`${host.base}/?code=${host.code}`);
    assert.equal(await welcomed(second), ids[1]);
    await first.page.waitForSelector('#ended', { state: 'visible' });
    assert.ok(first.frames.some((f) => f.json?.t === 'pmc.replaced'));
    const sockets = first.sockets;
    await sleep(2500);
    assert.equal(first.sockets, sockets, 'replaced tab does not reconnect');
    assert.equal(await second.page.evaluate(() => window.pmc.status), 'open');
    await first.shot('08-replaced');
  });

  it('wrong join code is rejected without retries, then the right code works', async () => {
    const p = await newPhone(browser, 'Gus');
    await p.page.goto(`${host.base}/?code=NOPE`);
    await p.page.fill('#name', 'Gus');
    await p.page.click('#join-btn');
    await p.page.waitForSelector('#code-form', { state: 'visible' });
    const reject = p.frames.find((f) => f.json?.t === 'pmc.reject').json;
    assert.equal(reject.code, 'bad_code');
    await sleep(2000);
    assert.equal(p.sockets, 1, 'no retry after reject');
    await p.shot('09-bad-code');
    await p.page.fill('#code', host.code.toLowerCase());
    await p.page.click('#code-form button');
    await welcomed(p);
    await p.shot('10-joined-after-code');
    await p.ctx.close();
  });

  it('"Change look" updates name and profile live (setProfile)', async () => {
    const p = phones[5];
    await p.page.click('#edit-btn');
    await p.page.fill('#name', 'Faye');
    await p.page.locator('#colors .swatch').nth(7).click();
    await p.page.click('#join-btn');
    const me = await waitFor(() => stateOf(phones[0])?.players.find((x) => x.id === ids[5] && x.name === 'Faye'), 5000, 'renamed player');
    assert.equal(me.color, '#ff6fb5');
    assert.equal(await p.page.evaluate(() => window.pmc.status), 'open');
    assert.equal(p.sockets, 1, 'profile change needs no reconnect');
  });

  it('admin PIN locks out after 5 failures', async () => {
    const p = await newPhone(browser, 'Hal');
    await join(p, host, { name: 'Hal' });
    const results = await p.page.evaluate(async (pin) => {
      const out = [];
      for (let i = 0; i < 5; i++) out.push(await window.pmc.auth('0000'));
      out.push(await window.pmc.auth(pin));
      return out;
    }, host.pin);
    assert.deepEqual(results, [false, false, false, false, false, false], 'correct PIN refused during lockout');
    await p.page.evaluate(() => window.pmc.leave());
    await p.ctx.close();
  });

  it('leave removes the player at once, with no reconnect', async () => {
    const p = phones[5];
    const sockets = p.sockets;
    await p.page.click('#leave-btn');
    await p.page.waitForSelector('#ended', { state: 'visible' });
    await waitFor(() => !stateOf(phones[0]).players.some((x) => x.id === ids[5]), 3000, 'player removed without grace');
    await sleep(1500);
    assert.equal(p.sockets, sockets);
    assert.equal(await p.page.evaluate(() => window.pmc.status), 'closed');
  });

  it('host restart: phone shows the reconnect banner, then reconnects by itself', async () => {
    assert.deepEqual(scriptErrors(host.log), [], 'the demo ran without GDScript errors');
    const p = phones[2];
    const port = host.port;
    await host.stop();
    await p.page.waitForSelector('#banner', { state: 'visible', timeout: 20000 });
    await p.shot('11-reconnecting');
    host = await startHost({ code: 'PLAY', pin: '2468', port, args: ['--no-auto'] });
    await p.page.waitForSelector('#banner', { state: 'hidden', timeout: 20000 });
    await welcomed(p);
    assert.equal(await p.page.evaluate(() => window.pmc.status), 'open');
  });
});
