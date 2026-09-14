class_name PMCTestSocket
extends RefCounted
## Raw TCP client for tests: connects, sends bytes, and buffers what it receives while test frames pump.

var peer := StreamPeerTCP.new()
var buf := PackedByteArray()
var closed := false
var _t


func _init(t) -> void:
	_t = t


## Connects to 127.0.0.1:[param port]. Returns true once connected.
func connect_to(port: int, timeout := 5.0) -> bool:
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return false
	var ok: bool = await _t.wait_until(func() -> bool:
		peer.poll()
		return peer.get_status() != StreamPeerTCP.STATUS_CONNECTING, timeout)
	peer.set_no_delay(true)
	return ok and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


## Sends a String (UTF-8) or PackedByteArray, blocking until it's all written.
func send(data) -> void:
	var bytes: PackedByteArray = data.to_utf8_buffer() if data is String else data
	var off := 0
	while off < bytes.size():
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			closed = true
			return
		var r := peer.put_partial_data(bytes.slice(off, mini(bytes.size(), off + 65536)))
		if r[0] != OK:
			closed = true
			return
		off += r[1]
		if r[1] == 0:
			pump()
			await _t.frame()


## Reads whatever is available into [member buf].
func pump() -> void:
	if closed:
		return
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		closed = true
		return
	var n := peer.get_available_bytes()
	if n > 0:
		var r := peer.get_partial_data(n)
		if r[0] == OK:
			buf.append_array(r[1])


## Pumps frames until [param cond] (called with this socket) is true or the timeout passes.
func wait_for(cond: Callable, timeout := 5.0) -> bool:
	return await _t.wait_until(func() -> bool:
		pump()
		return cond.call(self), timeout)


## Waits until the peer closes the connection.
func wait_closed(timeout := 5.0) -> bool:
	return await wait_for(func(s) -> bool: return s.closed, timeout)


## Takes [param n] bytes from the front of [member buf].
func take(n: int) -> PackedByteArray:
	var out := buf.slice(0, n)
	buf = buf.slice(n)
	return out


func close() -> void:
	peer.disconnect_from_host()
	closed = true


## Parses one HTTP response from the front of [param data]. Returns {} if incomplete, else
## {status, headers (lower-case), body, consumed}. [param head_only]: the response has no body (HEAD).
static func parse_response(data: PackedByteArray, head_only := false) -> Dictionary:
	var ends := PMCHttpParser.find_head_end(data, 0, 1 << 20)
	if ends[0] < 0:
		return {}
	var head := data.slice(0, ends[0]).get_string_from_ascii()
	var lines := head.split("\n")
	var status_parts := lines[0].strip_edges().split(" ")
	var headers := {}
	for i in range(1, lines.size()):
		var l := lines[i].strip_edges()
		var c := l.find(":")
		if c > 0:
			headers[l.substr(0, c).to_lower()] = l.substr(c + 1).strip_edges()
	var status := status_parts[1].to_int() if status_parts.size() > 1 else 0
	var len := 0
	if not head_only and status != 101 and status != 204 and status != 304:
		len = String(headers.get("content-length", "0")).to_int()
	if data.size() < ends[1] + len:
		return {}
	return {"status": status, "headers": headers, "body": data.slice(ends[1], ends[1] + len), "consumed": ends[1] + len}


## Sends [param raw] and waits for [param count] responses. Returns an Array of response dictionaries
## (possibly fewer on timeout or close). [param head_flags]: per-response HEAD flags.
func http(raw, count := 1, timeout := 5.0, head_flags: Array = []) -> Array:
	await send(raw)
	var out: Array = []
	await wait_for(func(s) -> bool:
		while out.size() < count:
			var r := parse_response(s.buf, head_flags[out.size()] if out.size() < head_flags.size() else false)
			if r.is_empty():
				break
			s.take(r.consumed)
			out.append(r)
		return out.size() >= count or s.closed, timeout)
	# Catch a response that arrived together with the close.
	while out.size() < count:
		var r := parse_response(buf, head_flags[out.size()] if out.size() < head_flags.size() else false)
		if r.is_empty():
			break
		take(r.consumed)
		out.append(r)
	return out


## One-shot GET helper on a fresh connection. Returns the response dictionary or {}.
static func get_url(t, port: int, path: String, extra_headers := "") -> Dictionary:
	var s := PMCTestSocket.new(t)
	if not await s.connect_to(port):
		return {}
	var rs: Array = await s.http("GET %s HTTP/1.1\r\nHost: test\r\nConnection: close\r\n%s\r\n" % [path, extra_headers])
	s.close()
	return rs[0] if rs.size() > 0 else {}
