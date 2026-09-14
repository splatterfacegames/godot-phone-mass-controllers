extends Node
## Game-side half of the dock's running-game status. PMCHost adds one of these as a child only
## when the game runs from the editor (see the OS.has_feature("editor") block in PMCHost._ready).
## It pushes "pmc:status" dictionaries over EngineDebugger on host changes and answers the dock's
## "pmc:status" polls. Never instantiated in exported games.

## Heartbeat so the dock stays fresh between signal-driven pushes.
const HEARTBEAT_MSEC := 2000
## Name cap for the player list sent to the dock.
const MAX_NAMES := 24

var _host: PMCHost
var _dirty := true
var _last_send_msec := -HEARTBEAT_MSEC
var _capturing := false


func _init(host: PMCHost) -> void:
	_host = host
	name = "PMCStatusReporter"


func _ready() -> void:
	if EngineDebugger.is_active():
		_bind()


func _exit_tree() -> void:
	if _capturing:
		EngineDebugger.unregister_message_capture("pmc")


func _process(_delta: float) -> void:
	if not _capturing:
		if EngineDebugger.is_active():
			_bind()  # the debugger can attach after scene start
		else:
			return
	var now := Time.get_ticks_msec()
	if _dirty or now - _last_send_msec >= HEARTBEAT_MSEC:
		_send()


func _bind() -> void:
	EngineDebugger.register_message_capture("pmc", _capture)
	_capturing = true
	for sig in ["started", "stopped", "player_joined", "player_rejoined", "player_disconnected",
			"player_left", "player_updated", "join_url_changed", "tunnel_state_changed"]:
		_host.connect(sig, _notify)


# Editor -> game. The capture name is stripped: "pmc:status" arrives as "status".
func _capture(message: String, _data: Array) -> bool:
	if message == "status":
		_send()
		return true
	return false


func _notify(_a = null, _b = null) -> void:
	_dirty = true


func _send() -> void:
	_dirty = false
	_last_send_msec = Time.get_ticks_msec()
	if EngineDebugger.is_active():
		EngineDebugger.send_message("pmc:status", [status()])


## The payload the dock renders. Kept host-API-only so tests can build it without a debugger.
func status() -> Dictionary:
	var connected := 0
	var names: Array[String] = []
	for p in _host.players():
		if p.connected:
			connected += 1
		if names.size() < MAX_NAMES:
			names.append(p.name)
	var tunnel_state := ""
	var tunnel_url := ""
	var t := _host.get_tunnel()
	if t != null:
		if "state" in t:
			tunnel_state = String(t.state)
		if "url" in t:
			tunnel_url = String(t.url)
	return {
		"version": PMCHost.VERSION,
		"running": _host.is_running(),
		"port": _host.get_port(),
		"join_url": _host.join_url() if _host.is_running() else "",
		"code": _host.join_code,
		"players": connected,
		"players_total": _host.players().size(),
		"player_names": names,
		"tunnel_state": tunnel_state,
		"tunnel_url": tunnel_url,
		"msec": Time.get_ticks_msec(),
	}
