@tool
extends VBoxContainer
## "Phone Controllers" editor panel: download cloudflared, run a throwaway quick tunnel against a local
## test responder (shows the public URL and its QR code), and links to the docs.
## Built entirely in code so it has no scene dependencies; it also works outside the editor for tests.

const REPO_URL := "https://github.com/splatterfacegames/godot-phone-mass-controllers"
const DebuggerScript := preload("res://addons/phone_mass_controllers/editor/debugger_plugin.gd")
const LINKS := [
	["README", REPO_URL + "#readme"],
	["Spec: outside-LAN join", REPO_URL + "/blob/main/SPEC.md#5-outside-lan-join-one-click-cloudflare-quick-tunnel"],
	["Known tunnel caveats", REPO_URL + "/issues?q=is%3Aissue+label%3Atunnel"],
	["Cloudflare Quick Tunnels", "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/"],
]

## The tunnel used by the buttons (exposed for tests).
var tunnel: PMCTunnel
## Local responder the test tunnel points at.
var responder: PMCTunnelTestResponder

var binary_label: Label
var download_button: Button
var download_bar: ProgressBar
var open_folder_button: Button
var test_button: Button
var status_label: Label
var url_edit: LineEdit
var copy_button: Button
var open_url_button: Button
var qr_rect: TextureRect
var game_status: Label
var game_url_edit: LineEdit
var game_copy_button: Button
var game_open_button: Button
var game_players: Label
var game_qr: TextureRect
var mode_option: OptionButton
var named_token_edit: LineEdit
var named_host_edit: LineEdit

var _downloading := false
var _game_sessions: Dictionary = {} # session_id -> last status payload


func _init() -> void:
	name = "PhoneControllers"
	custom_minimum_size = Vector2(0, 220)
	add_theme_constant_override("separation", 6)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 16)
	add_child(columns)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)

	# cloudflared
	left.add_child(_heading("cloudflared (for players outside your network)"))
	binary_label = Label.new()
	binary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(binary_label)
	var dl_row := HBoxContainer.new()
	left.add_child(dl_row)
	download_button = Button.new()
	download_button.text = "Download cloudflared"
	download_button.tooltip_text = "Downloads the official binary for this OS from github.com/cloudflare/cloudflared (latest release) into %s" % PMCTunnel.INSTALL_DIR
	download_button.pressed.connect(_on_download_pressed)
	dl_row.add_child(download_button)
	open_folder_button = Button.new()
	open_folder_button.text = "Show folder"
	open_folder_button.pressed.connect(func() -> void:
		var dir := ProjectSettings.globalize_path(PMCTunnel.INSTALL_DIR)
		DirAccess.make_dir_recursive_absolute(dir)
		OS.shell_show_in_file_manager(dir))
	dl_row.add_child(open_folder_button)
	download_bar = ProgressBar.new()
	download_bar.custom_minimum_size = Vector2(160, 0)
	download_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	download_bar.visible = false
	dl_row.add_child(download_bar)

	# test tunnel
	left.add_child(_heading("Test a tunnel"))
	var test_row := HBoxContainer.new()
	left.add_child(test_row)
	test_button = Button.new()
	test_button.text = "Test tunnel"
	test_button.tooltip_text = "Starts a throwaway Cloudflare Quick Tunnel to a tiny local test page. Anyone with the URL can open that page while it runs."
	test_button.pressed.connect(_on_test_pressed)
	test_row.add_child(test_button)
	mode_option = OptionButton.new()
	mode_option.add_item("Quick (random URL)")
	mode_option.add_item("Named (stable URL)")
	mode_option.tooltip_text = "Named tunnels need a Cloudflare account: create one in the dashboard, copy its 'run with token' token and the public hostname you routed to it."
	mode_option.item_selected.connect(func(_i: int) -> void:
		named_token_edit.visible = mode_option.selected == 1
		named_host_edit.visible = mode_option.selected == 1)
	test_row.add_child(mode_option)
	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.text = "Idle."
	test_row.add_child(status_label)
	var url_row := HBoxContainer.new()
	left.add_child(url_row)
	url_edit = LineEdit.new()
	url_edit.editable = false
	url_edit.placeholder_text = "https://<random>.trycloudflare.com"
	url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_row.add_child(url_edit)
	copy_button = Button.new()
	copy_button.text = "Copy"
	copy_button.disabled = true
	copy_button.pressed.connect(func() -> void: DisplayServer.clipboard_set(url_edit.text))
	url_row.add_child(copy_button)
	open_url_button = Button.new()
	open_url_button.text = "Open"
	open_url_button.disabled = true
	open_url_button.pressed.connect(func() -> void: OS.shell_open(url_edit.text))
	url_row.add_child(open_url_button)
	named_token_edit = LineEdit.new()
	named_token_edit.placeholder_text = "Tunnel token (Cloudflare dashboard -> 'run with token')"
	named_token_edit.secret = true
	named_token_edit.visible = false
	named_token_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(named_token_edit)
	named_host_edit = LineEdit.new()
	named_host_edit.placeholder_text = "Public hostname routed to the tunnel, e.g. party.example.com"
	named_host_edit.visible = false
	named_host_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(named_host_edit)

	# docs
	left.add_child(_heading("Docs"))
	var links := HFlowContainer.new()
	left.add_child(links)
	for l in LINKS:
		var b := LinkButton.new()
		b.text = l[0]
		b.uri = l[1]
		b.tooltip_text = l[1]
		links.add_child(b)

	# running game status (fed by debugger_plugin.gd / ingame_reporter.gd over EngineDebugger)
	var game := VBoxContainer.new()
	game.custom_minimum_size = Vector2(210, 0)
	game.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(game)
	game.add_child(_heading("Running game"))
	game_status = Label.new()
	game_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	game_status.text = "Run the game from this editor (F5) to see its host status here."
	game.add_child(game_status)
	var game_url_row := HBoxContainer.new()
	game.add_child(game_url_row)
	game_url_edit = LineEdit.new()
	game_url_edit.editable = false
	game_url_edit.placeholder_text = "http://<lan-ip>:<port>/?code=…"
	game_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_url_row.add_child(game_url_edit)
	game_copy_button = Button.new()
	game_copy_button.text = "Copy"
	game_copy_button.disabled = true
	game_copy_button.pressed.connect(func() -> void: DisplayServer.clipboard_set(game_url_edit.text))
	game_url_row.add_child(game_copy_button)
	game_open_button = Button.new()
	game_open_button.text = "Open"
	game_open_button.disabled = true
	game_open_button.pressed.connect(func() -> void: OS.shell_open(game_url_edit.text))
	game_url_row.add_child(game_open_button)
	game_players = Label.new()
	game_players.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	game.add_child(game_players)
	game_qr = TextureRect.new()
	game_qr.custom_minimum_size = Vector2(160, 160)
	game_qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	game_qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	game_qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	game_qr.tooltip_text = "Scan with a phone to join the running game."
	game.add_child(game_qr)

	qr_rect = TextureRect.new()
	qr_rect.custom_minimum_size = Vector2(180, 180)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	qr_rect.tooltip_text = "Scan with a phone to open the test page through the tunnel."
	columns.add_child(qr_rect)

	tunnel = PMCTunnel.new()
	tunnel.name = "Tunnel"
	tunnel.allow_download = true
	tunnel.state_changed.connect(_on_tunnel_state)
	tunnel.download_finished.connect(_on_download_finished)
	add_child(tunnel)
	responder = PMCTunnelTestResponder.new()
	responder.name = "TestResponder"
	add_child(responder)


func _ready() -> void:
	_refresh_binary()
	DebuggerScript.dock = self


func _process(_delta: float) -> void:
	if _downloading:
		var p := tunnel.get_download_progress()
		download_bar.value = maxf(p, 0.0) * 100.0


func _exit_tree() -> void:
	if DebuggerScript.dock == self:
		DebuggerScript.dock = null
	if tunnel != null:
		tunnel.stop()
	if responder != null:
		responder.close()


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.56, 0.94, 0.6))
	return l


func _refresh_binary() -> void:
	var path := PMCTunnel.resolve_binary(tunnel.cloudflared_path)
	var why := PMCTunnel.unsupported_reason()
	if why != "":
		binary_label.text = why
		download_button.disabled = true
		test_button.disabled = true
	elif path == "":
		binary_label.text = "Not installed. It will be saved to %s" % PMCTunnel.install_path()
	else:
		binary_label.text = "Found: %s" % path


func _on_download_pressed() -> void:
	_downloading = true
	download_button.disabled = true
	download_bar.visible = true
	download_bar.value = 0
	binary_label.text = "Downloading %s..." % PMCTunnel.asset_name()
	tunnel.download()


func _on_download_finished(ok: bool, info: String) -> void:
	_downloading = false
	download_button.disabled = false
	download_bar.visible = false
	binary_label.text = ("Saved to %s" % info) if ok else ("Download failed: %s" % info)


func _on_test_pressed() -> void:
	if tunnel.state in ["starting", "ready", "downloading", "lost"]:
		tunnel.stop()
		responder.close()
		return
	var port := responder.listen(18490)
	if port == 0:
		status_label.text = "Could not open a local test port."
		return
	if mode_option.selected == 1:
		tunnel.mode = "named"
		tunnel.named_token = named_token_edit.text.strip_edges()
		tunnel.named_hostname = named_host_edit.text.strip_edges()
	else:
		tunnel.mode = "quick"
	tunnel.start(port)


func _on_tunnel_state(state: String, detail: String) -> void:
	match state:
		"downloading":
			_downloading = true
			download_bar.visible = true
			status_label.text = "Downloading cloudflared: %s" % detail
			test_button.text = "Cancel"
		"starting":
			status_label.text = "Starting cloudflared (the URL usually appears within 5-15 s)..."
			test_button.text = "Stop"
		"ready":
			status_label.text = "Ready. Open the URL (or scan the QR) from any network."
			test_button.text = "Stop"
			_show_url(detail)
		"lost":
			status_label.text = "Tunnel lost: %s (it may recover on its own, or press Stop then Test to restart)" % detail
			test_button.text = "Stop"
		"failed":
			status_label.text = "Failed: %s" % detail
			test_button.text = "Test tunnel"
			responder.close()
			_show_url("")
		"stopped":
			status_label.text = "Stopped."
			test_button.text = "Test tunnel"
			_show_url("")
	if state != "downloading" and _downloading and state != "stopped":
		_downloading = false
		download_bar.visible = false
	_refresh_binary()


func _show_url(u: String) -> void:
	_set_url_row(u, url_edit, copy_button, open_url_button, qr_rect)


## Live status pushed by the running game (see debugger_plugin.gd). [param d] is the reporter payload.
func apply_game_status(session_id: int, d: Dictionary) -> void:
	_game_sessions[session_id] = d
	_refresh_game_status()


## The game's debug session ended.
func clear_game_status(session_id: int) -> void:
	_game_sessions.erase(session_id)
	_refresh_game_status()


func _refresh_game_status() -> void:
	var best := {}
	var best_msec := -1
	for id in _game_sessions:
		var d: Dictionary = _game_sessions[id]
		if int(d.get("msec", 0)) >= best_msec:
			best_msec = int(d.get("msec", 0))
			best = d
	if best.is_empty():
		game_status.text = "Run the game from this editor (F5) to see its host status here."
		game_players.text = ""
		_set_url_row("", game_url_edit, game_copy_button, game_open_button, game_qr)
		return
	if not best.get("running", false):
		game_status.text = "PMCHost found in the running game, but it isn't listening."
		game_players.text = ""
		_set_url_row("", game_url_edit, game_copy_button, game_open_button, game_qr)
		return
	var n := int(best.get("players", 0))
	var total := int(best.get("players_total", n))
	var players_text := "%d player%s" % [n, "" if n == 1 else "s"]
	if total > n:
		players_text += " (%d reconnecting)" % (total - n)
	var parts: Array[String] = ["port %d" % int(best.get("port", 0)), players_text]
	var ts := String(best.get("tunnel_state", ""))
	if ts != "" and ts != "stopped":
		parts.append("tunnel: " + ts)
	game_status.text = " · ".join(parts)
	var names: Array = best.get("player_names", [])
	game_players.text = ", ".join(names) if names.size() > 0 else "No players yet."
	_set_url_row(String(best.get("join_url", "")), game_url_edit, game_copy_button, game_open_button, game_qr)


static func _set_url_row(u: String, edit: LineEdit, copy_b: Button, open_b: Button, qr: TextureRect) -> void:
	edit.text = u
	copy_b.disabled = u == ""
	open_b.disabled = u == ""
	if u == "":
		qr.texture = null
		return
	var m := PMCQr.encode(u, PMCQr.ECC_M)
	qr.texture = ImageTexture.create_from_image(PMCQr.to_image(m, 6, 4)) if m != null else null
