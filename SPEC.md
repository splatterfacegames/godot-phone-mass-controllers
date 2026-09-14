# godot-phone-mass-controllers — spec (v1)

A pure-GDScript Godot 4 addon that turns a Godot game into the host for a room full of
phone controllers. The idea comes from HappyFunTimes. Players scan a QR code, their phone's
browser loads a controller page served **by the game itself**, and they're connected over
WebSocket. No app install, no Node, no external server.

Game authority lives in Godot. The addon handles transport, identity/rejoin, the QR code,
the join URL (LAN or one-click Cloudflare tunnel), and a small JS SDK for controller pages.

- Engine: Godot 4.x, tested on **4.7.1**. Minimum target 4.3 (needs `OS.execute_with_pipe` for the tunnel).
- Pure GDScript. No GDExtension, no native binaries in the repo.
- License: MIT. Repo: `splatterfacegames/godot-phone-mass-controllers`.
- Addon path: `addons/phone_mass_controllers/`. Prefix all class_names with `PMC`.

## 1. Transport

One TCP port serves both HTTP/1.1 and WebSocket (RFC 6455), so a single tunnel hostname works.

- The addon has its own HTTP/1.1 request parser and WebSocket server implementation on `TCPServer` +
  `StreamPeerTCP`. Godot's `WebSocketPeer.accept_stream` can't share a port with HTTP once the
  headers have been read.
- WS upgrade path: `GET /pmc/ws`. Everything else is HTTP.
- WS must support:
  - masking (client→server required)
  - text + binary frames
  - fragmentation / continuation reassembly
  - ping/pong control frames
  - close handshake with codes
  - payloads up to `max_message_bytes` (default 1 MiB)
  - rejecting unmasked client frames and oversize messages
- No extensions (permessage-deflate is not negotiated).
- HTTP must support:
  - GET/HEAD
  - keep-alive
  - `Content-Length` responses, and chunked or streamed large file writes without blocking the frame
  - 400/404/405/413/500
  - path-traversal protection
  - MIME by extension
  - `Cache-Control: no-cache` for html/js
- Non-blocking. Poll from `_process` (or an optional internal thread; default is main thread).
  Per-frame I/O budget, so a slow phone can't stall the game.
- `bind_address` default `"*"`. `port` default 8080. If busy, try the next port up to `port + port_search`
  (default 20), and emit/return the actual port.
- Delivery order is guaranteed **per player (per socket), not across players**: `send`/`broadcast` queue
  frames that are flushed in the host's round-robin service order, so a frame queued for socket A and then
  one for socket B can reach B first. Tests and game logic must not rely on cross-player arrival order.

Known limits of the built-in server (deliberate scope cuts — use the Cloudflare tunnel for `https`/`wss`):

- **No TLS.** Plain `http`/`ws` on the LAN. `start_tunnel()` is the supported way to get TLS.
- **No permessage-deflate** — extensions are never negotiated.
- **Request bodies:** `Content-Length` only; `Transfer-Encoding: chunked` gets 501.
- **Caching:** no `ETag`/`If-None-Match`. `Range` supports a single range; multi-ranges are ignored (200).
- **Symlinks** in served trees are resolved and confined to the served root (403 on escape).
- **Reverse proxies:** only `CF-Connecting-IP` is trusted, and only while the tunnel is up. `Forwarded`/
  `X-Forwarded-For` are ignored, so per-address limits behind another proxy see the proxy's address.
- **Origin:** not checked on the WS upgrade by default; `check_origin` + `allowed_origins` opt in.
- The join URL is IPv4-only (see §3 `lan_addresses`).

## 2. Wire protocol

Text frames are JSON objects with a string field `t`. Types `pmc.*` are reserved for the addon.
Game messages use `t: "msg"` with the payload in `d`. **Binary frames are raw game payloads** (e.g.
FlatBuffers), passed through untouched in both directions.

Client → host:

| t | fields | notes |
|---|--------|-------|
| `pmc.hello` | `sdk:1`, `token?:string`, `name?:string`, `profile?:object`, `code?:string` | must be the first frame. `token` = rejoin; `code` defaults from `?code=` in the page URL |
| `pmc.ping` | `c:number` (client epoch ms) | |
| `pmc.profile` | `name?`, `profile?` | update identity |
| `pmc.auth` | `pin:string` | admin elevation |
| `pmc.leave` | | explicit leave (no grace) |
| `msg` | `d:any` | game message |

Host → client:

| t | fields | notes |
|---|--------|-------|
| `pmc.welcome` | `id:int`, `token:string`, `name`, `profile`, `rejoined:bool`, `admin:bool`, `server_ms:int` (epoch ms UTC), `join_url:string` | |
| `pmc.reject` | `code:string` (`bad_code`, `full`, `version`, `banned`, `bad_hello`), `reason:string` | then close 4000 |
| `pmc.pong` | `c`, `s:int` (epoch ms UTC) | clock-offset estimate; `s` is wall-clock epoch ms, so `serverNow()` is comparable to `turn_ends_at_ms`-style deadlines stamped from `Time.get_unix_time_from_system() * 1000` |
| `pmc.auth` | `ok:bool`, `locked_ms?:int`, `disabled?:bool` | 5 failures → 30 s per connection; 20 per address → 60 s; `admin_pin_max_failures` (default 20) across all addresses disables the PIN until restart (`disabled:true`) |
| `pmc.kicked` | `reason:string` | then close 4001 |
| `pmc.replaced` | | same token connected elsewhere, then close 4002 |
| `pmc.moved` | `url:string` | join URL changed (ephemeral tunnel). https→https pages may auto-follow; others should ask for a re-scan |
| `msg` | `d:any` | game message |

HTTP auth for custom routes: after join, pmc.js sets a `pmc_token` cookie (value = the rejoin token).
`require_player(req)` maps `?t=<token>` or that cookie to the joined player; serve nothing private without it.

While a tunnel is up the host is public: auto-generated join codes are 6 chars (24^6), and
`/pmc/info.json` + `/pmc/qr.png` (which reveal the join URL) answer only to loopback or a request
carrying a valid `?code=`. The controller page and `/pmc/pmc.js` stay public — phones need them to join.

Identity: the token is a random 128-bit hex string issued by the host. The same token reconnecting within
`grace_seconds` resumes the same `PMCPlayer` (same id, meta preserved) and emits `player_rejoined`. After grace
expires the player is removed with `player_left(player, "timeout")`. A token seen after removal starts
a new player, unless `remember_seconds` (default 3600) keeps a tombstone so the id and meta come back.
Tombstones are written only on `"timeout"` removal (and on `kick(..., remember := true)`) — a plain
`kick()` or `pmc.leave` drops the token, so the player comes back as someone new (new id, empty meta).

## 3. GDScript API

```gdscript
class_name PMCHost extends Node
# config
@export var port := 8080
@export var port_search := 20
@export var bind_address := "*"
@export var controller_dir := "res://controller"     # served at "/"; index.html default
@export var join_code := ""                           # non-empty => required (also embedded in QR as ?code=)
@export var max_players := 0                          # 0 = unlimited
@export var grace_seconds := 30.0
@export var remember_seconds := 3600.0
@export var heartbeat_seconds := 15.0                 # WS ping; dead sockets closed after 2 missed
@export var admin_pin := ""
@export var advertise_url := ""                       # override join URL (else best LAN IPv4, or tunnel URL)
@export var max_message_bytes := 1 << 20
@export var autostart := false
@export var no_joins_hint_seconds := 0.0                  # >0: emit no_joins_hint if the URL sits unjoined that long
@export var io_thread_enabled := false                  # worker thread does accept/read/write/frame decode; set before start()
# limits (selected): max_connections, max_connections_per_address, join_code_max_failures,
# join_code_block_seconds, admin_pin_max_failures (global PIN budget, default 20), header/body sizes, timeouts,
# check_origin + allowed_origins (opt-in WS Origin allow-list)

signal started(port: int)
signal stopped
signal player_joined(player: PMCPlayer)
signal player_rejoined(player: PMCPlayer)
signal player_disconnected(player: PMCPlayer)        # socket gone, grace running
signal player_left(player: PMCPlayer, reason: String) # "timeout" | "kicked" | "leave"
signal player_updated(player: PMCPlayer)             # name/profile changed
signal admin_authenticated(player: PMCPlayer)
signal message_received(player: PMCPlayer, data)     # Variant from JSON `d`, or PackedByteArray
signal join_url_changed(url: String)
signal no_joins_hint                                 # no joins within no_joins_hint_seconds of the URL going up (0 = off)

func start() -> Error
func stop() -> void
func is_running() -> bool
func get_port() -> int
func join_url() -> String                             # includes ?code= when join_code set
func lan_addresses() -> Array[Dictionary]             # {name, address, score}; best first (real adapters over virtual/VPN)
func qr_image(module_px := 8, quiet := 4) -> Image
func qr_texture(module_px := 8) -> ImageTexture
func players(include_disconnected := true) -> Array[PMCPlayer]
func get_player(id: int) -> PMCPlayer
func send(to, data) -> void                           # to: PMCPlayer | int; data: Dictionary/Array/String/number (JSON msg) or PackedByteArray (binary)
func broadcast(data, filter: Callable = Callable()) -> void   # filter(player) -> bool
func kick(to, reason := "", ban := false, remember := false) -> void   # remember: keep a tombstone so the token rejoins with id+meta; ban: refuse the token
func add_route(prefix: String, handler: Callable) -> void     # handler(req: PMCHttpRequest) -> PMCHttpResponse or null (fall through)
func serve_directory(prefix: String, dir: String, players_only := false) -> void  # players_only: require a joined player's token (?t= or pmc_token cookie) else 403
func require_player(req: PMCHttpRequest) -> PMCPlayer          # player for ?t=<token> or the pmc_token cookie, else null → respond 403
func start_tunnel() -> void                           # one-click outside-LAN (see §5); sets advertise URL on success
func stop_tunnel() -> void
signal tunnel_state_changed(state: String, url: String)       # "downloading" | "starting" | "ready" | "failed" | "stopped"

class_name PMCPlayer extends RefCounted
var id: int; var token: String; var name: String; var profile: Dictionary
var connected: bool; var is_admin: bool; var meta: Dictionary
var joined_msec: int; var last_seen_msec: int; var grace_deadline_msec: int
var remote_address: String
var rtt_ms: float      # rolling average of the WS heartbeat ping→pong round trip (0 until first sample)
```

Optional helpers extracted from a real party game's lobby (pure logic, no networking, fully unit-tested):

```gdscript
class_name PMCQueue extends RefCounted      # ordered play queue
func push(id: int) / remove(id: int) / position(id: int) -> int / ids() -> Array[int]
func pop_next(n: int, is_eligible: Callable) -> Array[int]   # skips ineligible (e.g. disconnected), keeps their spot

class_name PMCVote extends RefCounted       # proposal vote with vetoes
func open(proposal_id: int, eligible: Array[int], ends_msec: int, vetoers: Dictionary)  # vetoers: id -> vetoes left
func cast(id: int, approve: bool) -> bool
func veto(id: int) -> bool
func tally() -> Dictionary                  # {yes, no, eligible, decided: "" | "approved" | "rejected" | "vetoed"}
func expire(now_msec: int) -> String        # majority-at-timeout rule: yes >= no approves

class_name PMCRotation extends RefCounted   # who plays next
enum Policy { WINNER_STAYS, LOSER_STAYS, STRICT }
func next_pair(policy, last_blue: int, last_red: int, winner: int, streaks: Dictionary, queue: PMCQueue, is_eligible: Callable, max_streak := 2) -> Array[int]
```

## 4. JS SDK — served at `/pmc/pmc.js` (ES module) + `pmc.d.ts`

```js
import { connect, feedback, keepScreenOn, vibrate, wakeLock } from '/pmc/pmc.js';
const pmc = connect({ name, profile, code /* default: ?code= from location */, tokenKey });
pmc.on('welcome', ({id, rejoined}) => {}); pmc.on('message', d => {}); pmc.on('binary', ab => {});
pmc.on('status', s => {});            // 'connecting' | 'open' | 'reconnecting' | 'closed'
pmc.on('reject', ({code, reason}) => {}); pmc.on('kicked', r => {}); pmc.on('replaced', () => {});
pmc.on('moved', ({url}) => {});       // join URL changed (ephemeral tunnel)
pmc.send(obj); pmc.sendBinary(arrayBufferOrView); pmc.auth(pin) /* Promise<boolean> */;
pmc.setProfile({name, profile}); pmc.leave();
pmc.id; pmc.serverNow(); pmc.timestamp();  // host-clock ms, offset-corrected
pmc.rttMs;                            // rolling avg round-trip ms
```
- Token in localStorage, keyed by origin (two tabs in one browser = same player; `tokenKey` overrides for
  per-tab identities). Also mirrored to a `pmc_token` cookie (`path=/`, `SameSite=Strict`) that gated custom
  routes can check. Reconnect with jittered exponential backoff, capped at 5 s.
- `wss:` when the page is https (tunnel).
- Never retry after `reject`/`kicked`/`replaced`.
- `pmc.moved`: auto-follow only https→https after a reachability check; a LAN (`http://`) page never navigates
  itself — show "re-scan the QR" on the `moved` event.
- `vibrate(pattern)` feature-detects (absent on iOS). `feedback('buzz'|'success'|'error')` vibrates where
  possible, else a 60 ms screen flash + WebAudio click (audio only after a user gesture).
- `wakeLock()` requests a screen wake lock (secure contexts only). `keepScreenOn()` uses it where allowed and
  otherwise plays a muted looping clip on the next user gesture (NoSleep-style).
- `timestamp()` stamps inputs on the estimated host clock; hosts should credit them bounded by the player's
  RTT (also exposed as `player.rtt_ms`) so remote players stay competitive.
- Zero dependencies, no build step for consumers.

## 5. Outside-LAN join: one-click Cloudflare Quick Tunnel

`PMCTunnel` (used by `PMCHost.start_tunnel()` and an editor dock button):

1. Resolve `cloudflared`: export var path → env `PMC_CLOUDFLARED` → `PATH` → `user://pmc/bin/cloudflared[.exe]`.
2. If missing, download the official release asset for the OS/arch from
   `https://github.com/cloudflare/cloudflared/releases/latest/download/…` (windows-amd64.exe, linux-amd64,
   linux-arm64, darwin `.tgz`, extracted via `tar`). Verify it runs `--version`. Download requires `allow_download=true`,
   default true in the editor and false at runtime unless the game opts in.
3. Run `cloudflared tunnel --no-autoupdate --url http://127.0.0.1:<port>` via `OS.execute_with_pipe`. Read stderr
   for `https://<random>.trycloudflare.com` and wait for the "Registered tunnel connection" line.
4. On ready: `advertise_url` = tunnel URL, `join_url_changed`, QR regenerates. **If `join_code` is empty, auto-generate
   a 6-letter code** (24^6 ≈ 191M — the host is now on the public internet). The QR and `join_url()` carry it
   as `?code=`; while tunneled, `/pmc/info.json` and `/pmc/qr.png` answer only to loopback or a valid `?code=`.
5. Kill the process on `stop_tunnel()`, host `stop()`, and `NOTIFICATION_WM_CLOSE_REQUEST` / exit.
   Surface failures (no network, download blocked, process exit) through `tunnel_state_changed("failed", reason)`.

Quick Tunnels need no Cloudflare account, but URLs are ephemeral and there is no uptime guarantee. The caveats are tracked as GitHub issues.

## 6. Editor plugin

`plugin.cfg` + `plugin.gd`. `PMCHost` registers via `class_name` alone (icon via `@icon` on host.gd) so it appears
once in *Create Node*. The plugin adds a bottom dock "Phone Controllers" that shows the running game's host status
and offers "Download cloudflared", a throwaway test tunnel, and docs links.

- **Running-game status.** When the game runs from the editor (`OS.has_feature("editor")` + active debugger),
  `PMCHost._ready` attaches `editor/ingame_reporter.gd`, which pushes `pmc:status` payloads over `EngineDebugger`
  on host changes (plus a 2 s heartbeat) and answers `pmc:status` polls. Editor side, `editor/debugger_plugin.gd`
  (an `EditorDebuggerPlugin` registered with `add_debugger_plugin`, capturing `pmc:*`) forwards payloads to the
  dock, which renders port, join URL + QR, connected players and tunnel state.
- **Exports.** `editor/export_plugin.gd` (`EditorExportPlugin`) re-packs served `res://` directories as raw files
  so imported/unrecognized assets survive the pck: `web/` (the SDK), `res://controller` when present,
  `controller_dir` on `PMCHost` nodes in `.tscn` scenes, and `res://` literals in `serve_directory`/`controller_dir`
  assignments across `.gd` sources. The collection logic lives in `editor/export_scan.gd` (unit-tested); see
  [docs/exporting.md](docs/exporting.md).

## 7. Repo layout

```
addons/phone_mass_controllers/   the addon (host.gd, player.gd, http/, ws/, qr/, tunnel/, lobby/, web/pmc.js, web/pmc.d.ts, editor/, plugin.cfg, plugin.gd, LICENSE)
demo/                            runnable Godot demo: "Buzzer Party" (lobby with QR + roster, rounds, private per-player prompts, rejoin)
demo/controller/                 its controller page (plain HTML + pmc.js)
tests/                           headless GDScript suites (run_tests.gd) + tests/node (ws interop, QR decode) + tests/browser (Playwright, optional in CI)
.github/workflows/ci.yml
README.md  LICENSE  CHANGELOG.md  SPEC.md
```

## 8. Quality bar

- **Interop:** Godot's own `WebSocketPeer` client and Node `ws` client both pass (text, binary, fragmented, 1 MiB, ping, close).
  Browser (Chromium via Playwright) runs the SDK + demo controller.
- **QR:** the encoder's matrices for a corpus of URLs (versions 1–10, EC level M) are decoded by an independent decoder (`jsqr`
  in tests/node). Byte-exact match vs `qrcode` npm is nice-to-have, not required.
- **Robustness:**
  - malformed HTTP, garbage WS frames, slowloris-ish partial headers (timeout), and 200 concurrent sockets don't crash or stall the host
  - frame-time impact measured and reported in README
- Everything in CI on ubuntu with Godot 4.7.1 headless.
- The public repo contains no third-party game assets and no references to any private project.
