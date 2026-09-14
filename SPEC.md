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

## 2. Wire protocol

Text frames are JSON objects with a string field `t`. Types `pmc.*` are reserved for the addon.
Game messages use `t: "msg"` with the payload in `d`. **Binary frames are raw game payloads** (e.g.
FlatBuffers), passed through untouched in both directions.

Client → host:

| t | fields | notes |
|---|--------|-------|
| `pmc.hello` | `sdk:1`, `token?:string`, `name?:string`, `profile?:object`, `code?:string` | must be the first frame. `token` = rejoin |
| `pmc.ping` | `c:number` (client ms) | |
| `pmc.profile` | `name?`, `profile?` | update identity |
| `pmc.auth` | `pin:string` | admin elevation |
| `pmc.leave` | | explicit leave (no grace) |
| `msg` | `d:any` | game message |

Host → client:

| t | fields | notes |
|---|--------|-------|
| `pmc.welcome` | `id:int`, `token:string`, `name`, `profile`, `rejoined:bool`, `admin:bool`, `server_ms:int`, `join_url:string` | |
| `pmc.reject` | `code:string` (`bad_code`, `full`, `version`, `banned`, `bad_hello`), `reason:string` | then close 4000 |
| `pmc.pong` | `c`, `s:int` (server ms) | clock-offset estimate |
| `pmc.auth` | `ok:bool` | 5 failures → 30 s lockout per connection |
| `pmc.kicked` | `reason:string` | then close 4001 |
| `pmc.replaced` | | same token connected elsewhere, then close 4002 |
| `pmc.moved` | `d.url:string` | join URL changed mid-session (tunnel replaced); sent before the old tunnel goes down — the client should show "rescan/rejoin at the new URL" |
| `msg` | `d:any` | game message |

Identity: the token is a random 128-bit hex string issued by the host. The same token reconnecting within
`grace_seconds` resumes the same `PMCPlayer` (same id, meta preserved) and emits `player_rejoined`. After grace
expires the player is removed with `player_left(player, "timeout")`. A token seen after removal starts
a new player, unless `remember_seconds` (default 3600) keeps a tombstone so the id and meta come back.

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
func kick(to, reason := "") -> void
func add_route(prefix: String, handler: Callable) -> void     # handler(req: PMCHttpRequest) -> PMCHttpResponse or null (fall through)
func serve_directory(prefix: String, dir: String) -> void     # e.g. serve_directory("/assets/", "C:/game/assets") — absolute or res:// or user://
@export_group("Tunnel")
@export var tunnel_allow_download := true             # fetch cloudflared when missing
@export var cloudflared_path := ""
@export var tunnel_mode := "quick"                    # "quick" | "named"
@export var named_tunnel_token := ""                  # dashboard "run with token" token
@export var named_tunnel_hostname := ""               # public hostname routed to the tunnel
@export var tunnel_verify_dns := true                 # wait for the new hostname to resolve before ready
@export var tunnel_ready_timeout_sec := 60.0
@export var tunnel_extra_args: PackedStringArray = [] # e.g. ["--protocol", "http2"]
@export var tunnel_join_code := ""                    # used as-is, never auto-cleared
@export var tunnel_auto_restart := true               # bounded relaunch after a lost tunnel
@export var tunnel_restart_delay_sec := 2.0

func start_tunnel(code := "") -> void                 # outside-LAN (see §5); code overrides join_code. No-op while a healthy tunnel is up.
func restart_tunnel(code := "") -> void               # rolling replace: pmc.moved to players, then the old tunnel dies
func stop_tunnel() -> void
signal tunnel_state_changed(state: String, url: String)       # "downloading" | "starting" | "ready" | "lost" | "failed" | "stopped"

class_name PMCPlayer extends RefCounted
var id: int; var token: String; var name: String; var profile: Dictionary
var connected: bool; var is_admin: bool; var meta: Dictionary
var joined_msec: int; var last_seen_msec: int; var grace_deadline_msec: int
var remote_address: String
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
import { connect, vibrate, wakeLock } from '/pmc/pmc.js';
const pmc = connect({ name, profile, code /* default: ?code= from location */ });
pmc.on('welcome', ({id, rejoined}) => {}); pmc.on('message', d => {}); pmc.on('binary', ab => {});
pmc.on('status', s => {});            // 'connecting' | 'open' | 'reconnecting' | 'closed'
pmc.on('reject', ({code, reason}) => {}); pmc.on('kicked', r => {});
pmc.send(obj); pmc.sendBinary(arrayBufferOrView); pmc.auth(pin) /* Promise<boolean> */;
pmc.setProfile({name, profile}); pmc.leave();
pmc.id; pmc.serverNow();              // ms, clock-offset corrected
```
- Token in localStorage, keyed by origin. Reconnect with jittered exponential backoff, capped at 5 s.
- `wss:` when the page is https (tunnel).
- Never retry after `reject`/`kicked`/`replaced`.
- `vibrate(pattern)` feature-detects. `wakeLock()` requests a screen wake lock when available (secure contexts only) and falls back silently.
- Zero dependencies, no build step for consumers.

## 5. Outside-LAN join: Cloudflare tunnels (quick + named)

`PMCTunnel` (used by `PMCHost.start_tunnel()` / `restart_tunnel()` and the editor dock):

1. Resolve `cloudflared`: export var path → env `PMC_CLOUDFLARED` → `PATH` → `user://pmc/bin/cloudflared[.exe]`.
2. If missing, download the official release asset for the OS/arch from
   `https://github.com/cloudflare/cloudflared/releases/latest/download/…` (windows-amd64.exe, linux-amd64,
   linux-arm64, darwin `.tgz`, extracted via `tar`). The binary must then pass: SHA-256 vs the release's GitHub
   API digest, `cloudflared --version` ≥ `minimum_version` (default 2022.6.2), and an OS code-signature check
   where supported (Windows Authenticode — must be Valid and signed by Cloudflare, Inc. when a signature is
   present; macOS `codesign --verify`, with `spctl` for notarization; unsigned binaries fall back to the digest
   check — Linux users should prefer their distro's signed Cloudflare package). A managed binary older than
   `binary_max_age_days` (default 30) is re-verified against the latest release and refreshed when it drifted.
   Download requires `allow_download=true` (default: editor on, runtime off unless the game opts in).
3. **Quick mode** runs `cloudflared tunnel --no-autoupdate --config <isolated> --url http://127.0.0.1:<port>`
   via `OS.execute_with_pipe`. The always-isolated `--config` keeps a default `~/.cloudflared/config.yml`
   (left over from named-tunnel setups) from breaking the quick tunnel. stderr is read for
   `https://<random>.trycloudflare.com` and "Registered tunnel connection"; with `verify_dns` the hostname must
   also resolve over DNS-over-HTTPS before `ready`.
   **Named mode** runs `cloudflared tunnel --no-autoupdate run --token <named_token>`, or — with
   `named_tunnel` + `named_credentials_file` — a generated `named-tunnel.yml` (ingress hostname →
   `http://127.0.0.1:<port>`) and `run <named_tunnel>`. No trycloudflare URL is printed; the URL is
   `https://<named_hostname>`.
4. States: `downloading` → `starting` → `ready` → `lost` (every edge connection unregistered for
   `lost_grace_sec`, or the process exits post-ready; an alive process can return to `ready` on
   re-registration) → `stopped` / `failed`. Creation failures (HTTP 429 / error 1015) retry with exponential
   backoff (`max_retries` default 2, `retry_backoff_sec` default 4 s). When QUIC (UDP 7844) looks blocked —
   its signature errors in the log, or registration stalling past `protocol_fallback_sec` after the URL was
   issued — cloudflared relaunches once with `--protocol http2` (skipped when `extra_args` already sets a
   protocol). Common error lines map to actionable hints ("rate-limited", "UDP blocked", "DNS filter").
5. On `ready`: `advertise_url` = tunnel URL, `join_url_changed`, QR regenerates. `join_code` empty →
   auto-generate a 4-letter code; `start_tunnel(code)` or `tunnel_join_code` supplies one that is used as-is
   and never auto-cleared. The QR/join URL is only ever shown post-`ready` — a phone that resolves a
   brand-new hostname too early can sit on a cached NXDOMAIN for ~90 s (fix: airplane-mode toggle or wait).
6. Lifecycle: `stop_tunnel()` and freeing the host kill the child process; the pid is recorded in
   `user://pmc/cloudflared.pid` and a leftover from a crashed engine is reaped on the next `start()` — only
   when the pid's command line still looks like cloudflared, so a recycled pid is never killed. A `ready`
   tunnel survives `stop()`→`start()` on the same port (retargeted when the port changed) and a host
   teardown detaches it to the scene root, where the next `start_tunnel()` re-adopts it within ~2 minutes.
7. `restart_tunnel()` performs a rolling restart: the replacement tunnel reaches `ready` first, all joined
   players get `{"t":"pmc.moved","d":{"url":<new join url>}}`, then the old tunnel stops. A `lost` tunnel is
   auto-restarted by the host (`tunnel_auto_restart`, `tunnel_restart_delay_sec`, bounded per `start_tunnel`).

Quick Tunnels need no Cloudflare account, but URLs are ephemeral, best-effort, rate-limited (HTTP 429,
~200 concurrent in-flight requests, no SSE) and come with no uptime guarantee — use a named tunnel (or
another provider, see docs/tunnels.md) for anything you want to print or keep.

## 6. Editor plugin

`plugin.cfg` + `plugin.gd`: adds a `PMCHost` custom node type and a bottom dock "Phone Controllers" that shows
the host status of the running game where possible. In-editor it offers "Download cloudflared" and a docs link.

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
