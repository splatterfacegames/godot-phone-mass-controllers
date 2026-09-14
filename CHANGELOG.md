# Changelog

## 0.2.0 — 2026-09-14

Every open issue on the tracker is addressed in this release. Highlights:

### Tunnel (outside-LAN play)

- **Named tunnels** (`tunnel_mode = "named"`): stable join URLs via a Cloudflare account —
  dashboard "run with token" (`named_tunnel_token` + `named_tunnel_hostname`) or a local
  `named_tunnel` + `named_credentials_file`.
- **Tunnel options are configurable before launch**: `@export_group("Tunnel")` on `PMCHost`
  (`tunnel_verify_dns`, `tunnel_ready_timeout_sec`, `tunnel_extra_args`, `tunnel_allow_download`,
  `tunnel_join_code`, `tunnel_auto_restart`, `tunnel_restart_delay_sec`), and
  `start_tunnel(code := "")` accepts a game-supplied join code that is never auto-cleared.
- **Resilience**: creation 429/1015 retries with backoff; QUIC-blocked detection with an
  HTTP/2 fallback; a new `lost` state (distinct from `failed`) with bounded auto-restart;
  actionable error hints for blocked/DNS-filtered networks.
- **Ephemeral-URL handling**: `restart_tunnel()` does a rolling replace — connected players get
  `pmc.moved` with the new join URL before the old tunnel dies; a ready tunnel survives
  `stop()`→`start()` and even a scene reload (detached + re-adopted ~2 min).
- **Trust**: downloaded binaries pass SHA-256 vs GitHub's release digest, a minimum-version check,
  and an OS code-signature check (Windows Authenticode / macOS codesign+spctl); managed binaries
  re-verify after `binary_max_age_days` (30). A `~/.cloudflared/config.yml` can no longer break
  Quick Tunnels (isolated `--config`), and a `user://pmc/cloudflared.pid` watchdog reaps a
  cloudflared orphaned by an engine crash.
- Provider contract and alternatives (Tailscale Funnel, ngrok, hosted relay, WebRTC) documented
  in `docs/tunnels.md`; relay/WebRTC scoping for Android/iOS/Web/console hosts in
  `docs/relay-scope.md`.

### Host core

- **Protocol fix**: `pmc.welcome.server_ms` and `pmc.pong.s` are now **epoch ms UTC**
  (`serverNow()` is comparable to deadlines stamped from `Time.get_unix_time_from_system()`).
- **Public-host hardening** while tunneled: 6-char join codes carried in the QR's `?code=`;
  `/pmc/info.json` + `/pmc/qr.png` answer loopback-or-code only; `require_player(req)` +
  `serve_directory(..., players_only)` gate custom routes on a joined player's token
  (`?t=` or the `pmc_token` cookie); a global `admin_pin_max_failures` budget disables the PIN.
- `serve_directory` resolves symlinks and refuses escapes; opt-in WebSocket `check_origin` +
  `allowed_origins`; SPEC §1 documents the remaining gaps (no TLS — use the tunnel —, no
  permessage-deflate, chunked→501, no ETag, proxy headers).
- `kick(to, reason, ban, remember := false)`: `remember` leaves a tombstone so a kicked player
  rejoins with id + `meta` intact.
- `PMCPlayer.rtt_ms` (rolling heartbeat RTT), `no_joins_hint_seconds` + `no_joins_hint` signal
  for the "QR showing, nobody can reach the host" case, and per-socket (not cross-player)
  delivery ordering documented.
- **Optional I/O thread** (`io_thread_enabled`): accept/read/write/frame-decode on a worker;
  the main thread drains complete events within `io_budget_msec`. Numbers and tuning in
  `docs/performance.md`.

### pmc.js + demo

- `pmc.rttMs` + `pmc.timestamp()` for latency-aware inputs; the Buzzer Party demo credits
  timestamped buzzes with bounded RTT compensation and a steal window.
- `pmc.feedback(kind)` — vibrate where supported, else screen flash + WebAudio click
  (iOS has no vibration API).
- `pmc.keepScreenOn()` — Screen Wake Lock where allowed, else a NoSleep-style muted clip on
  the next gesture (plain-http LAN pages can't hold a wake lock).
- `?code=` in the join URL is sent in `pmc.hello`; the rejoin token is mirrored to the
  `pmc_token` cookie; `pmc.moved` triggers a rescan banner (https→https may auto-follow).
- `docs/mobile-browsers.md`: backgrounded-socket behavior, `grace_seconds` 60–120 guidance,
  two-tabs-share-a-token, per-tab `tokenKey` for dev.

### Editor

- The **Phone Controllers dock** shows the running game's host status (port, join URL + QR,
  players, tunnel state) over a debugger channel, and supports named-tunnel test runs.
- `PMCHost` no longer appears twice in Create Node.
- An `EditorExportPlugin` packs `controller_dir` and `serve_directory` `res://` dirs as raw
  files so controller assets survive export — see `docs/exporting.md`.

### Project site

- [pmc.splatterfacegames.com](https://pmc.splatterfacegames.com) — explainer, quickstart, caveats, deployed
  from `site/` by `.github/workflows/pages.yml`.

## 0.1.0 — 2026-09-13

First public release: pure-GDScript HTTP+WebSocket host on one port, player tokens/rejoin/
tombstones, join codes, kick/ban, PIN admin, pure-GDScript QR encoder, one-click Cloudflare
Quick Tunnel, `pmc.js` SDK, lobby helpers (queue/vote/rotation), Buzzer Party demo, editor dock.
