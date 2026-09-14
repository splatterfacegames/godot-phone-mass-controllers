# Security notes

This addon's server is hand-rolled GDScript. It is meant for a game LAN or a short-lived public URL
(via `host.start_tunnel()`), not as a general-purpose web server. This page collects the threat model,
the built-in limits, and the hardening knobs.

## Threat model

- **On the LAN**, traffic is plain `http`/`ws`. Anyone on the network can read it and can try to join.
  Set `host.join_code` (or let the tunnel auto-generate one) when the room isn't trusted.
- **Through the tunnel**, the host is on the public internet at a random `*.trycloudflare.com` URL.
  Cloudflare terminates TLS, so phones get `https`/`wss`; the last hop to the game stays local HTTP.
  Anyone who learns the URL can reach the HTTP port — see the limits below.

## What the host already does

- **Join code** (required while tunneled): 4 chars when you set one on the LAN, 6 chars auto-generated
  while a tunnel is up (24^6 ≈ 191M). The QR and `join_url()` carry it as `?code=`, and pmc.js sends it
  in `pmc.hello`. Wrong codes are limited per client address (`join_code_max_failures` →
  `join_code_block_seconds`); behind the tunnel the address comes from `CF-Connecting-IP`.
- **Per-address connection cap** (`max_connections_per_address`, default 128).
- **Admin PIN**: per-connection lockout (5 → 30 s), per-address lockout (20 → 60 s), and a **global
  budget** (`admin_pin_max_failures`, default 20) that disables the PIN until the host restarts — this
  is what stops a distributed brute-force run. Prefer a non-trivial PIN, or keep `admin_pin` empty
  (auth always fails) when you don't need it.
- **Handshake timeouts** on request headers, `pmc.hello`, stalled writes, and heartbeat loss.
- **Static serving** refuses `..`/encoding tricks and now also resolves symlinks, refusing files that
  escape the served directory (403).

## While tunneled

- `/pmc/info.json` and `/pmc/qr.png` **reveal the join URL including the code**, so they answer only to
  loopback or to a request carrying a valid `?code=`. The controller page and `/pmc/pmc.js` stay public
  by design — phones can't join without them.
- If a phone's browser loads the controller through the tunnel, it has the code already (`?code=` in the
  URL). A stranger who finds the bare tunnel URL can fetch the page and SDK but not the code, and a wrong
  guess still costs them a per-address block.
- Rotate the code any time by assigning a new `host.join_code` — `join_url()` and the QR update
  automatically.

## Guarding your own routes and files

Custom routes (`add_route`) and `serve_directory` mounts are unauthenticated by default — anything they
expose is fetchable by someone with the tunnel URL. Use `require_player` to demand a joined player's
rejoin token (`?t=<token>` or the `pmc_token` cookie that pmc.js sets after join):

```gdscript
host.add_route("/save", func(req: PMCHttpRequest):
	var p := host.require_player(req)
	if p == null:
		return PMCHttpResponse.error(403)
	return PMCHttpResponse.json({"saved_for": p.id}))

host.serve_directory("/private/", "user://private", true)   # players_only
```

The token is a bearer secret — it identifies the player but doesn't prove their phone is who they say
beyond that. Don't build real authentication on it.

## Origin check

Browsers always send `Origin` on a WebSocket upgrade. Auth is by token/code so a foreign site can't
impersonate a player anyway, but `check_origin` + `allowed_origins` can refuse upgrades whose Origin
isn't yours (403). Clients without an Origin header (curl, ws, non-browser tooling) are unaffected.

## Known protocol gaps (won't fix in the built-in server)

- **No TLS.** Use the tunnel (Cloudflare edge) for `https`/`wss`.
- **No permessage-deflate.** Never negotiated; big JSON payloads cost bandwidth. Prefer binary frames.
- **Request bodies:** `Content-Length` only; `Transfer-Encoding: chunked` → 501.
- **Caching:** no `ETag`/`If-None-Match` (no 304s). `Range` handles a single range only.
- **Reverse proxies:** without the tunnel, `Forwarded`/`X-Forwarded-For` are ignored — per-address
  limits then see the proxy's address. Behind `start_tunnel()`, `CF-Connecting-IP` is honored.
- The WebSocket implementation passes Godot's `WebSocketPeer`, Chromium and Node `ws` including
  malformed-frame handling, but hasn't run the Autobahn suite — see issue #20.
