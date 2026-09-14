@tool
extends EditorDebuggerPlugin
## Editor half of the running-game status channel. The game's PMCHost adds ingame_reporter.gd
## when running from the editor; it pushes "pmc:status" payloads over EngineDebugger and answers
## "pmc:status" requests sent here. Forwarded to the dock via the static [member dock] link, since
## the dock can't reach this instance (it's registered with add_debugger_plugin from plugin.gd).

## Set/cleared by dock.gd while it lives in the editor UI.
static var dock: Control = null
## session_id -> most recent status dictionary (also used by tests).
static var last_status: Dictionary = {}


func _has_capture(capture: String) -> bool:
	return capture == "pmc"


func _capture(message: String, data: Array, session_id: int) -> bool:
	return handle_message(message, data, session_id)


func _setup_session(session_id: int) -> void:
	var s := get_session(session_id)
	if s == null:
		return
	if s.has_signal("started"):
		s.started.connect(request_status.bind(session_id))
	if s.has_signal("stopped"):
		s.stopped.connect(_on_session_stopped.bind(session_id))
	request_status(session_id)


## Asks the game (via its "pmc" message capture) to send a fresh status payload.
func request_status(session_id: int) -> void:
	var s := get_session(session_id)
	if s != null and s.is_active():
		s.send_message("pmc:status", [])


func _on_session_stopped(session_id: int) -> void:
	last_status.erase(session_id)
	if dock != null:
		dock.clear_game_status(session_id)


## Message routing, static so tests can drive it without an export/debug session.
static func handle_message(message: String, data: Array, session_id: int) -> bool:
	if message != "pmc:status" or data.is_empty() or not data[0] is Dictionary:
		return false
	last_status[session_id] = data[0]
	if dock != null:
		dock.apply_game_status(session_id, data[0])
	return true
