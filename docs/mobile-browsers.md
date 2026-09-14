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

## Backgrounded and locked phones drop their socket

iOS — and Android with battery savers on — freezes or kills a page's WebSocket when the tab goes to
the background or the phone locks. Two safety nets cover it:

- **pmc.js reconnects** the moment the page becomes visible again, and treats a socket that has gone
  16 s without a pong as dead.
- **The host's `grace_seconds`** keeps the player in the game meanwhile — reconnects inside the
  window resume the same player (same id, same meta). For a phone party game set it to 60–120 s so a
  pocketed phone isn't "gone"; the demo uses 90.

In your UI, distinguish "socket lost" from "left": a `disconnected` player inside the grace window
is reconnecting (the demo dims their card and shows *reconnecting…*), while an explicit `leave`
removes them. And pair `grace_seconds` with `keepScreenOn()` so screens don't sleep mid-round.

## Screen wake lock needs a secure context

The Screen Wake Lock API only works on `https://` or localhost, so on a plain `http://192.168.x.x`
LAN page `wakeLock()` fails and phones dim and lock mid-game. `keepScreenOn()` handles both cases:
it tries the real API first, and on an insecure context it arms a NoSleep-style fallback — a tiny
muted looping video that keeps the screen awake while playing. Autoplay rules mean the clip starts
on the first user gesture (the join button tap counts). The same secure-context restriction blocks
clipboard and some sensor APIs on LAN pages; running the party over the https tunnel is the real fix
when keeping screens on matters.

## Two tabs in one browser share a player

The rejoin token lives in `localStorage`, which is keyed by origin — so two tabs in one browser
profile count as the **same player**. The newer tab's hello wins and the host closes the older tab's
socket with `pmc.replaced` (close code 4002). That's by design: it's what makes reloads seamless.

It does surprise developers faking several "phones" in one desktop browser. Options: separate
browser profiles, incognito windows, or `connect({ tokenKey: 'tab-2' })` per tab — the token lands
under your key and each tab keeps its own identity.

## Ephemeral tunnel URLs

Quick Tunnel URLs change every run (and can change mid-session if the tunnel restarts). When the
host announces a new join URL (`pmc.moved`), an https page auto-follows to the new address once the
new URL answers; a LAN `http://` page never navigates itself — show "re-scan the QR" on the `moved`
event instead.
