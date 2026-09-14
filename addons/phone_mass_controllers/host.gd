class_name PMCHost
extends Node
## Hosts phone controllers: an HTTP/1.1 + WebSocket server on one TCP port, plus player sessions.
##
## Add a [PMCHost] to your scene, point [member controller_dir] at your controller page, and call [method start]
## (or enable [member autostart]). Phones open [method join_url] (show [method qr_texture]), load the page,
## and connect with [code]/pmc/pmc.js[/code]. Game messages arrive via [signal message_received]. Reply with
## [method send] or [method broadcast].
## [br][br]
## Everything runs on the main thread and is polled from [method Node._process] (or call [method poll] yourself
## with [member auto_poll] off). Socket work per frame is capped by [member io_budget_msec].
## [br][br]
## Built-in HTTP routes: [code]/pmc/ws[/code] (WebSocket), [code]/pmc/pmc.js[/code] and [code]/pmc/pmc.d.ts[/code] (SDK),
## [code]/pmc/qr.png[/code], [code]/pmc/info.json[/code] and [code]/pmc/healthz[/code].

## Wire protocol version (the [code]sdk[/code] field of [code]pmc.hello[/code]).
const SDK_VERSION := 1
## Addon version.
const VERSION := "0.1.0"
## Longest accepted display name.
const MAX_NAME_LENGTH := 32
## Where the JS SDK files live. They're served at /pmc/.
const WEB_DIR := "res://addons/phone_mass_controllers/web"

## Emitted after the server starts listening, with the actual port.
signal started(port: int)
## Emitted after [method stop].
signal stopped
## A new player completed the hello handshake. Also emitted when a tombstoned token comes back (same id and meta).
signal player_joined(player: PMCPlayer)
## A known player reconnected within the grace period (or replaced its own socket).
signal player_rejoined(player: PMCPlayer)
## A player's socket closed. They stay in [method players] until [member grace_seconds] runs out.
signal player_disconnected(player: PMCPlayer)
## A player was removed. [param reason] is [code]"timeout"[/code], [code]"kicked"[/code] or [code]"leave"[/code].
signal player_left(player: PMCPlayer, reason: String)
## A player's name or profile changed.
signal player_updated(player: PMCPlayer)
## A player sent the correct [member admin_pin].
signal admin_authenticated(player: PMCPlayer)
## A game message: the JSON [code]d[/code] value of a [code]msg[/code] frame, or a [PackedByteArray] for binary frames.
signal message_received(player: PMCPlayer, data)
## The join URL changed (start, port, [member advertise_url], [member join_code], tunnel).
signal join_url_changed(url: String)
## Tunnel progress: [code]"downloading"[/code], [code]"starting"[/code], [code]"ready"[/code] (url = public URL),
## [code]"failed"[/code] (url = reason) or [code]"stopped"[/code].
signal tunnel_state_changed(state: String, url: String)

## Preferred TCP port. [code]0[/code] picks a free ephemeral port.
@export var port := 8080
## If [member port] is busy, try up to this many ports above it.
@export var port_search := 20
## Interface to bind: [code]"*"[/code] for all, or an IP address.
@export var bind_address := "*"
## Directory served at [code]/[/code] (index.html by default). It can be res://, user:// or an absolute path.
@export var controller_dir := "res://controller"
## When non-empty, new players must send this code (case-insensitive). It's included in [method join_url] as [code]?code=[/code].
@export var join_code := "":
	set(v):
		if v == join_code:
			return
		join_code = v
		_url_changed()
## Maximum players, including those in their grace period. 0 means unlimited.
@export var max_players := 0
## Seconds a disconnected player keeps their slot before [signal player_left] with "timeout".
@export var grace_seconds := 30.0
## Seconds a timed-out player's token is remembered, so the same id and meta come back on reconnect.
@export var remember_seconds := 3600.0
## WebSocket ping interval. A socket is closed after 2 intervals with no inbound frame. 0 disables it.
@export var heartbeat_seconds := 15.0
## PIN for [code]pmc.auth[/code] admin elevation. Empty means admin auth always fails.
@export var admin_pin := ""
## Overrides the join URL base (e.g. [code]"https://example.com/"[/code]). Empty uses the best LAN IPv4 (or the tunnel URL).
@export var advertise_url := "":
	set(v):
		if v == advertise_url:
			return
		advertise_url = v
		_url_changed()
## Largest accepted WebSocket message (after reassembly).
@export var max_message_bytes := 1 << 20
## Call [method start] in [method Node._ready].
@export var autostart := false

@export_group("Limits")
## Poll sockets automatically from [method Node._process]. Turn it off to call [method poll] yourself.
@export var auto_poll := true
## Maximum time spent on socket I/O per [method poll]. Connections not reached continue next frame (round-robin).
## Lower values cap frame-time spikes but add latency under heavy traffic, because unserviced sockets wait a frame.
## It's checked every 8 connections, so a single poll can overshoot it slightly.
@export var io_budget_msec := 8.0
## Maximum simultaneous TCP connections. Extra ones are closed on accept.
@export var max_connections := 512
## Seconds a client has to send a complete request head (slowloris protection). Idle keep-alive sockets close after it too.
@export var header_timeout_seconds := 10.0
## Largest request head (request line + headers).
@export var max_header_bytes := 16384
## Largest HTTP request body (for [method add_route] handlers).
@export var max_body_bytes := 65536
## Seconds a WebSocket has to send [code]pmc.hello[/code].
@export var hello_timeout_seconds := 10.0
## Unsent bytes allowed per connection before it's dropped as too slow.
@export var max_backlog_bytes := 16 << 20
## Maximum simultaneous connections from one client address. 0 means unlimited. Behind a tunnel the address comes
## from [code]CF-Connecting-IP[/code], so players sharing a venue's public IP count together. Keep it generous.
@export var max_connections_per_address := 128
## Wrong join codes an address may send (within [member join_code_block_seconds]) before it's blocked.
@export var join_code_max_failures := 10
## How long an address is blocked after too many wrong join codes. New joins from it are refused with [code]bad_code[/code].
@export var join_code_block_seconds := 60.0

@export_group("Tunnel")
## Let [method start_tunnel] download cloudflared if it isn't found.
@export var tunnel_allow_download := false
## Explicit cloudflared executable path (optional).
@export var cloudflared_path := ""

const _TIMER_MSEC := 50
const _STATUS_EVERY_FRAMES := 15
const _READ_CAP := 262144
const _WRITE_CAP := 1 << 20
const _STALL_MSEC := 30000
const _CLOSE_HANDSHAKE_MSEC := 1000
const _AUTH_MAX_FAILURES := 5
const _AUTH_LOCK_MSEC := 30000
const _AUTH_ADDR_MAX_FAILURES := 20
const _AUTH_ADDR_LOCK_MSEC := 60000
const _CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ"

var _server: TCPServer = null
var _running := false
var _port := 0
var _conns: Array[PMCConnection] = []
var _rr := 0
var _addr_conns: Dictionary = {}    # client address -> open connection count
var _addr_failures: Dictionary = {} # "kind|address" -> {count, window_end_msec, blocked_until_msec}
var _bytes_in := 0
var _bytes_out := 0
var _msgs_in := 0
var _msgs_out := 0
var _frame := 0
var _last_timer_msec := 0
var _closed_pending := false
var _players: Dictionary = {}     # id -> PMCPlayer
var _by_token: Dictionary = {}    # token -> PMCPlayer
var _tombstones: Dictionary = {}  # token -> {id, name, profile, meta, expires_msec}
var _banned: Dictionary = {}      # token -> true
var _next_id := 1
var _routes: Array[Dictionary] = []   # {prefix, handler}
var _mounts: Array[Dictionary] = []   # {prefix, dir}
var _last_sweep_msec := 0
var _crypto := Crypto.new()
var _json := JSON.new()
var _lan_cache: Array[Dictionary] = []
var _lan_cache_msec := -100000
var _class_cache: Dictionary = {}
var _suppress_url_signal := false
var _tunnel: Object = null
var _tunnel_prev_advertise := ""
var _tunnel_set_advertise := false
var _tunnel_generated_code := false
var _stats := {
	"http_requests": 0, "ws_messages_in": 0, "ws_messages_out": 0, "bytes_in": 0, "bytes_out": 0,
	"last_poll_usec": 0, "max_poll_usec": 0, "accepted": 0, "refused": 0,
}


func _ready() -> void:
	set_process(_running and auto_poll)  # start() may have been called before the node entered the tree
	if autostart and not Engine.is_editor_hint():
		start()


func _process(_delta: float) -> void:
	if auto_poll:
		poll()


func _exit_tree() -> void:
	if is_queued_for_deletion():
		stop()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()
	elif what == NOTIFICATION_PREDELETE:
		_shutdown(false)


# --------------------------------------------------------------------------------------------------
# Lifecycle

## Starts listening on [member port] (or the next free port, up to [member port_search] above it).
## Returns [constant OK], or the last listen error.
func start() -> Error:
	if _running:
		return OK
	_server = TCPServer.new()
	var err: Error = FAILED
	var tries := 1 if port == 0 else maxi(0, port_search) + 1
	for i in tries:
		var p := port + i
		if p > 65535:
			break
		if p != 0 and bind_address == "*" and not _ipv4_port_free(p):
			# "*" binds an IPv6 dual-stack socket, which can succeed even while another process owns the
			# port on IPv4 (e.g. Windows netsh portproxy / iphlpsvc). IPv4 clients would reach that process.
			err = ERR_ALREADY_IN_USE
			continue
		err = _server.listen(p, bind_address)
		if err == OK:
			break
	if err != OK:
		push_error("PMCHost: couldn't listen on %s:%d-%d (%s)" % [bind_address, port, port + tries - 1, error_string(err)])
		_server = null
		return err
	_port = _server.get_local_port()
	_running = true
	_last_sweep_msec = Time.get_ticks_msec()
	set_process(auto_poll)
	started.emit(_port)
	join_url_changed.emit(join_url())
	return OK


static func _ipv4_port_free(p: int) -> bool:
	var probe := TCPServer.new()
	var ok := probe.listen(p, "0.0.0.0") == OK
	probe.stop()
	return ok


## Stops the server, closes every socket (WebSocket close 1001) and forgets all players, tombstones and bans.
## No player signals are emitted.
func stop() -> void:
	if not _running:
		return
	_shutdown(true)
	stopped.emit()


func _shutdown(graceful: bool) -> void:
	if _tunnel != null:
		_stop_tunnel_internal(false)
	if not _running:
		return
	_running = false
	for c in _conns:
		if graceful and c.mode == PMCConnection.Mode.WS and not c.close_sent:
			c.queue(PMCWsFrame.close(1001, "server stopping"))
			c.flush(65536)
		c.close_now("stopped")
	_conns = []
	for p in _players.values():
		p._conn = null
		p.connected = false
	_players.clear()
	_by_token.clear()
	_tombstones.clear()
	_banned.clear()
	_addr_conns.clear()
	_addr_failures.clear()
	if _server != null:
		_server.stop()
		_server = null
	if is_inside_tree():
		set_process(false)


## Whether the server is listening.
func is_running() -> bool:
	return _running


## The port actually bound, or [member port] when not running.
func get_port() -> int:
	return _port if _running else port


## Counters for diagnostics: connections, websockets, players, http_requests, ws_messages_in/out,
## bytes_in/out, last_poll_usec, max_poll_usec, accepted, refused.
func get_stats() -> Dictionary:
	var d := _stats.duplicate()
	d["ws_messages_in"] = _msgs_in
	d["ws_messages_out"] = _msgs_out
	d["bytes_in"] = _bytes_in
	d["bytes_out"] = _bytes_out
	var ws := 0
	for c in _conns:
		if c.mode == PMCConnection.Mode.WS:
			ws += 1
	d["connections"] = _conns.size()
	d["websockets"] = ws
	d["players"] = _players.size()
	return d


## Resets [code]max_poll_usec[/code] in [method get_stats].
func reset_poll_stats() -> void:
	_stats["max_poll_usec"] = 0


# --------------------------------------------------------------------------------------------------
# Join URL / LAN / QR

## The URL players open. It's [member advertise_url] (or the tunnel URL), or else
## [code]http://<best LAN IPv4>:<port>/[/code], with [code]?code=[/code] added when [member join_code] is set.
func join_url() -> String:
	var base := advertise_url.strip_edges()
	if base == "":
		var addrs := lan_addresses()
		var host_ip: String = addrs[0]["address"] if addrs.size() > 0 else "127.0.0.1"
		base = "http://%s:%d/" % [host_ip, get_port()]
	if not base.contains("://"):
		base = "http://" + base
	var scheme_end := base.find("://") + 3
	if base.find("/", scheme_end) < 0:
		var q := base.find("?", scheme_end)
		base = base + "/" if q < 0 else base.insert(q, "/")
	if join_code != "":
		base += ("&" if base.contains("?") else "?") + "code=" + join_code.uri_encode()
	return base


## Local IPv4 addresses, best first: [code]{name, address, score}[/code]. Private addresses on physical Ethernet/Wi-Fi
## adapters rank above virtual, VPN and container adapters (vEthernet/WSL/Hyper-V, VirtualBox, VMware,
## Tailscale, ZeroTier, Docker, ...). Loopback is excluded. Cached for 30 seconds
## ([method IP.get_local_interfaces] can take several milliseconds on Windows).
func lan_addresses() -> Array[Dictionary]:
	var now := Time.get_ticks_msec()
	if now - _lan_cache_msec < 30000:
		return _lan_cache.duplicate()
	var out: Array[Dictionary] = []
	for iface in IP.get_local_interfaces():
		var friendly: String = iface.get("friendly", "")
		var raw_name: String = iface.get("name", "")
		var name := friendly if friendly != "" else raw_name
		for addr in iface.get("addresses", []):
			var a := String(addr)
			if not _is_ipv4(a) or a.begins_with("127."):
				continue
			out.append({"name": name, "address": a, "score": score_address(name if raw_name == "" or raw_name == name else name + " " + raw_name, a)})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if x.score != y.score:
			return x.score > y.score
		return x.address < y.address)
	_lan_cache = out
	_lan_cache_msec = now
	return out.duplicate()


const _VIRTUAL_HINTS := ["vethernet", "wsl", "hyper-v", "virtualbox", "vbox", "vmware", "vmnet", "tailscale",
	"zerotier", "docker", "vpn", "loopback", "wireguard", "hamachi", "npcap", "bluetooth", "pseudo", "teredo",
	"isatap", "nordlynx", "parallels", "virtual", "tunnel", "radmin"]
const _VIRTUAL_PREFIXES := ["wg", "tun", "tap", "utun", "br-", "veth", "virbr", "vnic", "zt", "lo", "awdl", "llw",
	"anpi", "bridge", "ipsec", "ppp", "gif", "stf", "cni", "flannel", "cali", "vboxnet", "lxc", "lxd", "incus"]
const _PHYSICAL_HINTS := ["ethernet", "wi-fi", "wifi", "wlan", "wireless", "local area connection"]
const _PHYSICAL_PREFIXES := ["eth", "en", "wl", "wlan", "wlp", "enp", "eno", "ens"]


## Scores an IPv4 [param address] on an adapter called [param iface_name] (higher is better). Used by [method lan_addresses].
static func score_address(iface_name: String, address: String) -> int:
	if not _is_ipv4(address):
		return -1000
	var o := address.split(".")
	var a := o[0].to_int()
	var b := o[1].to_int()
	var c := o[2].to_int()
	var s := 0
	if a == 127:
		return -1000
	if a == 169 and b == 254:
		s = -300
	elif a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31):
		s = 100
	elif a == 100 and b >= 64 and b <= 127:
		s = 20  # CGNAT range, used by Tailscale
	else:
		s = 50
	var n := iface_name.to_lower()
	var is_virtual := false
	for h in _VIRTUAL_HINTS:
		if n.contains(h):
			is_virtual = true
			break
	if not is_virtual:
		for word in n.split(" ", false):
			for pre in _VIRTUAL_PREFIXES:
				if word.begins_with(pre) and not (pre == "lo" and word.begins_with("local")):
					is_virtual = true
					break
			if is_virtual:
				break
	if is_virtual:
		s -= 200
	else:
		var physical := false
		for h in _PHYSICAL_HINTS:
			if n.contains(h):
				physical = true
		for word in n.split(" ", false):
			for pre in _PHYSICAL_PREFIXES:
				if word.begins_with(pre):
					physical = true
		if physical:
			s += 20
	if a == 192 and b == 168 and c == 56:
		s -= 40  # VirtualBox host-only default
	if a == 172 and b == 17:
		s -= 40  # Docker default bridge
	return s


static func _is_ipv4(a: String) -> bool:
	return a.is_valid_ip_address() and not a.contains(":")


## A QR code [Image] of [method join_url]. Returns [code]null[/code] when the QR encoder ([code]PMCQr[/code]) isn't available.
func qr_image(module_px := 8, quiet := 4) -> Image:
	var qr = _global_class("PMCQr")
	if qr == null:
		push_warning("PMCHost: PMCQr class not found")
		return null
	var m = qr.encode(join_url())
	if m == null:
		return null
	return qr.to_image(m, module_px, quiet)


## [method qr_image] as an [ImageTexture] (quiet zone of 4 modules), or [code]null[/code].
func qr_texture(module_px := 8) -> ImageTexture:
	var img := qr_image(module_px, 4)
	return ImageTexture.create_from_image(img) if img != null else null


# --------------------------------------------------------------------------------------------------
# Players

## Players ordered by id. With [param include_disconnected] false, only players with a live socket are included.
func players(include_disconnected := true) -> Array[PMCPlayer]:
	var out: Array[PMCPlayer] = []
	for p in _players.values():
		if include_disconnected or p.connected:
			out.append(p)
	out.sort_custom(func(x: PMCPlayer, y: PMCPlayer) -> bool: return x.id < y.id)
	return out


## The player with [param id], or [code]null[/code].
func get_player(id: int) -> PMCPlayer:
	return _players.get(id)


## Sends to one player ([PMCPlayer] or id). [PackedByteArray] goes out as a binary frame. Anything else is
## JSON-encoded as [code]{"t":"msg","d":data}[/code]. Players without a socket are skipped (nothing is queued).
func send(to, data) -> void:
	var p := _resolve(to)
	if p == null or p._conn == null:
		return
	var c: PMCConnection = p._conn
	if c.close_sent or not c.is_open():
		return
	c.queue(_encode_msg(data))
	_msgs_out += 1


## Sends to every connected player, or only those where [code]filter.call(player)[/code] is true. The frame is encoded once.
func broadcast(data, filter: Callable = Callable()) -> void:
	var frame := PackedByteArray()
	for p: PMCPlayer in _players.values():
		if p._conn == null:
			continue
		var c: PMCConnection = p._conn
		if c.close_sent or not c.is_open():
			continue
		if filter.is_valid() and not filter.call(p):
			continue
		if frame.is_empty():
			frame = _encode_msg(data)
		c.queue(frame)
		_msgs_out += 1


## Removes a player: sends [code]pmc.kicked[/code], closes with 4001 and emits [signal player_left] with "kicked".
## No tombstone is kept by default: a kicked token that reconnects becomes a new player (new id, empty meta).
## With [param remember], a tombstone is left (subject to [member remember_seconds]) so the same token rejoins
## with its id and meta intact. With [param ban], the token is refused ([code]banned[/code]) until the host
## stops or [method clear_bans] runs.
func kick(to, reason := "", ban := false, remember := false) -> void:
	var p := _resolve(to)
	if p == null:
		return
	if ban:
		_banned[p.token] = true
	var c: PMCConnection = p._conn
	if c != null:
		_detach(c)
		_send_json(c, {"t": "pmc.kicked", "reason": reason})
		_ws_close(c, 4001, "kicked")
	_remove_player(p, "kicked", remember)


## Forgets all bans made with [method kick].
func clear_bans() -> void:
	_banned.clear()


func _resolve(to) -> PMCPlayer:
	if to is PMCPlayer:
		return to if _players.get(to.id) == to else null
	if typeof(to) == TYPE_INT or typeof(to) == TYPE_FLOAT:
		return _players.get(int(to))
	return null


# --------------------------------------------------------------------------------------------------
# HTTP routing

## Registers [param handler] for request paths starting with [param prefix] (longest prefix wins).
## [code]handler(req: PMCHttpRequest) -> PMCHttpResponse[/code]. Return [code]null[/code] to fall through to static files.
## Handlers see any method. [code]req.sub_path()[/code] is the path after the prefix. Paths under [code]/pmc/[/code] are reserved.
func add_route(prefix: String, handler: Callable) -> void:
	_routes = _routes.filter(func(r: Dictionary) -> bool: return r.prefix != prefix)
	_routes.append({"prefix": prefix, "handler": handler})
	_routes.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.prefix.length() > y.prefix.length())


## Removes a route added with [method add_route].
func remove_route(prefix: String) -> void:
	_routes = _routes.filter(func(r: Dictionary) -> bool: return r.prefix != prefix)


## Serves files from [param dir] (absolute, res:// or user://) under URL [param prefix], e.g.
## [code]serve_directory("/assets/", "user://assets")[/code]. Paths are traversal-safe. Longest prefix wins.
func serve_directory(prefix: String, dir: String) -> void:
	var pre := prefix if prefix.begins_with("/") else "/" + prefix
	if not pre.ends_with("/"):
		pre += "/"
	_mounts = _mounts.filter(func(m: Dictionary) -> bool: return m.prefix != pre)
	_mounts.append({"prefix": pre, "dir": dir})
	_mounts.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.prefix.length() > y.prefix.length())


## The [code]/pmc/info.json[/code] payload.
func info() -> Dictionary:
	return {
		"name": "godot-phone-mass-controllers",
		"version": VERSION,
		"sdk": SDK_VERSION,
		"join_url": join_url(),
		"code_required": join_code != "",
		"players": _players.size(),
		"max_players": max_players,
		"admin": admin_pin != "",
	}


func _route(req: PMCHttpRequest) -> PMCHttpResponse:
	var path := req.path
	if path.begins_with("/pmc/"):
		match path:
			"/pmc/healthz":
				return PMCHttpResponse.text("ok\n").set_header("Cache-Control", "no-cache")
			"/pmc/info.json":
				return PMCHttpResponse.json(info())
			"/pmc/qr.png":
				return _qr_response(req)
		return PMCStaticFiles.serve(WEB_DIR, path.substr(5), req, "")
	for r in _routes:
		if path.begins_with(r.prefix):
			req.route_prefix = r.prefix
			var out = r.handler.call(req)
			if out is PMCHttpResponse:
				return out
			if out != null:
				return PMCHttpResponse.error(500, "route handler returned %s" % type_string(typeof(out)))
	for m in _mounts:
		if path.begins_with(m.prefix):
			var resp := PMCStaticFiles.serve(m.dir, path.substr(m.prefix.length()), req)
			if resp != null:
				return resp
	if controller_dir != "":
		return PMCStaticFiles.serve(controller_dir, path, req)
	return null


func _qr_response(req: PMCHttpRequest) -> PMCHttpResponse:
	var px := clampi(String(req.query.get("px", "8")).to_int(), 1, 32)
	var quiet := clampi(String(req.query.get("quiet", "4")).to_int(), 0, 16)
	if _global_class("PMCQr") == null:
		return PMCHttpResponse.error(501, "QR encoder not available")
	var img := qr_image(px, quiet)
	if img == null:
		return PMCHttpResponse.error(500, "QR encoding failed")
	return PMCHttpResponse.bytes(img.save_png_to_buffer(), "image/png").set_header("Cache-Control", "no-cache")


# --------------------------------------------------------------------------------------------------
# Polling

## Accepts connections, does socket I/O within [member io_budget_msec], and runs timers. Called automatically when
## [member auto_poll] is on.
func poll() -> void:
	if not _running:
		return
	var t0 := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()

	var accepted := 0
	while _server != null and _server.is_connection_available() and accepted < 64:
		var peer := _server.take_connection()
		if peer == null:
			break
		accepted += 1
		if _conns.size() >= max_connections:
			peer.disconnect_from_host()
			_stats["refused"] += 1
			continue
		var conn := PMCConnection.new(peer, now)
		conn.slot = _stats["accepted"]
		# Behind the tunnel every peer is loopback; those are counted per CF-Connecting-IP on their first request.
		if not _behind_tunnel(conn):
			if not _count_address(conn, conn.remote_address):
				conn.close_now("too many connections from address")
				_stats["refused"] += 1
				continue
		_conns.append(conn)
		_stats["accepted"] += 1

	_frame += 1
	var n := _conns.size()
	if n > 0:
		# _conns is only ever replaced (never mutated in place) while iterating, so no copy is needed.
		var conns := _conns
		var deadline := t0 + int(io_budget_msec * 1000.0)
		var start := _rr % n
		var i := 0
		while i < n and _running:
			_service(conns[(start + i) % n], now)
			i += 1
			if (i & 7) == 0 and Time.get_ticks_usec() > deadline:
				break
		_rr = (start + i) % n

	if _running and now - _last_timer_msec >= _TIMER_MSEC:
		_last_timer_msec = now
		_timers(now)
		_closed_pending = true
	if _running and _closed_pending:
		_closed_pending = false
		_reap()

	var dt := Time.get_ticks_usec() - t0
	_stats["last_poll_usec"] = dt
	if dt > _stats["max_poll_usec"]:
		_stats["max_poll_usec"] = dt


func _service(c: PMCConnection, now: int) -> void:
	# Hot path: runs for every connection every frame, so it avoids needless calls and syscalls.
	if c.mode == PMCConnection.Mode.CLOSED:
		_closed_pending = true
		return
	if c._out_off < c._out.size() or c._file != null:
		_bytes_out += c.flush(_WRITE_CAP)
	# The status check is a select() call, so it's staggered to every few frames per connection.
	if (_frame + c.slot) % _STATUS_EVERY_FRAMES == 0 or c.mode == PMCConnection.Mode.CLOSED:
		if not c.poll_status():
			_closed_pending = true
			return
	var avail := c.peer.get_available_bytes()
	if avail < 0:
		if not c.poll_status():
			_closed_pending = true
			return
		avail = 0
	if c.mode == PMCConnection.Mode.HTTP:
		if avail > 0 and not c.close_after_flush and c._in.size() - c._in_off < max_header_bytes + max_body_bytes + 8:
			_bytes_in += c.read(_READ_CAP, now)
		if c._in.size() > c._in_off:
			_process_http(c, now)
	else:
		var got := 0
		if avail > 0 and c.ws.buffered() < max_message_bytes + 16:
			got = c.read(_READ_CAP, now)
			_bytes_in += got
		if got > 0 or c.ws_more:
			_process_ws(c, now)
	if c.mode == PMCConnection.Mode.CLOSED:
		_closed_pending = true
	elif c._out_off < c._out.size() or c._file != null:
		_bytes_out += c.flush(_WRITE_CAP)


func _process_http(c: PMCConnection, now: int) -> void:
	var handled := 0
	while c.is_open() and c.mode == PMCConnection.Mode.HTTP and not c.close_after_flush and not c.is_streaming() \
			and c.out_pending() < _WRITE_CAP and handled < 16:
		var r := c.next_http_request(max_header_bytes, max_body_bytes)
		if r.is_empty():
			break
		handled += 1
		if r.has("error"):
			_respond(c, null, PMCHttpResponse.error(r.error, r.reason), false)
			break
		_stats["http_requests"] += 1
		var req: PMCHttpRequest = r.request
		c.head_started_msec = now
		if c.counted_address == "" and _behind_tunnel(c):
			var addr := _forwarded_address(c, req)
			if not _count_address(c, addr):
				_respond(c, req, PMCHttpResponse.error(429, "too many connections from your address"), false)
				break
		req.remote_address = c.client_address
		if req.path == "/pmc/ws":
			_upgrade(c, req, now)
			break
		var resp := _route(req)
		if resp == null:
			if req.method == "GET" or req.method == "HEAD":
				resp = PMCHttpResponse.error(404)
			else:
				resp = PMCHttpResponse.error(405).set_header("Allow", "GET, HEAD")
		_respond(c, req, resp, req.wants_keep_alive())


func _respond(c: PMCConnection, req: PMCHttpRequest, resp: PMCHttpResponse, keep_alive: bool) -> void:
	var head_only := req != null and req.method == "HEAD"
	if resp.file_path != "":
		var f := FileAccess.open(resp.file_path, FileAccess.READ)
		if f == null:
			resp = PMCHttpResponse.error(500, "cannot open file")
		else:
			var size := f.get_length()
			var offset := clampi(resp.file_offset, 0, size)
			var length := size - offset if resp.file_length < 0 else mini(resp.file_length, size - offset)
			c.queue(resp.build_head(length, keep_alive))
			if head_only or length <= 0:
				f.close()
			else:
				f.seek(offset)
				c.start_file(f, length)
			if not keep_alive:
				c.close_after_flush = true
			return
	c.queue(resp.build_head(resp.body.size(), keep_alive))
	if not head_only:
		c.queue(resp.body)
	if not keep_alive:
		c.close_after_flush = true


func _upgrade(c: PMCConnection, req: PMCHttpRequest, now: int) -> void:
	if req.method != "GET":
		_respond(c, req, PMCHttpResponse.error(405).set_header("Allow", "GET"), false)
		return
	if not req.header_has_token("upgrade", "websocket") or not req.header_has_token("connection", "upgrade"):
		_respond(c, req, PMCHttpResponse.error(426, "WebSocket upgrade required").set_header("Upgrade", "websocket"), false)
		return
	if req.header("sec-websocket-version").strip_edges() != "13":
		_respond(c, req, PMCHttpResponse.error(426, "unsupported WebSocket version").set_header("Sec-WebSocket-Version", "13"), false)
		return
	var key := req.header("sec-websocket-key").strip_edges()
	if key.length() != 24 or not key.ends_with("==") or Marshalls.base64_to_raw(key).size() != 16:
		_respond(c, req, PMCHttpResponse.error(400, "bad Sec-WebSocket-Key"), false)
		return
	var resp := PMCHttpResponse.new()
	resp.status = 101
	resp.headers["Upgrade"] = "websocket"
	resp.headers["Connection"] = "Upgrade"
	resp.headers["Sec-WebSocket-Accept"] = PMCWsFrame.accept_key(key)
	c.queue(resp.build_head(0, true))
	c.upgrade_to_ws(max_message_bytes, now, int(hello_timeout_seconds * 1000.0), _heartbeat_msec())


func _heartbeat_msec() -> int:
	return int(heartbeat_seconds * 1000.0) if heartbeat_seconds > 0.0 else 1 << 62


func _process_ws(c: PMCConnection, now: int) -> void:
	var count := 0
	c.ws_more = false
	while c.is_open():
		if count >= 256:
			c.ws_more = true  # continue next frame
			break
		var ev := c.ws.next()
		if ev.is_empty():
			break
		count += 1
		c.pings_unanswered = 0
		match ev.op:
			"text":
				if not c.close_sent and not c.rejected:
					_msgs_in += 1
					_on_ws_text(c, ev.data, now)
			"binary":
				if not c.close_sent and not c.rejected:
					_msgs_in += 1
					_on_ws_binary(c, ev.data, now)
			"ping":
				if not c.close_sent:
					c.queue(PMCWsFrame.pong(ev.data))
			"pong":
				if c.ping_sent_msec > 0:
					var pp: PMCPlayer = _players.get(c.player_id)
					if pp != null:
						var sample := float(now - c.ping_sent_msec)
						pp.rtt_ms = sample if pp.rtt_ms <= 0.0 else pp.rtt_ms * 0.75 + sample * 0.25
					c.ping_sent_msec = 0
			"close":
				_on_peer_socket_closing(c)
				if not c.close_sent:
					c.queue(PMCWsFrame.close(ev.code if ev.code != 1005 else 0))
					c.close_sent = true
				c.close_after_flush = true
				if not c.has_pending_output():
					c.close_now("closed by peer")
			"error":
				# Protocol failure: send the close frame and keep draining input until the peer closes or the
				# handshake timeout passes. Closing with unread input would send a TCP RST, which can destroy
				# the close frame before the peer reads it.
				_on_peer_socket_closing(c)
				_ws_close(c, ev.code, ev.reason)
		if not _running:
			return


# Detaches the player when the socket is going away, so grace starts immediately.
func _on_peer_socket_closing(c: PMCConnection) -> void:
	if c.player_id != 0:
		var p: PMCPlayer = _players.get(c.player_id)
		_detach(c)
		if p != null:
			_player_socket_lost(p)


func _ws_close(c: PMCConnection, code: int, reason := "") -> void:
	if not c.is_open() or c.mode != PMCConnection.Mode.WS:
		return
	if not c.close_sent:
		c.queue(PMCWsFrame.close(code, reason))
		c.close_sent = true
		c.close_deadline_msec = Time.get_ticks_msec() + _CLOSE_HANDSHAKE_MSEC
		c.flush(65536)


func _send_json(c: PMCConnection, obj: Dictionary) -> void:
	if c.is_open() and not c.close_sent:
		c.queue(PMCWsFrame.text(JSON.stringify(obj, "", false)))


func _encode_msg(data) -> PackedByteArray:
	if data is PackedByteArray:
		return PMCWsFrame.binary(data)
	return PMCWsFrame.text(JSON.stringify({"t": "msg", "d": data}, "", false))


func _timers(now: int) -> void:
	var header_ms := int(header_timeout_seconds * 1000.0)
	for c in _conns:
		if not c.is_open():
			continue
		if c.has_pending_output() and now - c.last_tx_msec > _STALL_MSEC:
			c.close_now("write stalled")
			_on_peer_socket_closing(c)
			continue
		if c.mode == PMCConnection.Mode.HTTP:
			if c.has_pending_output():
				c.head_started_msec = now
			elif now - c.head_started_msec > header_ms:
				if c.buffered_in() > 0 or c.awaiting_body():
					_respond(c, null, PMCHttpResponse.error(408), false)
					c.flush(65536)
				c.close_now("header timeout")
		elif c.mode == PMCConnection.Mode.WS:
			if c.close_sent:
				if now >= c.close_deadline_msec and c.close_deadline_msec > 0:
					c.close_now("close handshake timeout")
				continue
			if c.out_pending() > max_backlog_bytes:
				c.close_now("backlog")
				_on_peer_socket_closing(c)
				continue
			if c.player_id == 0 and not c.rejected and now >= c.hello_deadline_msec:
				_reject(c, "bad_hello", "no pmc.hello received")
				continue
			if now >= c.next_ping_msec:
				if c.pings_unanswered >= 2:
					c.close_now("heartbeat timeout")
					_on_peer_socket_closing(c)
					continue
				c.queue(PMCWsFrame.ping())
				c.pings_unanswered += 1
				c.ping_sent_msec = now
				c.next_ping_msec = now + _heartbeat_msec()

	if now - _last_sweep_msec >= 100:
		_last_sweep_msec = now
		for p: PMCPlayer in _players.values():
			if not p.connected and p.grace_deadline_msec > 0 and now >= p.grace_deadline_msec:
				_remove_player(p, "timeout")
				if not _running:
					return
		for token in _tombstones.keys():
			if now >= _tombstones[token].expires_msec:
				_tombstones.erase(token)
		for key in _addr_failures.keys():
			var e: Dictionary = _addr_failures[key]
			if now >= e.window_end_msec and now >= e.blocked_until_msec:
				_addr_failures.erase(key)


func _reap() -> void:
	var any_closed := false
	for c in _conns:
		if c.mode == PMCConnection.Mode.CLOSED:
			any_closed = true
			break
	if not any_closed:
		return
	var keep: Array[PMCConnection] = []
	var closed: Array[PMCConnection] = []
	for c in _conns:
		if c.is_open():
			keep.append(c)
		else:
			closed.append(c)
	_conns = keep
	for c in closed:
		_uncount_address(c)
		_on_peer_socket_closing(c)


# --------------------------------------------------------------------------------------------------
# Per-address limits

# True when the socket comes from the local tunnel process, so the real client is in CF-Connecting-IP.
func _behind_tunnel(c: PMCConnection) -> bool:
	return _tunnel != null and _is_loopback(c.remote_address)


static func _is_loopback(addr: String) -> bool:
	return addr.begins_with("127.") or addr == "::1" or addr == "::ffff:127.0.0.1"


func _forwarded_address(c: PMCConnection, req: PMCHttpRequest) -> String:
	var h := req.header("cf-connecting-ip").strip_edges()
	if h != "" and h.is_valid_ip_address():
		return h
	return c.remote_address


func _count_address(c: PMCConnection, addr: String) -> bool:
	if max_connections_per_address > 0 and int(_addr_conns.get(addr, 0)) >= max_connections_per_address:
		return false
	_addr_conns[addr] = int(_addr_conns.get(addr, 0)) + 1
	c.counted_address = addr
	c.client_address = addr
	return true


func _uncount_address(c: PMCConnection) -> void:
	if c.counted_address == "":
		return
	var n := int(_addr_conns.get(c.counted_address, 0)) - 1
	if n <= 0:
		_addr_conns.erase(c.counted_address)
	else:
		_addr_conns[c.counted_address] = n
	c.counted_address = ""


# Milliseconds [param addr] is still blocked for [param kind], or 0.
func _blocked_ms(kind: String, addr: String, now: int) -> int:
	var e: Dictionary = _addr_failures.get(kind + "|" + addr, {})
	return maxi(0, int(e.get("blocked_until_msec", 0)) - now)


# Records a failure. Returns true if this failure triggered a block.
func _record_failure(kind: String, addr: String, now: int, max_failures: int, block_msec: int) -> bool:
	if max_failures <= 0:
		return false
	var key := kind + "|" + addr
	var e: Dictionary = _addr_failures.get(key, {})
	if e.is_empty() or now >= int(e.window_end_msec):
		e = {"count": 0, "window_end_msec": now + block_msec, "blocked_until_msec": int(e.get("blocked_until_msec", 0))}
	e.count = int(e.count) + 1
	var blocked := false
	if e.count >= max_failures:
		e.blocked_until_msec = now + block_msec
		e.count = 0
		e.window_end_msec = now + block_msec
		blocked = true
	_addr_failures[key] = e
	return blocked


# --------------------------------------------------------------------------------------------------
# Protocol

func _on_ws_binary(c: PMCConnection, data: PackedByteArray, now: int) -> void:
	if c.player_id == 0:
		_reject(c, "bad_hello", "first frame must be pmc.hello")
		return
	var p: PMCPlayer = _players.get(c.player_id)
	if p == null:
		return
	p.last_seen_msec = now
	message_received.emit(p, data)


func _on_ws_text(c: PMCConnection, text: String, now: int) -> void:
	var m = null
	if _json.parse(text) == OK:
		m = _json.data
	if typeof(m) != TYPE_DICTIONARY or typeof(m.get("t")) != TYPE_STRING:
		if c.player_id == 0:
			_reject(c, "bad_hello", "first frame must be pmc.hello")
		return
	var t: String = m["t"]
	if c.player_id == 0:
		if t != "pmc.hello":
			_reject(c, "bad_hello", "first frame must be pmc.hello")
			return
		_on_hello(c, m, now)
		return
	var p: PMCPlayer = _players.get(c.player_id)
	if p == null:
		return
	p.last_seen_msec = now
	match t:
		"msg":
			message_received.emit(p, m.get("d"))
		"pmc.ping":
			_send_json(c, {"t": "pmc.pong", "c": m.get("c"), "s": _epoch_ms()})
		"pmc.profile":
			if _apply_identity(p, m):
				player_updated.emit(p)
		"pmc.auth":
			_on_auth(c, p, m, now)
		"pmc.leave":
			_detach(c)
			_ws_close(c, 1000, "leave")
			_remove_player(p, "leave")


func _on_hello(c: PMCConnection, m: Dictionary, now: int) -> void:
	var sdk = m.get("sdk")
	if typeof(sdk) != TYPE_INT and typeof(sdk) != TYPE_FLOAT:
		_reject(c, "bad_hello", "missing sdk version")
		return
	if int(sdk) != SDK_VERSION:
		_reject(c, "version", "host speaks sdk %d" % SDK_VERSION)
		return
	var token := ""
	if typeof(m.get("token")) == TYPE_STRING:
		token = m["token"]
	if token != "" and _banned.has(token):
		_reject(c, "banned", "you were removed from this game")
		return

	var existing: PMCPlayer = _by_token.get(token) if token != "" else null
	if existing != null:
		if existing._conn != null and existing._conn != c:
			var old: PMCConnection = existing._conn
			_detach(old)
			_send_json(old, {"t": "pmc.replaced"})
			_ws_close(old, 4002, "replaced")
		_attach(c, existing, now)
		var changed := _apply_identity(existing, m)
		_welcome(c, existing, true)
		player_rejoined.emit(existing)
		if changed and existing._conn == c:
			player_updated.emit(existing)
		return

	var tomb: Dictionary = _tombstones.get(token, {}) if token != "" else {}
	if join_code != "" and tomb.is_empty():
		var wait_ms := _blocked_ms("code", c.client_address, now)
		if wait_ms > 0:
			_reject(c, "bad_code", "too many wrong join codes; try again in %d s" % ceili(wait_ms / 1000.0))
			return
		var code = m.get("code")
		var given := String(code).strip_edges() if typeof(code) == TYPE_STRING else ""
		if given.to_upper() != join_code.strip_edges().to_upper():
			# Only non-empty wrong guesses count toward the per-address block (a missing code isn't a guess).
			if given != "":
				_record_failure("code", c.client_address, now, join_code_max_failures, int(join_code_block_seconds * 1000.0))
			_reject(c, "bad_code", "wrong or missing join code")
			return
	if max_players > 0 and _players.size() >= max_players:
		_reject(c, "full", "the game is full")
		return

	var p := PMCPlayer.new()
	var rejoined := false
	if not tomb.is_empty():
		_tombstones.erase(token)
		p.id = tomb.id
		p.token = token
		p.name = tomb.name
		p.profile = tomb.profile
		p.meta = tomb.meta
		rejoined = true
	else:
		p.id = _next_id
		_next_id += 1
		p.token = _crypto.generate_random_bytes(16).hex_encode()
	_apply_identity(p, m)
	if p.name == "":
		p.name = "Player %d" % p.id
	p.joined_msec = now
	_players[p.id] = p
	_by_token[p.token] = p
	_attach(c, p, now)
	_welcome(c, p, rejoined)
	player_joined.emit(p)


func _attach(c: PMCConnection, p: PMCPlayer, now: int) -> void:
	c.player_id = p.id
	p._conn = c
	p.connected = true
	p.grace_deadline_msec = 0
	p.last_seen_msec = now
	p.remote_address = c.client_address


func _detach(c: PMCConnection) -> void:
	if c.player_id == 0:
		return
	var p: PMCPlayer = _players.get(c.player_id)
	c.player_id = 0
	if p != null and p._conn == c:
		p._conn = null


func _player_socket_lost(p: PMCPlayer) -> void:
	if not _players.has(p.id) or p._conn != null or not p.connected:
		return
	var now := Time.get_ticks_msec()
	p.connected = false
	p.last_seen_msec = now
	p.grace_deadline_msec = now + maxi(1, int(grace_seconds * 1000.0))
	player_disconnected.emit(p)
	if grace_seconds <= 0.0 and _players.get(p.id) == p and not p.connected:
		_remove_player(p, "timeout")


func _remove_player(p: PMCPlayer, reason: String, tombstone := false) -> void:
	if _players.get(p.id) != p:
		return
	_players.erase(p.id)
	_by_token.erase(p.token)
	if p._conn != null:
		var c: PMCConnection = p._conn
		_detach(c)
		_ws_close(c, 1000, reason)
	p.connected = false
	p.grace_deadline_msec = 0
	if (reason == "timeout" or tombstone) and remember_seconds > 0.0:
		_tombstones[p.token] = {
			"id": p.id, "name": p.name, "profile": p.profile, "meta": p.meta,
			"expires_msec": Time.get_ticks_msec() + int(remember_seconds * 1000.0),
		}
	player_left.emit(p, reason)


func _apply_identity(p: PMCPlayer, m: Dictionary) -> bool:
	var changed := false
	if typeof(m.get("name")) == TYPE_STRING:
		var nm := _clean_name(m["name"])
		if nm != "" and nm != p.name:
			p.name = nm
			changed = true
	if typeof(m.get("profile")) == TYPE_DICTIONARY and m["profile"] != p.profile:
		p.profile = m["profile"]
		changed = true
	return changed


static func _clean_name(s: String) -> String:
	var out := ""
	for ch in s.strip_edges():
		var u := ch.unicode_at(0)
		if u >= 32 and u != 127:
			out += ch
	return out.strip_edges().left(MAX_NAME_LENGTH)


func _welcome(c: PMCConnection, p: PMCPlayer, rejoined: bool) -> void:
	_send_json(c, {
		"t": "pmc.welcome", "id": p.id, "token": p.token, "name": p.name, "profile": p.profile,
		"rejoined": rejoined, "admin": p.is_admin, "server_ms": _epoch_ms(), "join_url": join_url(),
	})


static func _epoch_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func _reject(c: PMCConnection, code: String, reason: String) -> void:
	c.rejected = true
	_send_json(c, {"t": "pmc.reject", "code": code, "reason": reason})
	_ws_close(c, 4000, code)


func _on_auth(c: PMCConnection, p: PMCPlayer, m: Dictionary, now: int) -> void:
	# Per connection: 5 failures -> 30 s. Per address (so reconnecting doesn't reset it): 20 failures -> 60 s.
	var locked := maxi(c.auth_locked_until_msec - now, _blocked_ms("auth", c.client_address, now))
	if locked > 0:
		_send_json(c, {"t": "pmc.auth", "ok": false, "locked_ms": locked})
		return
	var pin = m.get("pin")
	var ok := admin_pin != "" and typeof(pin) == TYPE_STRING and _secure_equals(String(pin), admin_pin)
	if ok:
		c.auth_failures = 0
		_send_json(c, {"t": "pmc.auth", "ok": true})
		if not p.is_admin:
			p.is_admin = true
			admin_authenticated.emit(p)
		return
	c.auth_failures += 1
	if c.auth_failures >= _AUTH_MAX_FAILURES:
		c.auth_failures = 0
		c.auth_locked_until_msec = now + _AUTH_LOCK_MSEC
	_record_failure("auth", c.client_address, now, _AUTH_ADDR_MAX_FAILURES, _AUTH_ADDR_LOCK_MSEC)
	_send_json(c, {"t": "pmc.auth", "ok": false})


static func _secure_equals(a: String, b: String) -> bool:
	var x := a.sha256_buffer()
	var y := b.sha256_buffer()
	var diff := 0
	for i in x.size():
		diff |= x[i] ^ y[i]
	return diff == 0


# --------------------------------------------------------------------------------------------------
# Tunnel

## Starts a Cloudflare Quick Tunnel to this host (starting the host first if needed). Progress is reported via
## [signal tunnel_state_changed]. When it's ready, [member advertise_url] becomes the tunnel URL and a 4-letter
## [member join_code] is generated if none is set.
func start_tunnel() -> void:
	if _tunnel != null:
		return
	if not _running:
		var err := start()
		if err != OK:
			tunnel_state_changed.emit("failed", "host failed to start: %s" % error_string(err))
			return
	var cls = _global_class("PMCTunnel")
	if cls == null:
		tunnel_state_changed.emit("failed", "PMCTunnel class not found")
		return
	var t: Object = cls.new()
	if "allow_download" in t:
		t.allow_download = tunnel_allow_download
	if cloudflared_path != "" and "cloudflared_path" in t:
		t.cloudflared_path = cloudflared_path
	_tunnel = t
	if t is Node:
		t.name = "PMCTunnel"
		add_child(t)
	t.state_changed.connect(_on_tunnel_state)
	t.start(_port)


## Stops the tunnel and restores the previous join URL (and clears an auto-generated join code).
func stop_tunnel() -> void:
	if _tunnel != null:
		_stop_tunnel_internal(true)


## The active tunnel object ([code]PMCTunnel[/code]), or [code]null[/code].
func get_tunnel() -> Object:
	return _tunnel


func _stop_tunnel_internal(emit: bool) -> void:
	var t := _tunnel
	_tunnel = null
	if t.state_changed.is_connected(_on_tunnel_state):
		t.state_changed.disconnect(_on_tunnel_state)
	t.stop()
	if t is Node:
		t.queue_free()
	_restore_after_tunnel(emit)
	if emit:
		tunnel_state_changed.emit("stopped", "")


func _on_tunnel_state(state: String, detail: String) -> void:
	match state:
		"ready":
			var url: String = _tunnel.url if _tunnel != null and "url" in _tunnel else detail
			_suppress_url_signal = true
			if not _tunnel_set_advertise:
				_tunnel_prev_advertise = advertise_url
				_tunnel_set_advertise = true
			advertise_url = url
			if join_code == "":
				join_code = _generate_code()
				_tunnel_generated_code = true
			_suppress_url_signal = false
			tunnel_state_changed.emit("ready", url)
			if _running:
				join_url_changed.emit(join_url())
		"failed", "stopped":
			if _tunnel != null:
				var t := _tunnel
				_tunnel = null
				if t.state_changed.is_connected(_on_tunnel_state):
					t.state_changed.disconnect(_on_tunnel_state)
				if t is Node:
					t.queue_free.call_deferred()
			_restore_after_tunnel(true)
			tunnel_state_changed.emit(state, detail)
		_:
			tunnel_state_changed.emit(state, detail)


func _restore_after_tunnel(emit: bool) -> void:
	var changed := false
	_suppress_url_signal = true
	if _tunnel_set_advertise:
		advertise_url = _tunnel_prev_advertise
		_tunnel_set_advertise = false
		changed = true
	if _tunnel_generated_code:
		join_code = ""
		_tunnel_generated_code = false
		changed = true
	_suppress_url_signal = false
	if changed and emit and _running:
		join_url_changed.emit(join_url())


func _generate_code() -> String:
	var bytes := _crypto.generate_random_bytes(4)
	var s := ""
	for b in bytes:
		s += _CODE_ALPHABET[b % _CODE_ALPHABET.length()]
	return s


func _url_changed() -> void:
	if _running and not _suppress_url_signal:
		join_url_changed.emit(join_url())


# Resolves a global class_name lazily, so optional parts (QR, tunnel) may be absent.
func _global_class(name: String):
	if _class_cache.has(name):
		return _class_cache[name]
	var script = null
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == name:
			script = load(c["path"])
			break
	if script != null:
		_class_cache[name] = script
	return script
