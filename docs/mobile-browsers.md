# Mobile browser caveats

Phone browsers are the whole point of this addon, and they come with quirks that don't exist on
desktop. This page collects them — and what pmc.js and the host already do about each.

## Tunnel latency vs. fairness

Through the tunnel, traffic goes phone → Cloudflare edge → `cloudflared` → game, even when everyone
is in the same room — measured round-trips of 26–56 ms from Tokyo, more elsewhere, and jittery. In
reaction games that's unfair between local and remote players.

- Prefer LAN mode when everyone's local; use the tunnel for friends who aren't.
- `pmc.rttMs` exposes each client's rolling RTT (from `pmc.ping`/`pong`), and the host mirrors it as
  `player.rtt_ms` so games can display or use it.
- For "who was first" mechanics: stamp inputs on the phone with `pmc.timestamp()` (the estimated host
  clock) and let the host judge them — crediting a claim no further back than that player's RTT keeps
  it fair without trusting backdating. The demo's buzzer does exactly this, including a short
  steal-the-win window for a tap that genuinely happened earlier but arrived late.

## iOS: no vibration API

`navigator.vibrate` doesn't exist on iOS — in any browser, because they all use WebKit — so
`vibrate()` returns `false` there. Use `feedback(kind)` (`'buzz'`/`'success'`/`'error'`) for
tactile-ish feedback instead: it vibrates where supported and otherwise flashes the screen for
60 ms and plays a short WebAudio click. iOS audio only starts inside a user gesture, so the SDK
unlocks its AudioContext on the first `pointerdown` — call `feedback()` in response to taps and the
click will be ready.

## Ephemeral tunnel URLs

Quick Tunnel URLs change every run (and can change mid-session if the tunnel restarts). When the
host announces a new join URL (`pmc.moved`), an https page auto-follows to the new address once the
new URL answers; a LAN `http://` page never navigates itself — show "re-scan the QR" on the `moved`
event instead.
