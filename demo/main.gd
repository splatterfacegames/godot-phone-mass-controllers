extends Control
## Buzzer Party: the demo host scene for godot-phone-mass-controllers.
##
## Shows the join QR and a live roster, runs rounds (demo/buzzer_game.gd) and talks to phones
## through PMCHost. The phone side lives in demo/controller/ (message formats are listed at the top
## of controller.js).
##
## Command-line options (after `--`):
##   --port=N  --code=ABCD  --pin=1234  --flash-ms=N  --lead-ms=N  --reveal-ms=N  --target=N
##   --seed=N  --no-auto (don't auto-advance rounds)  --shots=DIR (save a PNG on each phase change)
##   --tunnel (start the Cloudflare quick tunnel right away)

const Game := preload("res://demo/buzzer_game.gd")
const SymbolView := preload("res://demo/symbol_view.gd")

const BG := Color("#101226")
const PANEL := Color("#1d2044")
const PANEL_2 := Color("#171a36")
const TEXT := Color("#f4f3ff")
const DIM := Color("#9a9cc4")
const ACCENT := Color("#ff5a5f")
const GOOD := Color("#2ec27e")

var host: PMCHost
var game: Game
var auto_next := true
var reveal_ms := 4000
var shots_dir := ""

var _reveal_until := 0
var _last_phase := ""
var _roster_dirty := true
var _pin_visible := false
var _seen_join_url := ""

# UI
var _font_bold: SystemFont
var _font_emoji: SystemFont
var _qr_rect: TextureRect
var _url_label: Label
var _code_label: Label
var _tunnel_btn: Button
var _tunnel_label: Label
var _pin_label: Label
var _start_btn: Button
var _next_btn: Button
var _stage_title: Label
var _stage_sub: Label
var _symbol: SymbolView
var _symbol_label: Label
var _roster_title: Label
var _roster: HFlowContainer
var _round_label: Label
var _moved_banner: PanelContainer


func _ready() -> void:
	var args := _parse_args()
	game = Game.new(int(args.get("seed", "0")))
	game.flash_ms = int(args.get("flash-ms", game.flash_ms))
	game.lead_ms = int(args.get("lead-ms", game.lead_ms))
	game.target_score = int(args.get("target", game.target_score))
	reveal_ms = int(args.get("reveal-ms", reveal_ms))
	auto_next = not args.has("no-auto")
	shots_dir = args.get("shots", "")

	host = PMCHost.new()
	host.controller_dir = "res://demo/controller"
	host.port = int(args.get("port", "8080"))
	host.join_code = args.get("code", "")
	host.admin_pin = args.get("pin", "%04d" % (randi() % 10000))
	host.grace_seconds = 90.0 # a pocketed/locked phone stays in the game ~90 s (recommended 60–120)
	host.tunnel_allow_download = true # the "Share outside LAN" button is an explicit opt-in
	add_child(host)

	_build_ui()

	host.player_joined.connect(_on_player_joined)
	host.player_rejoined.connect(_on_player_rejoined)
	host.player_disconnected.connect(func(_p): _changed())
	host.player_left.connect(_on_player_left)
	host.player_updated.connect(func(_p): _changed())
	host.admin_authenticated.connect(func(_p): _changed())
	host.message_received.connect(_on_message)
	host.join_url_changed.connect(_on_join_url_changed)
	host.tunnel_state_changed.connect(_on_tunnel_state)

	var err := host.start()
	if err != OK:
		push_error("Buzzer Party: host failed to start (%s)" % error_string(err))
		_stage_title.text = "Could not open a network port"
		return
	_refresh_join_info()
	print("BUZZER_READY port=%d url=%s pin=%s" % [host.get_port(), host.join_url(), host.admin_pin])
	if args.has("tunnel"):
		host.start_tunnel()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for ev in game.tick(now):
		if ev["type"] == "flash":
			host.broadcast({"type": "flash", "round": game.round_no, "symbol": ev["symbol"], "seq": ev["seq"]})
			if shots_dir != "" and ev["seq"] == 2:
				_save_shot.call_deferred("flash_r%d" % game.round_no)
		else:
			_end_round(now)
	if auto_next and game.phase == "reveal" and _reveal_until > 0 and now >= _reveal_until:
		_start_round()
	if _roster_dirty:
		_roster_dirty = false
		_rebuild_roster()
	_update_stage(now)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE, KEY_ENTER:
				_start_round()
			KEY_R:
				_reset_match()


# --- networking ---------------------------------------------------------------

func _on_player_joined(p: PMCPlayer) -> void:
	game.add_player(p.id)
	_send_secret(p)
	_changed()
	if shots_dir != "" and game.phase == "lobby":
		_save_shot.call_deferred("lobby_players")


func _on_player_rejoined(p: PMCPlayer) -> void:
	game.add_player(p.id)
	_send_secret(p)
	_changed()


func _on_player_left(p: PMCPlayer, reason: String) -> void:
	# Timed-out players keep their score (the host remembers their token); kicked ones don't.
	if reason == "kicked" or reason == "leave":
		game.remove_player(p.id)
	else:
		game.secrets.erase(p.id)
	_changed()


func _on_message(p: PMCPlayer, data) -> void:
	if data is PackedByteArray:
		host.send(p, data) # binary echo: phones use it as a latency probe
		return
	if not data is Dictionary:
		return
	match data.get("type"):
		"buzz":
			_on_buzz(p, data)
		"admin":
			if not p.is_admin:
				return
			match data.get("action"):
				"start":
					if game.phase != "round":
						_start_round()
				"next":
					_start_round()
				"reset":
					_reset_match()
				"kick":
					var id := int(data.get("id", -1))
					if id != p.id and host.get_player(id) != null:
						host.kick(id, "Removed by the game admin")


func _on_buzz(p: PMCPlayer, data: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	# Phones stamp their tap on the host clock (pmc.timestamp()). Credit it, but never further
	# back than the player's round-trip time — fair for remote players, safe against backdating.
	var rtt := _rtt_ms(p)
	var at := now
	var claimed = data.get("at")
	if claimed is int or claimed is float:
		var ticks := int(claimed)
		# pmc.timestamp() uses the host clock the SDK sees; in epoch ms (v0.2+) that's a huge
		# value, so translate it back to ticks. A raw Date.now() claim lands the same way.
		if ticks > 100000000000:
			ticks -= int(Time.get_unix_time_from_system() * 1000.0) - now
		at = clampi(ticks, now - rtt, now)
	var r: Dictionary = game.buzz(p.id, at, now)
	var names := {Game.Buzz.WIN: "win", Game.Buzz.WRONG: "wrong", Game.Buzz.LOCKED: "locked", Game.Buzz.IDLE: "idle"}
	host.send(p, {"type": "buzz", "result": names[r["result"]], "locked_ms": r["locked_ms"]})
	if r["result"] == Game.Buzz.WIN:
		_end_round(now)


func _send_secret(p: PMCPlayer) -> void:
	var idx := game.assign_late_secret(p.id)
	if idx < 0:
		return
	host.send(p, {"type": "secret", "round": game.round_no, "for": p.id, "symbol": Game.SYMBOLS[idx]})


func _start_round() -> void:
	var ids: Array = []
	for p in host.players(false):
		ids.append(p.id)
	if not game.start_round(ids, Time.get_ticks_msec()):
		return
	_reveal_until = 0
	for p in host.players(false):
		_send_secret(p)
	_changed()


func _end_round(now: int) -> void:
	_reveal_until = now + reveal_ms if game.phase == "reveal" else 0
	_changed()


func _reset_match() -> void:
	game.reset_match()
	_reveal_until = 0
	_changed()


func _changed() -> void:
	_roster_dirty = true
	host.broadcast({"type": "state"}.merged(_state()))


## Round-trip ms, or 0 when unknown. (PMCPlayer.rtt_ms — read defensively.)
func _rtt_ms(p: PMCPlayer) -> int:
	var v = p.get("rtt_ms")
	return int(v) if v is int or v is float else 0


func _state() -> Dictionary:
	var list: Array = []
	for p in host.players(true):
		list.append({
			"id": p.id, "name": p.name, "color": str(p.profile.get("color", "#888888")),
			"emoji": str(p.profile.get("emoji", "")), "score": int(game.scores.get(p.id, 0)),
			"connected": p.connected, "admin": p.is_admin, "rtt": _rtt_ms(p),
		})
	return {
		"phase": game.phase, "round": game.round_no, "target": game.target_score,
		"winner": game.winner_id, "match_winner": game.match_winner_id, "players": list,
	}


func _on_tunnel_state(state: String, url: String) -> void:
	match state:
		"downloading":
			_tunnel_label.text = "Downloading cloudflared…"
		"starting":
			_tunnel_label.text = "Opening tunnel…"
		"ready":
			_tunnel_label.text = "Public link ready"
			print("BUZZER_TUNNEL url=%s" % host.join_url())
			_tunnel_btn.text = "Stop sharing"
		"failed":
			_tunnel_label.text = "Tunnel failed: %s" % url
			print("BUZZER_TUNNEL_FAILED %s" % url)
			_tunnel_btn.text = "Share outside LAN"
		"stopped":
			_tunnel_label.text = "LAN only"
			_tunnel_btn.text = "Share outside LAN"
	_tunnel_btn.disabled = state == "downloading" or state == "starting"
	_refresh_join_info()


func _on_tunnel_pressed() -> void:
	if _tunnel_btn.text == "Stop sharing":
		host.stop_tunnel()
	else:
		host.start_tunnel()


func _refresh_join_info() -> void:
	if not host.is_running():
		return
	_qr_rect.texture = host.qr_texture(8)
	var url := host.join_url()
	_url_label.text = url.split("?")[0].trim_prefix("http://").trim_prefix("https://")
	_code_label.text = "CODE  %s" % host.join_code if host.join_code != "" else ""
	_code_label.visible = host.join_code != ""


func _on_join_url_changed(url: String) -> void:
	# The tunnel URL is ephemeral — when it changes, every scanned QR is stale. Say so loudly.
	var changed := _seen_join_url != "" and url != _seen_join_url
	_seen_join_url = url
	_refresh_join_info()
	if changed:
		_moved_banner.show()
		print("BUZZER_MOVED url=%s" % url)


func _on_moved_banner_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		_moved_banner.hide()


# --- UI -------------------------------------------------------------------------

func _build_ui() -> void:
	# Lay out for 1280x720 and scale with the window, so it reads the same on a laptop or a TV.
	get_tree().root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	get_tree().root.content_scale_size = Vector2i(1280, 720)
	set_anchors_preset(PRESET_FULL_RECT)
	_font_bold = SystemFont.new()
	_font_bold.font_names = PackedStringArray(["Segoe UI", "SF Pro Rounded", "Helvetica Neue", "Noto Sans", "sans-serif"])
	_font_bold.font_weight = 800
	_font_emoji = SystemFont.new()
	_font_emoji.font_names = PackedStringArray(["Segoe UI Emoji", "Apple Color Emoji", "Noto Color Emoji"])
	_font_bold.fallbacks = [_font_emoji]
	var theme_ := Theme.new()
	theme_.default_font = _font_bold
	theme_.default_font_size = 20
	theme_.set_color("font_color", "Label", TEXT)
	theme_.set_stylebox("normal", "Button", _box(PANEL, 14, 18, 12))
	theme_.set_stylebox("hover", "Button", _box(PANEL.lightened(0.12), 14, 18, 12))
	theme_.set_stylebox("pressed", "Button", _box(PANEL.darkened(0.2), 14, 18, 12))
	theme_.set_stylebox("disabled", "Button", _box(PANEL_2, 14, 18, 12))
	theme_.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme_.set_color("font_color", "Button", TEXT)
	theme_.set_color("font_hover_color", "Button", TEXT)
	theme_.set_color("font_pressed_color", "Button", TEXT)
	theme_.set_font_size("font_size", "Button", 18)
	theme = theme_

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 28)
	margin.add_child(cols)

	# Left column: title, QR, join info, controls.
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 330
	left.add_theme_constant_override("separation", 10)
	cols.add_child(left)

	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override("separation", -20)
	left.add_child(title_box)
	title_box.add_child(_label("BUZZER", 50, TEXT))
	title_box.add_child(_label("PARTY", 50, ACCENT))

	var qr_panel := PanelContainer.new()
	qr_panel.add_theme_stylebox_override("panel", _box(Color.WHITE, 22, 10, 10))
	qr_panel.size_flags_horizontal = SIZE_SHRINK_BEGIN
	left.add_child(qr_panel)
	_qr_rect = TextureRect.new()
	_qr_rect.custom_minimum_size = Vector2(290, 290)
	_qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	qr_panel.add_child(_qr_rect)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 0)
	left.add_child(info)
	info.add_child(_label("Scan to join, or open", 16, DIM))
	_url_label = _label("…", 22, TEXT)
	_url_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	info.add_child(_url_label)
	_code_label = _label("", 30, Color("#ffc53d"))
	info.add_child(_code_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	left.add_child(spacer)

	var tunnel_row := HBoxContainer.new()
	tunnel_row.add_theme_constant_override("separation", 12)
	left.add_child(tunnel_row)
	_tunnel_btn = Button.new()
	_tunnel_btn.text = "Share outside LAN"
	_tunnel_btn.pressed.connect(_on_tunnel_pressed)
	tunnel_row.add_child(_tunnel_btn)
	_tunnel_label = _label("LAN only", 15, DIM)
	_tunnel_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_tunnel_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tunnel_row.add_child(_tunnel_label)

	# Right column: stage, then roster header with host controls, then roster.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 14)
	cols.add_child(right)

	var stage := PanelContainer.new()
	stage.size_flags_vertical = SIZE_EXPAND_FILL
	stage.add_theme_stylebox_override("panel", _box(PANEL_2, 28, 24, 16))
	right.add_child(stage)
	var stage_box := VBoxContainer.new()
	stage_box.alignment = BoxContainer.ALIGNMENT_CENTER
	stage_box.add_theme_constant_override("separation", 4)
	stage.add_child(stage_box)
	_round_label = _label("", 16, DIM)
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stage_box.add_child(_round_label)
	_stage_title = _label("", 38, TEXT)
	_stage_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stage_box.add_child(_stage_title)
	_symbol = SymbolView.new()
	_symbol.custom_minimum_size = Vector2(0, 170)
	_symbol.size_flags_vertical = SIZE_EXPAND_FILL
	stage_box.add_child(_symbol)
	_symbol_label = _label("", 30, TEXT)
	_symbol_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stage_box.add_child(_symbol_label)
	_stage_sub = _label("", 20, DIM)
	_stage_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stage_box.add_child(_stage_sub)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	right.add_child(bar)
	_roster_title = _label("PLAYERS", 16, DIM)
	_roster_title.size_flags_horizontal = SIZE_EXPAND_FILL
	bar.add_child(_roster_title)
	_pin_label = _label("Admin PIN ••••", 15, DIM)
	_pin_label.tooltip_text = "Click to show. Phones unlock host controls with this PIN."
	_pin_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_pin_label.gui_input.connect(_on_pin_label_input)
	bar.add_child(_pin_label)
	_next_btn = Button.new()
	_next_btn.text = "New match"
	_next_btn.pressed.connect(_reset_match)
	bar.add_child(_next_btn)
	_start_btn = Button.new()
	_start_btn.text = "Start round"
	_start_btn.add_theme_stylebox_override("normal", _box(ACCENT, 14, 18, 10))
	_start_btn.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.1), 14, 18, 10))
	_start_btn.add_theme_color_override("font_color", Color("#16121a"))
	_start_btn.add_theme_color_override("font_hover_color", Color("#16121a"))
	_start_btn.pressed.connect(_start_round)
	bar.add_child(_start_btn)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 160
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_roster = HFlowContainer.new()
	_roster.size_flags_horizontal = SIZE_EXPAND_FILL
	_roster.add_theme_constant_override("h_separation", 10)
	_roster.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_roster)

	# Full-width banner when the join URL moves (ephemeral tunnel). Click to dismiss.
	_moved_banner = PanelContainer.new()
	_moved_banner.set_anchors_preset(PRESET_TOP_WIDE)
	_moved_banner.add_theme_stylebox_override("panel", _box(ACCENT, 0, 12, 10))
	var mb := _label("JOIN LINK CHANGED — phones: re-scan the QR", 22, Color("#16121a"))
	mb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_moved_banner.add_child(mb)
	_moved_banner.tooltip_text = "Click to dismiss"
	_moved_banner.mouse_filter = Control.MOUSE_FILTER_STOP
	_moved_banner.gui_input.connect(_on_moved_banner_input)
	_moved_banner.hide()
	add_child(_moved_banner)


func _on_pin_label_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		_pin_visible = not _pin_visible
		_pin_label.text = ("Admin PIN %s" % host.admin_pin) if _pin_visible else "Admin PIN ••••"


func _update_stage(now: int) -> void:
	var connected := host.players(false).size()
	_start_btn.disabled = connected == 0 or game.phase == "round"
	match game.phase:
		"lobby":
			_round_label.text = "LOBBY"
			_stage_title.text = "Scan the code to join"
			var sym: Dictionary = Game.SYMBOLS[int(now / 1200.0) % Game.SYMBOLS.size()]
			_symbol.show_symbol(sym["shape"], Color(sym["color"]).darkened(0.35))
			_symbol_label.text = ""
			if connected == 0:
				_stage_sub.text = "Every phone gets a secret symbol. Buzz when yours flashes up here!"
			else:
				_stage_sub.text = "%d player%s in. Press Start (or Space) when everyone has joined." % [connected, "" if connected == 1 else "s"]
		"round":
			_round_label.text = "ROUND %d" % game.round_no
			if game.flash_symbol < 0:
				_stage_title.text = "Get ready…"
				_symbol.clear()
				_symbol_label.text = ""
				_stage_sub.text = "Check your phone for your secret symbol"
			else:
				var sym: Dictionary = Game.SYMBOLS[game.flash_symbol]
				_stage_title.text = "Is this yours?"
				_symbol.show_symbol(sym["shape"], Color(sym["color"]))
				_symbol_label.text = sym["label"].to_upper()
				_symbol_label.add_theme_color_override("font_color", Color(sym["color"]))
				_stage_sub.text = "Buzz only when YOUR symbol is showing"
		"reveal", "over":
			_round_label.text = "ROUND %d" % game.round_no
			var w: PMCPlayer = host.get_player(game.winner_id) if game.winner_id >= 0 else null
			if w:
				var sym: Dictionary = Game.SYMBOLS[game.secrets.get(w.id, 0)]
				_symbol.show_symbol(sym["shape"], Color(sym["color"]))
				_symbol_label.text = sym["label"].to_upper()
				_symbol_label.add_theme_color_override("font_color", Color(sym["color"]))
				if game.phase == "over":
					_stage_title.text = "%s %s WINS THE MATCH!" % [w.profile.get("emoji", ""), w.name]
					_stage_sub.text = "Press Start for a rematch"
				else:
					_stage_title.text = "%s %s got it!" % [w.profile.get("emoji", ""), w.name]
			else:
				_symbol.clear()
				_symbol_label.text = ""
				_stage_title.text = "Nobody buzzed in time"
			if game.phase == "reveal":
				if auto_next and _reveal_until > 0:
					_stage_sub.text = "Next round in %d…" % ceili(maxf(0.0, (_reveal_until - now) / 1000.0))
				else:
					_stage_sub.text = "Press Start for the next round"
	if game.phase != _last_phase:
		_last_phase = game.phase
		if shots_dir != "":
			_save_shot.call_deferred("%s_r%d" % [game.phase, game.round_no])


func _rebuild_roster() -> void:
	for c in _roster.get_children():
		c.queue_free()
	var list := host.players(true)
	list.sort_custom(func(a, b): return int(game.scores.get(a.id, 0)) > int(game.scores.get(b.id, 0)) or int(game.scores.get(a.id, 0)) == int(game.scores.get(b.id, 0)) and a.id < b.id)
	var online := 0
	for p in list:
		if p.connected:
			online += 1
		_roster.add_child(_player_card(p))
	_roster_title.text = "PLAYERS  %d online%s" % [online, "" if list.size() == online else ", %d reconnecting" % (list.size() - online)]


func _player_card(p: PMCPlayer) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(200, 0)
	var is_winner := p.id == game.winner_id and game.phase != "round"
	var box := _box(PANEL, 18, 12, 10)
	if is_winner:
		box.border_color = Color("#ffc53d")
		box.set_border_width_all(3)
	card.add_theme_stylebox_override("panel", box)
	card.modulate.a = 1.0 if p.connected else 0.45

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)

	var avatar := PanelContainer.new()
	avatar.custom_minimum_size = Vector2(52, 52)
	avatar.add_theme_stylebox_override("panel", _box(Color(str(p.profile.get("color", "#888888"))), 26, 0, 0))
	var emoji := _label(str(p.profile.get("emoji", "")), 28, TEXT)
	if emoji.text == "":
		emoji.text = p.name.left(1).to_upper()
	emoji.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	emoji.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar.add_child(emoji)
	row.add_child(avatar)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", -2)
	row.add_child(text)
	var name_label := _label(p.name if p.name != "" else "Player %d" % p.id, 19, TEXT)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.custom_minimum_size.x = 80
	text.add_child(name_label)
	var status := "admin" if p.is_admin else "connected"
	var rtt := _rtt_ms(p)
	if p.connected and rtt > 0:
		status += " · %d ms" % rtt
	if not p.connected:
		status = "reconnecting…" # socket lost, grace running — distinct from "left"
	var status_label := _label(status, 13, GOOD if p.connected else DIM)
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(status_label)

	var score := _label(str(game.scores.get(p.id, 0)), 30, Color("#ffc53d") if is_winner else TEXT)
	row.add_child(score)
	return card


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


func _box(color: Color, radius: int, pad_x: int, pad_y: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = color
	b.set_corner_radius_all(radius)
	b.content_margin_left = pad_x
	b.content_margin_right = pad_x
	b.content_margin_top = pad_y
	b.content_margin_bottom = pad_y
	b.anti_aliasing = true
	return b


func _save_shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(shots_dir)
	img.save_png(shots_dir.path_join("host_%s.png" % name))


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out
