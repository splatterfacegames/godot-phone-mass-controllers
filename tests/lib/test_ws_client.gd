class_name PMCTestWs
extends RefCounted
## Minimal masked WebSocket client over [PMCTestSocket] for protocol tests.

var sock: PMCTestSocket
var dec := PMCWsDecoder.new()
var events: Array[Dictionary] = []
var handshake_ok := false
var close_code := -1
var close_reason := ""
## Answer server pings automatically (like a browser). Turn off to simulate a dead peer.
var auto_pong := true
var _t
var _crypto := Crypto.new()


func _init(t) -> void:
	_t = t
	sock = PMCTestSocket.new(t)
	dec.require_mask = false
	dec.max_message_bytes = 64 << 20


## Connects and performs the upgrade on [param path]. Returns true on 101.
## [param extra_headers]: raw header lines, each ending in CRLF (e.g. "CF-Connecting-IP: 1.2.3.4\r\n").
func open(port: int, path := "/pmc/ws", extra_headers := "") -> bool:
	if not await sock.connect_to(port):
		return false
	var key := Marshalls.raw_to_base64(_crypto.generate_random_bytes(16))
	await sock.send("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n" % [path, key, extra_headers])
	var holder := [{}]
	await sock.wait_for(func(s) -> bool:
		holder[0] = PMCTestSocket.parse_response(s.buf)
		return not holder[0].is_empty() or s.closed)
	var resp: Dictionary = holder[0]
	if resp.is_empty() or resp.status != 101:
		return false
	if resp.headers.get("sec-websocket-accept", "") != PMCWsFrame.accept_key(key):
		return false
	sock.take(resp.consumed)
	handshake_ok = true
	return true


## Sends a masked frame.
func send_frame(opcode: int, payload: PackedByteArray, fin := true) -> void:
	await sock.send(PMCWsFrame.encode(opcode, payload, fin, _crypto.generate_random_bytes(4)))


## Sends a masked text frame with JSON of [param obj].
func send_json(obj) -> void:
	await send_frame(PMCWsFrame.OP_TEXT, JSON.stringify(obj).to_utf8_buffer())


## Sends a pmc.hello with optional extra fields.
func hello(extra := {}) -> void:
	var m := {"t": "pmc.hello", "sdk": 1}
	m.merge(extra, true)
	await send_json(m)


func _drain() -> void:
	sock.pump()
	if sock.buf.size() > 0:
		dec.push(sock.buf)
		sock.buf = PackedByteArray()
	while true:
		var ev := dec.next()
		if ev.is_empty():
			break
		if ev.op == "close":
			close_code = ev.code
			close_reason = ev.reason
		if ev.op == "ping" and auto_pong:
			sock.send(PMCWsFrame.encode(PMCWsFrame.OP_PONG, ev.data, true, _crypto.generate_random_bytes(4)))
			continue
		events.append(ev)


## Waits for the first event matching [param pred] (called with the event dictionary), removes it and returns it,
## or returns {} on timeout.
func wait_event(pred: Callable, timeout := 5.0) -> Dictionary:
	var found := [{}]
	await _t.wait_until(func() -> bool:
		_drain()
		for i in events.size():
			if pred.call(events[i]):
				found[0] = events[i]
				events.remove_at(i)
				return true
		return false, timeout)
	return found[0]


## Waits for a JSON text message with [code]t == type[/code]. Returns the parsed dictionary or {}.
func wait_json(type: String, timeout := 5.0) -> Dictionary:
	var ev := await wait_event(func(e: Dictionary) -> bool:
		if e.op != "text":
			return false
		var d = JSON.parse_string(e.data)
		return d is Dictionary and d.get("t") == type, timeout)
	return JSON.parse_string(ev.data) if not ev.is_empty() else {}


## Waits for the server's close frame. Returns its code (-1 on timeout).
func wait_close(timeout := 5.0) -> int:
	var ev := await wait_event(func(e: Dictionary) -> bool: return e.op == "close" or e.op == "error", timeout)
	return ev.get("code", -1)


## Waits until the TCP connection is closed by the server.
func wait_socket_closed(timeout := 5.0) -> bool:
	return await _t.wait_until(func() -> bool:
		_drain()
		return sock.closed, timeout)


func close() -> void:
	sock.close()
