// Outside-LAN join through the Cloudflare quick tunnel: https page => wss socket.
// Needs network access and cloudflared (downloaded on first use), so it only runs with PMC_TEST_TUNNEL=1.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { launchBrowser, newPhone, startHost, waitFor, welcomed } from './lib/harness.mjs';

describe('tunnel join (PMC_TEST_TUNNEL=1)', { skip: process.env.PMC_TEST_TUNNEL !== '1', timeout: 180000 }, () => {
  let host, browser;
  before(async () => {
    host = await startHost({ code: '', pin: '2468', args: ['--tunnel'] });
    browser = await launchBrowser();
  });
  after(async () => {
    await browser?.close();
    await host?.stop();
  });

  it('phone joins over https with wss and the auto-generated code', async () => {
    const line = await waitFor(() => /BUZZER_TUNNEL(_FAILED)? (?:url=)?(\S+)/.exec(host.log.join('')), 120000, 'tunnel ready');
    assert.ok(!line[1], `tunnel failed: ${line[2]}`);
    const url = new URL(line[2]);
    assert.equal(url.protocol, 'https:');
    assert.match(url.searchParams.get('code') ?? '', /^[A-Z]{4}$/, 'join code auto-generated for a public URL');
    const p = await newPhone(browser, 'remote');
    const wsUrls = [];
    p.page.on('websocket', (ws) => wsUrls.push(ws.url()));
    // Quick tunnels can take a few seconds before the hostname resolves everywhere.
    await waitFor(async () => (await p.page.goto(url.href).catch(() => null))?.ok(), 60000, 'tunnel page load');
    await p.page.fill('#name', 'Remote');
    await p.page.click('#join-btn');
    await welcomed(p, 30000);
    assert.ok(wsUrls[0].startsWith(`wss://${url.host}/pmc/ws`), `socket url ${wsUrls[0]}`);
    await p.shot('12-tunnel-join');
  });
});
