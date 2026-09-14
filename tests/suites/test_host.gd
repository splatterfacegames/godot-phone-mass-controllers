extends RefCounted
## PMCHost sessions and API: hello/welcome, rejoin, grace, tombstones, join code, full, admin, kick, replaced,
## leave, heartbeat, clock pong, send/broadcast, join URL, LAN scoring, port search, QR/tunnel wiring.

const TIMEOUT := 180

var host: PMCHost
var port := 0
var log: Array = []   # [signal, args...]


func _make_host(t) -> PMCHost:
	var h := PMCHost.new()
	h.port = 0
	h.controller_dir = ""
	h.grace_seconds = 0.5
	h.remember_seconds = 60.0
	h.heartbeat_seconds = 0.0
	h.admin_pin = "2468"
	t.add_node(h)
	return h


func _connect_log(h: PMCHost) -> void:
	h.player_joined.connect(func(p): log.append(["joined", p]))
	h.player_rejoined.connect(func(p): log.append(["rejoined", p]))
	h.player_disconnected.connect(func(p): log.append(["disconnected", p]))
	h.player_left.connect(func(p, r): log.append(["left", p, r]))
	h.player_updated.connect(func(p): log.append(["updated", p]))
	h.admin_authenticated.connect(func(p): log.append(["admin", p]))
	h.message_received.connect(func(p, d): log.append(["message", p, d]))


func _seen(kind: String, id := -1) -> Array:
	for e in log:
		if e[0] == kind and (id < 0 or e[1].id == id):
			return e
	return []


func _wait_seen(t, kind: String, id := -1, timeout := 3.0) -> Array:
	var holder := [[]]
	await t.wait_until(func() -> bool:
		holder[0] = _seen(kind, id)
		return not holder[0].is_empty(), timeout)
	return holder[0]


func _join(t, extra := {}) -> Array:
	var ws := PMCTestWs.new(t)
	if not await ws.open(port):
		return [ws, {}]
	await ws.hello(extra)
	var w := await ws.wait_json("pmc.welcome")
	return [ws, w]


func run(t) -> void:
	host = _make_host(t)
	_connect_log(host)
	var started := [0]
	host.started.connect(func(p): started[0] = p)
	t.eq(host.start(), OK, "start")
	port = host.get_port()
	t.eq(started[0], port, "started(port) signal")
	t.ok(host.is_running(), "is_running")

	await _hello(t)
	await _messaging(t)
	await _rejoin_grace(t)
	await _codes_and_limits(t)
	await _admin(t)
	await _kick_replace_leave(t)
	await _heartbeat(t)
	await _urls(t)
	_lan(t)
	await _port_search(t)
	await _qr_tunnel(t)

	t.section("stop")
	var j := await _join(t)
	var ws: PMCTestWs = j[0]
	var stopped := [false]
	host.stopped.connect(func(): stopped[0] = true)
	host.stop()
	t.ok(stopped[0] and not host.is_running(), "stopped signal")
	t.eq(await ws.wait_close(), 1001, "clients get 1001 on stop")
	t.eq(host.players().size(), 0, "players cleared on stop")


func _hello(t) -> void:
	t.section("hello / welcome")
	log.clear()
	var j := await _join(t, {"name": "  Annie  ", "profile": {"color": "red"}})
	var ws: PMCTestWs = j[0]
	var w: Dictionary = j[1]
	t.eq(w.get("t"), "pmc.welcome", "welcome received")
	t.eq(w.get("name"), "Annie", "name trimmed and control chars stripped")
	t.eq(w.get("profile"), {"color": "red"}, "profile echoed")
	t.eq(w.get("rejoined"), false, "rejoined false")
	t.eq(w.get("admin"), false, "admin false")
	t.ok(String(w.get("token", "")).length() == 32, "128-bit hex token")
	t.ok(w.has("server_ms") and w.has("join_url") and w.has("id"), "server_ms, join_url, id present")
	var p := host.get_player(int(w.get("id", 0)))
	t.ok(p != null and p.connected and p.name == "Annie" and p.remote_address == "127.0.0.1", "PMCPlayer populated")
	t.ok(not _seen("joined", p.id if p else 0).is_empty(), "player_joined emitted")
	var j2 := await _join(t, {"name": "x".repeat(100)})
	t.eq(String(j2[1].get("name", "")).length(), PMCHost.MAX_NAME_LENGTH, "long name truncated")
	var j3 := await _join(t)
	t.eq(j3[1].get("name"), "Player %d" % int(j3[1].get("id", 0)), "default name")
	t.ok(int(j2[1].id) > int(w.id) and int(j3[1].id) > int(j2[1].id), "ids increase")
	var unknown := await _join(t, {"token": "deadbeefdeadbeefdeadbeefdeadbeef"})
	t.ok(unknown[1].get("token") != "deadbeefdeadbeefdeadbeefdeadbeef" and unknown[1].get("rejoined") == false, "unknown token gets a fresh token")
	var ids: Array = host.players().map(func(pl): return pl.id)
	var sorted_ids := ids.duplicate()
	sorted_ids.sort()
	t.eq(ids, sorted_ids, "players() ordered by id")

	var ver := PMCTestWs.new(t)
	await ver.open(port)
	await ver.hello({"sdk": 2})
	t.eq((await ver.wait_json("pmc.reject")).get("code"), "version", "sdk 2 -> reject version")
	t.eq(await ver.wait_close(), 4000, "reject closes 4000")
	var nosdk := PMCTestWs.new(t)
	await nosdk.open(port)
	await nosdk.send_json({"t": "pmc.hello"})
	t.eq((await nosdk.wait_json("pmc.reject")).get("code"), "bad_hello", "missing sdk -> bad_hello")
	var other_first := PMCTestWs.new(t)
	await other_first.open(port)
	await other_first.send_json({"t": "msg", "d": 1})
	t.eq((await other_first.wait_json("pmc.reject")).get("code"), "bad_hello", "msg before hello -> bad_hello")
	for c in [ws, j2[0], j3[0], unknown[0]]:
		c.close()
	await t.wait(0.1)


func _messaging(t) -> void:
	t.section("messages, send, broadcast, ping")
	log.clear()
	var a := await _join(t, {"name": "A"})
	var b := await _join(t, {"name": "B"})
	var wa: PMCTestWs = a[0]
	var wb: PMCTestWs = b[0]
	var ida := int(a[1].id)
	var idb := int(b[1].id)
	await wa.send_json({"t": "msg", "d": {"press": true, "n": 3}})
	var m := await _wait_seen(t, "message", ida)
	t.eq(m[2] if m.size() > 2 else null, {"press": true, "n": 3}, "message_received with d")
	await wa.send_frame(PMCWsFrame.OP_BINARY, PackedByteArray([9, 8, 7]))
	var got_bin: bool = await t.wait_until(func() -> bool:
		for e in log:
			if e[0] == "message" and e[2] is PackedByteArray and e[2] == PackedByteArray([9, 8, 7]):
				return true
		return false)
	t.ok(got_bin, "binary message_received as PackedByteArray")

	host.send(ida, {"hi": "a"})
	t.eq((await wa.wait_json("msg")).get("d"), {"hi": "a"}, "send by id")
	host.send(host.get_player(idb), [1, "two"])
	t.eq((await wb.wait_json("msg")).get("d"), [1, "two"], "send by PMCPlayer")
	host.send(idb, "just a string")
	t.eq((await wb.wait_json("msg")).get("d"), "just a string", "send string")
	host.send(idb, 42)
	t.eq((await wb.wait_json("msg")).get("d"), 42, "send number")
	host.send(idb, PackedByteArray([1, 2, 3]))
	var be := await wb.wait_event(func(e): return e.op == "binary")
	t.eq(be.get("data"), PackedByteArray([1, 2, 3]), "send binary")
	host.send(9999, {"nobody": true})
	t.ok(true, "send to unknown id is a no-op")

	host.broadcast({"all": 1})
	t.eq((await wa.wait_json("msg")).get("d"), {"all": 1}, "broadcast reaches A")
	t.eq((await wb.wait_json("msg")).get("d"), {"all": 1}, "broadcast reaches B")
	host.broadcast({"only": "B"}, func(p: PMCPlayer) -> bool: return p.id == idb)
	t.eq((await wb.wait_json("msg")).get("d"), {"only": "B"}, "filtered broadcast reaches B")
	t.ok((await wa.wait_json("msg", 0.3)).is_empty(), "filtered broadcast skips A")

	await wa.send_json({"t": "pmc.ping", "c": 12345.5})
	var pong := await wa.wait_json("pmc.pong")
	t.eq(pong.get("c"), 12345.5, "pong echoes c")
	var epoch_ms := Time.get_unix_time_from_system() * 1000.0
	t.ok(absf(float(pong.get("s", 0)) - epoch_ms) < 2000, "pong s is epoch ms")
	t.ok(absf(float(a[1].get("server_ms", 0)) - epoch_ms) < 60000, "welcome server_ms is epoch ms")

	await wb.send_json({"t": "pmc.profile", "name": "Bee", "profile": {"hat": 1}})
	await _wait_seen(t, "updated", idb)
	var pb := host.get_player(idb)
	t.eq([pb.name, pb.profile], ["Bee", {"hat": 1}], "pmc.profile updates player + player_updated")
	log.clear()
	await wb.send_json({"t": "pmc.profile", "name": "Bee", "profile": {"hat": 1}})
	await t.wait(0.15)
	t.ok(_seen("updated", idb).is_empty(), "unchanged profile emits nothing")
	await wb.send_json({"t": "pmc.unknown"})
	await wb.send_json({"no_t": 1})
	await wb.send_frame(PMCWsFrame.OP_TEXT, "[1,2]".to_utf8_buffer())
	await wb.send_json({"t": "pmc.ping", "c": 1})
	t.ok(not (await wb.wait_json("pmc.pong")).is_empty(), "unknown/invalid frames after hello are ignored")
	wa.close()
	wb.close()
	await t.wait(0.1)


func _rejoin_grace(t) -> void:
	t.section("rejoin within grace")
	log.clear()
	host.grace_seconds = 2.0
	var a := await _join(t, {"name": "Re"})
	var ws: PMCTestWs = a[0]
	var id := int(a[1].id)
	var token: String = a[1].token
	host.get_player(id).meta["score"] = 7
	ws.close()
	t.ok(not (await _wait_seen(t, "disconnected", id)).is_empty(), "player_disconnected on socket loss")
	var p := host.get_player(id)
	t.ok(p != null and not p.connected and p.grace_deadline_msec > Time.get_ticks_msec(), "player kept during grace")
	t.eq(host.players(false).filter(func(x): return x.id == id).size(), 0, "players(false) excludes disconnected")
	t.eq(host.players(true).filter(func(x): return x.id == id).size(), 1, "players(true) includes disconnected")
	var r := await _join(t, {"token": token, "name": "Re2"})
	t.eq(int(r[1].get("id", -1)), id, "same id on rejoin")
	t.eq(r[1].get("rejoined"), true, "welcome.rejoined")
	t.eq(r[1].get("token"), token, "same token")
	t.ok(not (await _wait_seen(t, "rejoined", id)).is_empty(), "player_rejoined emitted")
	t.ok(host.get_player(id) == p and p.meta.get("score") == 7 and p.connected, "same PMCPlayer, meta kept")
	t.ok(not _seen("updated", id).is_empty() and p.name == "Re2", "name change on rejoin -> player_updated")
	t.ok(_seen("left", id).is_empty(), "no player_left during grace")

	t.section("grace expiry and tombstone")
	log.clear()
	host.grace_seconds = 0.3
	(r[0] as PMCTestWs).close()
	var left := await _wait_seen(t, "left", id, 3.0)
	t.eq(left[2] if left.size() > 2 else "", "timeout", "player_left reason timeout")
	t.eq(host.get_player(id), null, "player removed")
	log.clear()
	var back := await _join(t, {"token": token})
	t.eq(int(back[1].get("id", -1)), id, "tombstone restores id")
	t.eq(back[1].get("rejoined"), true, "tombstone welcome.rejoined")
	t.eq(back[1].get("name"), "Re2", "tombstone restores name")
	var np := host.get_player(id)
	t.ok(np != null and np.meta.get("score") == 7, "tombstone restores meta")
	t.ok(not _seen("joined", id).is_empty(), "tombstone recall emits player_joined")

	t.section("remember_seconds = 0")
	host.remember_seconds = 0.0
	(back[0] as PMCTestWs).close()
	await _wait_seen(t, "left", id, 3.0)
	var fresh := await _join(t, {"token": token})
	t.ok(int(fresh[1].get("id", -1)) != id and fresh[1].get("token") != token, "no tombstone -> new player and token")
	(fresh[0] as PMCTestWs).close()
	host.remember_seconds = 60.0

	t.section("grace_seconds = 0")
	host.grace_seconds = 0.0
	log.clear()
	var z := await _join(t)
	var zid := int(z[1].id)
	(z[0] as PMCTestWs).close()
	var zl := await _wait_seen(t, "left", zid, 2.0)
	t.ok(not _seen("disconnected", zid).is_empty() and zl.size() > 2 and zl[2] == "timeout", "immediate timeout with grace 0")
	host.grace_seconds = 0.5
	await t.wait(0.1)


func _codes_and_limits(t) -> void:
	t.section("join code")
	host.join_code = "ABCD"
	var bad := PMCTestWs.new(t)
	await bad.open(port)
	await bad.hello({"code": "ZZZZ"})
	var rej := await bad.wait_json("pmc.reject")
	t.eq(rej.get("code"), "bad_code", "wrong code -> bad_code")
	t.eq(await bad.wait_close(), 4000, "bad_code closes 4000")
	var missing := PMCTestWs.new(t)
	await missing.open(port)
	await missing.hello()
	t.eq((await missing.wait_json("pmc.reject")).get("code"), "bad_code", "missing code -> bad_code")
	var good := await _join(t, {"code": " abcd "})
	t.eq(good[1].get("t"), "pmc.welcome", "code is case-insensitive and trimmed")
	var tok: String = good[1].get("token", "")
	host.grace_seconds = 5.0
	(good[0] as PMCTestWs).close()
	await _wait_seen(t, "disconnected", int(good[1].get("id", 0)))
	var rejoin := await _join(t, {"token": tok})
	t.eq(rejoin[1].get("rejoined"), true, "known token rejoins without code")
	(rejoin[0] as PMCTestWs).close()
	host.join_code = ""
	host.grace_seconds = 0.0
	await t.wait(0.2)
	host.grace_seconds = 0.5

	t.section("max players")
	# Let earlier sockets' closes be noticed and their grace periods run out, so the count is stable.
	await t.wait(1.2)
	var before := host.players().size()
	host.max_players = before + 1
	var one := await _join(t)
	t.eq(one[1].get("t"), "pmc.welcome", "fills last slot")
	var full := PMCTestWs.new(t)
	await full.open(port)
	await full.hello()
	t.eq((await full.wait_json("pmc.reject")).get("code"), "full", "over capacity -> full")
	host.grace_seconds = 5.0
	(one[0] as PMCTestWs).close()
	await t.wait(0.2)
	var again := await _join(t, {"token": one[1].token})
	t.eq(again[1].get("rejoined"), true, "grace player can rejoin while full")
	(again[0] as PMCTestWs).close()
	host.max_players = 0
	host.grace_seconds = 0.0
	await t.wait(0.2)
	host.grace_seconds = 0.5


func _admin(t) -> void:
	t.section("admin auth + lockout")
	log.clear()
	var a := await _join(t)
	var ws: PMCTestWs = a[0]
	var id := int(a[1].id)
	for i in 4:
		await ws.send_json({"t": "pmc.auth", "pin": "0000"})
		t.eq((await ws.wait_json("pmc.auth")).get("ok"), false, "wrong pin %d" % (i + 1))
	await ws.send_json({"t": "pmc.auth", "pin": 2468})
	t.eq((await ws.wait_json("pmc.auth")).get("ok"), false, "non-string pin fails (5th failure)")
	await ws.send_json({"t": "pmc.auth", "pin": "2468"})
	var locked := await ws.wait_json("pmc.auth")
	t.eq(locked.get("ok"), false, "correct pin refused during lockout")
	t.ok(float(locked.get("locked_ms", 0)) > 25000, "lockout ~30 s reported")
	t.ok(not host.get_player(id).is_admin, "not admin while locked")
	var b := await _join(t)
	var wb: PMCTestWs = b[0]
	await wb.send_json({"t": "pmc.auth", "pin": "2468"})
	t.eq((await wb.wait_json("pmc.auth")).get("ok"), true, "other connection can auth (lockout is per connection)")
	var bid := int(b[1].id)
	t.ok(host.get_player(bid).is_admin and not (await _wait_seen(t, "admin", bid)).is_empty(), "is_admin + admin_authenticated")
	host.grace_seconds = 5.0
	wb.close()
	await _wait_seen(t, "disconnected", bid)
	var back := await _join(t, {"token": b[1].token})
	t.eq(back[1].get("admin"), true, "admin kept on rejoin")
	host.admin_pin = ""
	await (back[0] as PMCTestWs).send_json({"t": "pmc.auth", "pin": ""})
	t.eq((await (back[0] as PMCTestWs).wait_json("pmc.auth")).get("ok"), false, "empty admin_pin never authenticates")
	host.admin_pin = "2468"
	ws.close()
	(back[0] as PMCTestWs).close()
	host.grace_seconds = 0.0
	await t.wait(0.2)
	host.grace_seconds = 0.5


func _kick_replace_leave(t) -> void:
	t.section("kick")
	log.clear()
	var a := await _join(t)
	var ws: PMCTestWs = a[0]
	var id := int(a[1].id)
	host.kick(id, "be nice")
	t.eq((await ws.wait_json("pmc.kicked")).get("reason"), "be nice", "pmc.kicked with reason")
	t.eq(await ws.wait_close(), 4001, "kick closes 4001")
	var l := await _wait_seen(t, "left", id)
	t.eq(l[2] if l.size() > 2 else "", "kicked", "player_left kicked")
	t.eq(host.get_player(id), null, "kicked player removed")
	t.ok(_seen("disconnected", id).is_empty(), "no player_disconnected for kick")
	var again := await _join(t, {"token": a[1].token})
	t.ok(again[1].get("t") == "pmc.welcome" and int(again[1].id) != id, "kicked token without ban joins as new player")
	host.kick(host.get_player(int(again[1].id)), "bye", true)
	await (again[0] as PMCTestWs).wait_close()
	var banned := PMCTestWs.new(t)
	await banned.open(port)
	await banned.hello({"token": again[1].token})
	t.eq((await banned.wait_json("pmc.reject")).get("code"), "banned", "ban -> reject banned")
	host.clear_bans()
	var unbanned := await _join(t, {"token": again[1].token})
	t.eq(unbanned[1].get("t"), "pmc.welcome", "clear_bans")
	(unbanned[0] as PMCTestWs).close()
	host.grace_seconds = 5.0
	var g := await _join(t)
	(g[0] as PMCTestWs).close()
	await _wait_seen(t, "disconnected", int(g[1].id))
	log.clear()
	host.kick(int(g[1].id))
	t.eq((await _wait_seen(t, "left", int(g[1].id)))[2], "kicked", "kick a player in grace")

	t.section("kick(remember)")
	var r2 := await _join(t, {"name": "Keep"})
	var rid2 := int(r2[1].id)
	var tok2: String = r2[1].token
	host.get_player(rid2).meta["n"] = 5
	host.kick(rid2, "afk", false, true)
	t.eq((await _wait_seen(t, "left", rid2))[2], "kicked", "remembered kick still reports kicked")
	var back2 := await _join(t, {"token": tok2})
	t.eq(int(back2[1].get("id", -1)), rid2, "remembered kick restores id")
	t.eq(back2[1].get("rejoined"), true, "remembered kick rejoins")
	t.eq(host.get_player(rid2).meta.get("n"), 5, "remembered kick restores meta")
	(back2[0] as PMCTestWs).close()

	t.section("replaced")
	log.clear()
	var first := await _join(t)
	var w1: PMCTestWs = first[0]
	var rid := int(first[1].id)
	var second := await _join(t, {"token": first[1].token})
	t.eq(int(second[1].get("id", -1)), rid, "second socket takes over the same player")
	t.ok(not (await w1.wait_json("pmc.replaced")).is_empty(), "old socket gets pmc.replaced")
	t.eq(await w1.wait_close(), 4002, "old socket closed 4002")
	await t.wait(0.2)
	t.ok(host.get_player(rid).connected, "player still connected on new socket")
	t.ok(_seen("disconnected", rid).is_empty(), "no player_disconnected when replaced")
	t.ok(not _seen("rejoined", rid).is_empty(), "player_rejoined when replaced")
	host.send(rid, "to-new")
	t.eq((await (second[0] as PMCTestWs).wait_json("msg")).get("d"), "to-new", "messages go to the new socket")

	t.section("leave")
	log.clear()
	await (second[0] as PMCTestWs).send_json({"t": "pmc.leave"})
	var ll := await _wait_seen(t, "left", rid)
	t.eq(ll[2] if ll.size() > 2 else "", "leave", "player_left leave (no grace)")
	t.eq(await (second[0] as PMCTestWs).wait_close(), 1000, "leave closes 1000")
	t.ok(_seen("disconnected", rid).is_empty(), "no player_disconnected on leave")
	var after := await _join(t, {"token": first[1].token})
	t.ok(int(after[1].get("id", -1)) != rid, "no tombstone after leave")
	(after[0] as PMCTestWs).close()
	host.grace_seconds = 0.0
	await t.wait(0.2)
	host.grace_seconds = 0.5


func _heartbeat(t) -> void:
	t.section("heartbeat")
	log.clear()
	host.heartbeat_seconds = 0.2
	var dead := PMCTestWs.new(t)
	dead.auto_pong = false
	await dead.open(port)
	await dead.hello()
	var w := await dead.wait_json("pmc.welcome")
	var did := int(w.get("id", 0))
	var alive := await _join(t)
	var alive_ws: PMCTestWs = alive[0]
	var t0 := Time.get_ticks_msec()
	t.ok(await t.wait_until(func() -> bool:
		alive_ws._drain()  # keep answering pings on the live socket meanwhile
		dead._drain()
		return dead.sock.closed, 3.0), "unresponsive socket closed")
	var elapsed := Time.get_ticks_msec() - t0
	t.ok(elapsed >= 300 and elapsed < 1500, "closed after ~2 missed intervals (%d ms)" % elapsed)
	t.ok(not (await _wait_seen(t, "disconnected", did)).is_empty(), "player_disconnected from heartbeat")
	await t.wait_until(func() -> bool:
		alive_ws._drain()
		return false, 0.8)
	t.ok(not alive_ws.sock.closed and host.get_player(int(alive[1].id)).connected, "pong-answering socket stays open")
	alive_ws.close()
	host.heartbeat_seconds = 0.0
	await t.wait(0.1)


func _urls(t) -> void:
	t.section("join URL")
	var urls: Array = []
	var cb := func(u): urls.append(u)
	host.join_url_changed.connect(cb)
	var lan := host.lan_addresses()
	var expect_host: String = lan[0].address if lan.size() > 0 else "127.0.0.1"
	t.eq(host.join_url(), "http://%s:%d/" % [expect_host, port], "default LAN join URL")
	host.join_code = "WXYZ"
	t.eq(host.join_url(), "http://%s:%d/?code=WXYZ" % [expect_host, port], "join code appended")
	host.advertise_url = "https://play.example.com"
	t.eq(host.join_url(), "https://play.example.com/?code=WXYZ", "advertise_url gets trailing slash")
	host.advertise_url = "https://play.example.com/room?x=1"
	t.eq(host.join_url(), "https://play.example.com/room?x=1&code=WXYZ", "code appended with &")
	host.advertise_url = "10.1.2.3:9000"
	host.join_code = ""
	t.eq(host.join_url(), "http://10.1.2.3:9000/", "scheme added")
	host.advertise_url = ""
	t.eq(urls.size(), 6, "join_url_changed emitted on each change")
	t.eq(urls[urls.size() - 1], host.join_url(), "signal carries the new URL")
	host.join_url_changed.disconnect(cb)
	var r := await PMCTestSocket.get_url(t, port, "/pmc/info.json")
	var info = JSON.parse_string(r.body.get_string_from_utf8()) if r.has("body") else {}
	t.eq(info.get("join_url"), host.join_url(), "info.json join_url")


func _lan(t) -> void:
	t.section("LAN address scoring")
	var addrs := host.lan_addresses()
	t.ok(addrs is Array, "lan_addresses returns an array")
	for a in addrs:
		t.ok(a.has("name") and a.has("address") and a.has("score") and not String(a.address).begins_with("127.") and not String(a.address).contains(":"), "entry shape IPv4 %s (%s) score %d" % [a.address, a.name, a.score])
	for i in range(1, addrs.size()):
		t.ok(addrs[i - 1].score >= addrs[i].score, "sorted best first")
	# [better, worse] pairs.
	var pairs := [
		[["Ethernet", "192.168.1.20"], ["vEthernet (WSL)", "172.28.160.1"]],
		[["Wi-Fi", "10.0.0.12"], ["vEthernet (Default Switch)", "172.17.32.1"]],
		[["Wi-Fi", "192.168.0.7"], ["Tailscale", "100.101.102.103"]],
		[["Ethernet 2", "192.168.1.5"], ["ZeroTier One [8056c2e21c000001]", "10.147.17.5"]],
		[["Wi-Fi", "192.168.1.5"], ["VirtualBox Host-Only Network", "192.168.56.1"]],
		[["eth0", "10.0.0.5"], ["docker0", "172.17.0.1"]],
		[["wlan0", "192.168.43.2"], ["br-1a2b3c", "172.18.0.1"]],
		[["en0", "192.168.1.30"], ["utun3", "10.8.0.2"]],
		[["enp3s0", "192.168.1.30"], ["wg0", "10.66.66.2"]],
		[["Ethernet", "192.168.1.20"], ["Ethernet", "169.254.10.10"]],
		[["Local Area Connection", "192.168.1.9"], ["VMware Network Adapter VMnet8", "192.168.150.1"]],
		[["Wi-Fi", "192.168.1.9"], ["vEthernet (Hyper-V Virtual Ethernet Adapter)", "192.168.1.200"]],
		[["Ethernet", "10.20.30.40"], ["Ethernet", "8.8.4.4"]],
	]
	for pr in pairs:
		var good := PMCHost.score_address(pr[0][0], pr[0][1])
		var bad := PMCHost.score_address(pr[1][0], pr[1][1])
		t.ok(good > bad, "%s %s (%d) beats %s %s (%d)" % [pr[0][0], pr[0][1], good, pr[1][0], pr[1][1], bad])
	t.eq(PMCHost.score_address("lo", "127.0.0.1"), -1000, "loopback excluded")
	t.eq(PMCHost.score_address("eth0", "fe80::1"), -1000, "IPv6 excluded")


func _port_search(t) -> void:
	t.section("port search")
	var h2 := PMCHost.new()
	h2.port = port
	h2.port_search = 5
	h2.controller_dir = ""
	t.add_node(h2)
	t.eq(h2.start(), OK, "second host finds a port")
	t.ok(h2.get_port() > port and h2.get_port() <= port + 5, "next port used (%d -> %d)" % [port, h2.get_port()])
	var h3 := PMCHost.new()
	h3.port = port
	h3.port_search = 0
	h3.controller_dir = ""
	t.add_node(h3)
	t.ok(h3.start() != OK and not h3.is_running(), "port_search 0 on a busy port fails")
	h2.stop()
	t.eq(h3.get_port(), port, "get_port returns configured port when not running")


class FakeTunnel extends Node:
	signal state_changed(state: String, detail: String)
	var url := ""
	var allow_download := false
	var cloudflared_path := ""
	var started_port := -1
	var stopped := false
	func start(p: int) -> void:
		started_port = p
	func stop() -> void:
		stopped = true


func _qr_tunnel(t) -> void:
	t.section("QR")
	if t.class_available("PMCQr"):
		var img := host.qr_image(4, 2)
		t.ok(img != null and img.get_width() > 0 and img.get_width() == img.get_height(), "qr_image square image")
		t.ok(host.qr_texture(2) is ImageTexture, "qr_texture")
	else:
		t.note("PMCQr not present; QR checks skipped")

	t.section("tunnel wiring (fake tunnel)")
	var states: Array = []
	var urls: Array = []
	var s_cb := func(s, u): states.append([s, u])
	var u_cb := func(u): urls.append(u)
	host.tunnel_state_changed.connect(s_cb)
	host.join_url_changed.connect(u_cb)
	if not t.class_available("PMCTunnel"):
		host.start_tunnel()
		t.eq(states.size() > 0 and states[0][0], "failed", "start_tunnel without PMCTunnel -> failed")
		states.clear()
	var fake := FakeTunnel.new()
	host.add_child(fake)
	host._tunnel = fake
	fake.state_changed.connect(host._on_tunnel_state)
	host.join_code = ""
	host.advertise_url = ""
	urls.clear()
	fake.state_changed.emit("starting", "")
	fake.url = "https://random-words.trycloudflare.com"
	fake.state_changed.emit("ready", "")
	t.eq(states.map(func(x): return x[0]), ["starting", "ready"], "states forwarded")
	t.eq(states[1][1], "https://random-words.trycloudflare.com", "ready carries URL")
	t.eq(host.advertise_url, "https://random-words.trycloudflare.com", "advertise_url set")
	var code_ok := host.join_code.length() == 4
	for ch in host.join_code:
		if ch < "A" or ch > "Z":
			code_ok = false
	t.ok(code_ok, "4-letter join code generated (%s)" % host.join_code)
	t.eq(urls.size(), 1, "one join_url_changed on ready")
	t.eq(host.join_url(), "https://random-words.trycloudflare.com/?code=" + host.join_code, "tunnel join URL")
	host.stop_tunnel()
	t.ok(fake.stopped, "stop_tunnel stops the tunnel")
	t.eq(states[states.size() - 1][0], "stopped", "stopped state emitted")
	t.eq(host.advertise_url, "", "advertise_url restored")
	t.eq(host.join_code, "", "generated code cleared")
	t.ok(host.get_tunnel() == null, "tunnel released")

	# Failure path keeps a user-set code.
	var fake2 := FakeTunnel.new()
	host.add_child(fake2)
	host._tunnel = fake2
	fake2.state_changed.connect(host._on_tunnel_state)
	host.join_code = "KEEP"
	fake2.url = "https://x.trycloudflare.com"
	fake2.state_changed.emit("ready", "")
	t.eq(host.join_code, "KEEP", "existing join code kept")
	fake2.state_changed.emit("failed", "process exited")
	t.eq(states[states.size() - 1], ["failed", "process exited"], "failed forwarded with reason")
	t.eq(host.advertise_url, "", "advertise restored after failure")
	t.eq(host.join_code, "KEEP", "user code untouched")
	host.join_code = ""
	host.tunnel_state_changed.disconnect(s_cb)
	host.join_url_changed.disconnect(u_cb)
