extends RefCounted
## Issue #22: the running-game status channel — the in-game reporter's payload, the debugger
## plugin's message routing, and the dock's rendering. The wire itself (EngineDebugger /
## EditorDebuggerSession) needs a real editor+game pair, so it's covered by construction:
## reporter sends "pmc:status", the plugin captures "pmc:*" and calls the same static
## handle_message() exercised here.

const DockScript := preload("res://addons/phone_mass_controllers/editor/dock.gd")
const DebuggerScript := preload("res://addons/phone_mass_controllers/editor/debugger_plugin.gd")
const ReporterScript := preload("res://addons/phone_mass_controllers/editor/ingame_reporter.gd")

const PAYLOAD := {
	"running": true, "port": 8080, "join_url": "http://10.0.0.5:8080/?code=ABCD", "code": "ABCD",
	"players": 2, "players_total": 3, "player_names": ["A", "B"],
	"tunnel_state": "ready", "tunnel_url": "https://x.trycloudflare.com", "msec": 1,
}


func run(t) -> void:
	t.section("reporter payload")
	var host := PMCHost.new()
	host.port = 0
	host.controller_dir = ""
	host.join_code = "TEST"
	t.add_node(host)
	var reporter: Node = ReporterScript.new(host)
	t.add_node(reporter)
	var d: Dictionary = reporter.status()
	t.eq(d.running, false, "not running yet")
	t.eq(d.join_url, "", "no join url while stopped")
	t.eq(host.start(), OK, "host starts")
	d = reporter.status()
	t.eq(d.running, true)
	t.eq(d.port, host.get_port())
	t.ok(String(d.join_url).contains(str(host.get_port())), "join_url carries port")
	t.eq(d.code, "TEST")
	t.eq(d.players, 0)
	t.eq(d.player_names, [])
	t.eq(d.tunnel_state, "")
	t.eq(d.version, PMCHost.VERSION)

	var ws := PMCTestWs.new(t)
	t.ok(await ws.open(host.get_port()), "ws open")
	await ws.hello({"name": "Docky", "code": "TEST"})
	var w := await ws.wait_json("pmc.welcome")
	t.ok(not w.is_empty(), "player welcomed")
	d = reporter.status()
	t.eq(d.players, 1)
	t.eq(d.players_total, 1)
	t.eq(d.player_names, ["Docky"])
	ws.close()

	t.section("debugger routing")
	var dock: Control = DockScript.new()
	t.add_node(dock)
	await t.frame()
	t.eq(DebuggerScript.dock, dock, "dock registered itself on the script")
	t.ok(DebuggerScript.handle_message("pmc:status", [PAYLOAD], 7), "status message handled")
	t.eq(dock.game_url_edit.text, "http://10.0.0.5:8080/?code=ABCD")
	t.ok(dock.game_status.text.contains("8080"), "port shown")
	t.ok(dock.game_status.text.contains("2 players"), "player count shown")
	t.ok(dock.game_status.text.contains("1 reconnecting"), "grace-period players counted")
	t.ok(dock.game_status.text.contains("tunnel: ready"), "tunnel state shown")
	t.eq(dock.game_players.text, "A, B")
	t.ok(dock.game_qr.texture != null, "join QR shown")
	t.ok(not dock.game_copy_button.disabled and not dock.game_open_button.disabled, "copy/open enabled")
	t.eq(DebuggerScript.last_status.get(7, {}).get("port"), 8080, "last_status recorded")
	t.ok(not DebuggerScript.handle_message("pmc:other", [], 7), "unknown pmc message ignored")
	t.ok(not DebuggerScript.handle_message("other:status", [{}], 7), "foreign channel ignored")
	t.ok(not DebuggerScript.handle_message("pmc:status", [], 7), "empty payload ignored")

	t.section("multi-session and stop")
	DebuggerScript.handle_message("pmc:status", [{"running": false, "msec": 0}], 8)
	t.ok(dock.game_status.text.contains("8080"), "newest payload still wins")
	dock.clear_game_status(7)
	t.ok(dock.game_status.text.contains("isn't listening"), "remaining session shows stopped host")
	dock.clear_game_status(8)
	t.eq(dock.game_url_edit.text, "")
	t.eq(dock.game_players.text, "")
	t.ok(dock.game_qr.texture == null, "QR cleared")
	t.ok(dock.game_status.text.contains("Run the game"), "back to idle hint")
