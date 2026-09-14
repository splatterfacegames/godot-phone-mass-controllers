extends RefCounted
## WebSocket server: frame codec unit tests, Godot WebSocketPeer interop, and raw protocol violations.

const TIMEOUT := 180

var host: PMCHost
var port := 0


func run(t) -> void:
	_codec(t)

	host = PMCHost.new()
	host.port = 0
	host.controller_dir = ""
	host.hello_timeout_seconds = 0.5
	host.heartbeat_seconds = 0.25
	host.max_connections_per_address = 0
	t.add_node(host)
	host.message_received.connect(func(p: PMCPlayer, d) -> void: host.send(p, d))
	t.eq(host.start(), OK, "host starts")
	port = host.get_port()

	await _godot_client(t)
	await _raw_protocol(t)
	await _violations(t)
	var ws := PMCTestWs.new(t)
	t.ok(await ws.open(port), "host still accepts after abuse")
	await ws.hello()
	t.ok(not (await ws.wait_json("pmc.welcome")).is_empty(), "host still welcomes after abuse")
	ws.close()
	host.stop()


func _codec(t) -> void:
	t.section("codec")
	t.eq(PMCWsFrame.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 accept key example")
	var key := PackedByteArray([0x37, 0xfa, 0x21, 0x3d])
	for n in [0, 1, 7, 8, 9, 63, 64, 65, 125, 126, 127, 1000, 65535, 65536, 70001]:
		var data := PackedByteArray()
		data.resize(n)
		for i in n:
			data[i] = (i * 31 + 7) % 256
		var masked := PMCWsFrame.xor_mask(data, key)
		var ok: bool = masked.size() == n
		for i in n:
			if masked[i] != data[i] ^ key[i % 4]:
				ok = false
				break
		t.ok(ok, "xor_mask correct for %d bytes" % n)
		t.eq(PMCWsFrame.xor_mask(masked, key), data, "xor_mask round-trips %d bytes" % n)
		var dec := PMCWsDecoder.new()
		dec.max_message_bytes = 1 << 20
		dec.push(PMCWsFrame.encode(PMCWsFrame.OP_BINARY, data, true, key))
		var ev := dec.next()
		t.ok(ev.get("op") == "binary" and ev.data == data, "decode masked binary of %d bytes" % n)
		var hdr: int = PMCWsFrame.binary(data).size() - n
		t.eq(hdr, 2 if n < 126 else (4 if n < 65536 else 10), "header length for %d" % n)
	t.eq(PMCWsFrame.text("Hello").hex_encode(), "810548656c6c6f", "unmasked text frame (RFC example)")
	var d2 := PMCWsDecoder.new()
	d2.push(PackedByteArray([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]))
	t.eq(d2.next(), {"op": "text", "data": "Hello"}, "masked RFC example frame")
	# Byte-at-a-time feeding.
	var d3 := PMCWsDecoder.new()
	var frame := PMCWsFrame.encode(PMCWsFrame.OP_TEXT, "héllo wörld".to_utf8_buffer(), true, key)
	var got := {}
	for b in frame:
		d3.push(PackedByteArray([b]))
		var e := d3.next()
		if not e.is_empty():
			got = e
	t.eq(got, {"op": "text", "data": "héllo wörld"}, "byte-at-a-time decode")
	# Large masked frame fed in odd-sized chunks (chunked unmasking with key rotation).
	var payload := PackedByteArray()
	payload.resize(100003)
	for i in payload.size():
		payload[i] = (i * 7 + 3) & 0xFF
	var big_frame := PMCWsFrame.encode(PMCWsFrame.OP_BINARY, payload, true, key)
	var d4 := PMCWsDecoder.new()
	var got4 := {}
	var pos := 0
	while pos < big_frame.size():
		var step := 7001 if pos % 2 == 0 else 3333
		d4.push(big_frame.slice(pos, pos + step))
		pos += step
		var e4 := d4.next()
		if not e4.is_empty():
			got4 = e4
	t.ok(got4.get("data") == payload, "chunked large masked frame decodes intact")
	t.eq(PMCWsFrame.close(1000, "x".repeat(200)).size(), 2 + 125, "close reason truncated to fit 125 bytes")
	t.ok(PMCWsFrame.is_valid_close_code(4000) and not PMCWsFrame.is_valid_close_code(1005) and not PMCWsFrame.is_valid_close_code(999), "close code validation")


func _wait_open(t, ws: WebSocketPeer) -> bool:
	return await t.wait_until(func() -> bool:
		ws.poll()
		return ws.get_ready_state() != WebSocketPeer.STATE_CONNECTING, 5.0) and ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func _next_packet(t, ws: WebSocketPeer, timeout := 10.0) -> Dictionary:
	var out := [{}]
	await t.wait_until(func() -> bool:
		ws.poll()
		if ws.get_available_packet_count() > 0:
			var pkt := ws.get_packet()
			out[0] = {"string": ws.was_string_packet(), "data": pkt}
			return true
		return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, timeout)
	return out[0]


func _next_json(t, ws: WebSocketPeer, timeout := 10.0) -> Dictionary:
	var p := await _next_packet(t, ws, timeout)
	if p.is_empty() or not p.string:
		return {}
	var d = JSON.parse_string(p.data.get_string_from_utf8())
	return d if d is Dictionary else {}


func _godot_client(t) -> void:
	t.section("Godot WebSocketPeer interop")
	var ws := WebSocketPeer.new()
	ws.inbound_buffer_size = 4 << 20
	ws.outbound_buffer_size = 4 << 20
	ws.max_queued_packets = 4096
	t.eq(ws.connect_to_url("ws://127.0.0.1:%d/pmc/ws" % port), OK, "connect_to_url")
	t.ok(await _wait_open(t, ws), "handshake completes")
	ws.send_text(JSON.stringify({"t": "pmc.hello", "sdk": 1, "name": "Godot"}))
	var welcome := await _next_json(t, ws)
	t.eq(welcome.get("t"), "pmc.welcome", "welcome")
	t.eq(welcome.get("name"), "Godot", "welcome name")

	ws.send_text(JSON.stringify({"t": "msg", "d": {"hello": [1, 2, 3], "s": "ünïcödé"}}))
	var echo := await _next_json(t, ws)
	t.eq(echo, {"t": "msg", "d": {"hello": [1, 2, 3], "s": "ünïcödé"}}, "text echo")

	var bin := PackedByteArray([0, 1, 2, 250, 251, 255])
	ws.send(bin, WebSocketPeer.WRITE_MODE_BINARY)
	var bp := await _next_packet(t, ws)
	t.ok(not bp.is_empty() and not bp.string and bp.data == bin, "binary echo")

	var big := PackedByteArray()
	big.resize(1 << 20)
	for i in big.size():
		big[i] = (i * 13) & 0xFF
	var t0 := Time.get_ticks_msec()
	host.reset_poll_stats()
	ws.send(big, WebSocketPeer.WRITE_MODE_BINARY)
	bp = await _next_packet(t, ws, 20.0)
	t.ok(not bp.is_empty() and bp.data == big, "1 MiB binary echo intact")
	t.note("1 MiB binary round trip %d ms, max host poll %.2f ms" % [Time.get_ticks_msec() - t0, host.get_stats().max_poll_usec / 1000.0])

	var big_text := "x".repeat((1 << 20) - 32)
	ws.send_text(JSON.stringify({"t": "msg", "d": big_text}))
	echo = await _next_json(t, ws, 20.0)
	t.ok(echo.get("d", "") == big_text, "~1 MiB text echo intact")

	# Heartbeat pings (every 0.25 s) are answered by WebSocketPeer, so the socket stays open.
	await t.wait_until(func() -> bool:
		ws.poll()
		return ws.get_ready_state() != WebSocketPeer.STATE_OPEN, 1.2)
	t.eq(ws.get_ready_state(), WebSocketPeer.STATE_OPEN, "socket survives heartbeats (pong)")
	ws.send_text(JSON.stringify({"t": "msg", "d": "after"}))
	echo = await _next_json(t, ws)
	t.eq(echo.get("d"), "after", "still echoing after heartbeats")

	# Oversize message is refused with 1009.
	var huge := PackedByteArray()
	huge.resize((1 << 20) + 1)
	ws.send(huge, WebSocketPeer.WRITE_MODE_BINARY)
	await t.wait_until(func() -> bool:
		ws.poll()
		return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, 10.0)
	t.eq(ws.get_close_code(), 1009, "oversize -> close 1009")

	# Clean close from client.
	var ws2 := WebSocketPeer.new()
	ws2.connect_to_url("ws://127.0.0.1:%d/pmc/ws" % port)
	await _wait_open(t, ws2)
	ws2.send_text(JSON.stringify({"t": "pmc.hello", "sdk": 1}))
	var w2 := await _next_json(t, ws2)
	var disconnected := [false]
	var on_disc := func(p: PMCPlayer) -> void:
		if p.id == int(w2.get("id", -1)):
			disconnected[0] = true
	host.player_disconnected.connect(on_disc)
	ws2.close(1000, "bye")
	await t.wait_until(func() -> bool:
		ws2.poll()
		return ws2.get_ready_state() == WebSocketPeer.STATE_CLOSED, 5.0)
	t.eq(ws2.get_close_code(), 1000, "close handshake echoes 1000")
	t.ok(await t.wait_until(func() -> bool: return disconnected[0], 2.0), "player_disconnected after client close")
	host.player_disconnected.disconnect(on_disc)


func _raw_protocol(t) -> void:
	t.section("raw client: control frames and fragmentation")
	var ws := PMCTestWs.new(t)
	t.ok(await ws.open(port), "raw upgrade")
	await ws.hello({"name": "raw"})
	t.ok(not (await ws.wait_json("pmc.welcome")).is_empty(), "raw welcome")

	await ws.send_frame(PMCWsFrame.OP_PING, "are you there".to_utf8_buffer())
	var pong := await ws.wait_event(func(e: Dictionary) -> bool: return e.op == "pong")
	t.eq(pong.get("data", PackedByteArray()).get_string_from_utf8(), "are you there", "pong echoes ping payload")

	var msg := JSON.stringify({"t": "msg", "d": "fragmented ✓ message"}).to_utf8_buffer()
	await ws.send_frame(PMCWsFrame.OP_TEXT, msg.slice(0, 5), false)
	await ws.send_frame(PMCWsFrame.OP_PING, PackedByteArray([1, 2]))  # control frame between fragments
	await ws.send_frame(PMCWsFrame.OP_CONTINUATION, msg.slice(5, 19), false)  # splits the UTF-8 check mark
	await ws.send_frame(PMCWsFrame.OP_CONTINUATION, msg.slice(19), true)
	var echo := await ws.wait_json("msg")
	t.eq(echo.get("d"), "fragmented ✓ message", "fragmented text reassembled")
	t.ok(not (await ws.wait_event(func(e: Dictionary) -> bool: return e.op == "pong")).is_empty(), "ping between fragments answered")

	var bin := PackedByteArray()
	bin.resize(200000)
	for i in bin.size():
		bin[i] = i % 251
	for i in 4:
		await ws.send_frame(PMCWsFrame.OP_BINARY if i == 0 else PMCWsFrame.OP_CONTINUATION, bin.slice(i * 50000, (i + 1) * 50000), i == 3)
	var be := await ws.wait_event(func(e: Dictionary) -> bool: return e.op == "binary")
	t.ok(be.get("data") == bin, "fragmented binary reassembled")

	await ws.send_frame(PMCWsFrame.OP_TEXT, PackedByteArray())
	await ws.send_frame(PMCWsFrame.OP_CLOSE, PackedByteArray([0x03, 0xE8]) + "done".to_utf8_buffer())
	t.eq(await ws.wait_close(), 1000, "server echoes close code 1000")
	t.ok(await ws.wait_socket_closed(3.0), "server closes TCP after close handshake")


func _expect_close(t, label: String, bytes: PackedByteArray, code: int, hello := true) -> void:
	var ws := PMCTestWs.new(t)
	if not await ws.open(port):
		t.fail("%s: upgrade failed" % label)
		return
	if hello:
		await ws.hello()
		await ws.wait_json("pmc.welcome")
	await ws.sock.send(bytes)
	t.eq(await ws.wait_close(3.0), code, label)
	t.ok(await ws.wait_socket_closed(3.0), "%s: socket closed" % label)


func _violations(t) -> void:
	t.section("protocol violations")
	var key := PackedByteArray([1, 2, 3, 4])
	var unmasked := PMCWsFrame.text("{\"t\":\"msg\",\"d\":1}")
	await _expect_close(t, "unmasked frame -> 1002", unmasked, 1002)
	var rsv := PMCWsFrame.encode(PMCWsFrame.OP_TEXT, "x".to_utf8_buffer(), true, key)
	rsv[0] |= 0x40
	await _expect_close(t, "RSV1 without extension -> 1002", rsv, 1002)
	await _expect_close(t, "unknown opcode -> 1002", PMCWsFrame.encode(3, PackedByteArray(), true, key), 1002)
	await _expect_close(t, "continuation without start -> 1002", PMCWsFrame.encode(0, "x".to_utf8_buffer(), true, key), 1002)
	await _expect_close(t, "new message during fragmentation -> 1002",
		PMCWsFrame.encode(1, "a".to_utf8_buffer(), false, key) + PMCWsFrame.encode(1, "b".to_utf8_buffer(), true, key), 1002)
	var long_ping := PackedByteArray()
	long_ping.resize(126)
	await _expect_close(t, "control frame > 125 -> 1002", PMCWsFrame.encode(PMCWsFrame.OP_PING, long_ping, true, key), 1002)
	await _expect_close(t, "fragmented ping -> 1002", PMCWsFrame.encode(PMCWsFrame.OP_PING, PackedByteArray(), false, key), 1002)
	await _expect_close(t, "invalid UTF-8 text -> 1007", PMCWsFrame.encode(1, PackedByteArray([0xC3, 0x28]), true, key), 1007)
	# 64-bit length header claiming 2 GiB: rejected before any payload arrives.
	var claim := PackedByteArray([0x82, 0xFF, 0, 0, 0, 0, 0x80, 0, 0, 0]) + key
	await _expect_close(t, "declared 2 GiB -> 1009", claim, 1009)
	var frag := PackedByteArray()
	var half := PackedByteArray()
	half.resize(600000)
	frag = PMCWsFrame.encode(2, half, false, key) + PMCWsFrame.encode(0, half, true, key)
	await _expect_close(t, "fragments over max -> 1009", frag, 1009)
	await _expect_close(t, "close code 999 -> 1002", PMCWsFrame.encode(8, PackedByteArray([0x03, 0xE7]), true, key), 1002)
	await _expect_close(t, "close with 1-byte payload -> 1002", PMCWsFrame.encode(8, PackedByteArray([3]), true, key), 1002)
	await _expect_close(t, "close with reserved code 1005 -> 1002", PMCWsFrame.encode(8, PackedByteArray([0x03, 0xED]), true, key), 1002)
	await _expect_close(t, "empty close -> empty close", PMCWsFrame.encode(8, PackedByteArray(), true, key), 1005)

	t.section("pre-hello and garbage")
	var before := PMCTestWs.new(t)
	await before.open(port)
	await before.send_frame(PMCWsFrame.OP_BINARY, PackedByteArray([1, 2, 3]))
	var rej := await before.wait_json("pmc.reject")
	t.eq(rej.get("code"), "bad_hello", "binary before hello -> reject bad_hello")
	t.eq(await before.wait_close(), 4000, "reject closes with 4000")

	var not_json := PMCTestWs.new(t)
	await not_json.open(port)
	await not_json.send_frame(PMCWsFrame.OP_TEXT, "not json".to_utf8_buffer())
	t.eq((await not_json.wait_json("pmc.reject")).get("code"), "bad_hello", "non-JSON first frame -> bad_hello")

	var silent := PMCTestWs.new(t)
	await silent.open(port)
	t.eq((await silent.wait_json("pmc.reject", 3.0)).get("code"), "bad_hello", "no hello within hello_timeout -> bad_hello")

	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for round in 5:
		var g := PMCTestWs.new(t)
		await g.open(port)
		var junk := PackedByteArray()
		junk.resize(4096)
		for i in junk.size():
			junk[i] = rng.randi() % 256
		await g.sock.send(junk)
		t.ok(await g.wait_socket_closed(4.0), "random garbage frames round %d -> socket closed" % round)

	var partial := PMCTestWs.new(t)
	await partial.open(port)
	await partial.sock.send(PackedByteArray([0x81, 0xFE, 0x10]))  # truncated extended length
	partial.close()
	var partial2 := PMCTestSocket.new(t)
	await partial2.connect_to(port)
	await partial2.send("GET /pmc/ws HTTP/1.1\r\nUpgrade: websocket\r\n")
	partial2.close()
	await t.wait(0.2)
	t.ok(host.is_running(), "partial frames / headers then disconnect: host fine")
