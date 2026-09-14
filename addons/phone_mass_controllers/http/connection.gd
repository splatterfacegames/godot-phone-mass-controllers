class_name PMCConnection
extends RefCounted
## One accepted TCP connection: HTTP/1.1 (keep-alive), or WebSocket after an upgrade. Internal to [PMCHost].
##
## Keeps non-blocking read/write buffers and streams file bodies in chunks.

## Connection mode.
enum Mode { HTTP, WS, CLOSED }

## Largest single socket write / file chunk.
const CHUNK := 65536

## The socket.
var peer: StreamPeerTCP
## Current mode.
var mode := Mode.HTTP
## Peer IP.
var remote_address := ""
## Peer port.
var remote_port := 0
## Accept time (ticks msec).
var accepted_msec := 0
## Last time bytes arrived.
var last_rx_msec := 0
## Last time bytes were written (or output became pending).
var last_tx_msec := 0
## Close the socket once all queued output is written.
var close_after_flush := false
## Why the connection closed (diagnostics).
var close_reason := ""

# HTTP
## When the host started waiting for the current request head.
var head_started_msec := 0
var _pending_req: PMCHttpRequest = null
var _pending_body_len := 0

# WebSocket
## Frame decoder (WS mode only).
var ws: PMCWsDecoder = null
## Attached player id (0 = none, e.g. before hello).
var player_id := 0
## Deadline for the pmc.hello frame.
var hello_deadline_msec := 0
## Heartbeat pings sent without any inbound frame since.
var pings_unanswered := 0
## Next heartbeat tick.
var next_ping_msec := 0
## Whether we've sent a close frame.
var close_sent := false
## When to drop the socket if the peer doesn't finish the close handshake.
var close_deadline_msec := 0
## Failed admin auth attempts on this connection.
var auth_failures := 0
## Auth lockout end (ticks msec).
var auth_locked_until_msec := 0
## A pmc.reject was sent. Later frames are ignored.
var rejected := false
## Decoded events may remain (per-poll event cap reached, or bytes carried over from the upgrade).
var ws_more := false
## Stagger slot for periodic status checks.
var slot := 0
## Client address used for per-address limits: the peer IP, or CF-Connecting-IP behind the tunnel.
var client_address := ""
## Address this connection is counted under in the host's per-address table ("" if not counted).
var counted_address := ""

var _in := PackedByteArray()
var _in_off := 0
var _out := PackedByteArray()
var _out_off := 0
var _file: FileAccess = null
var _file_remaining := 0


func _init(p_peer: StreamPeerTCP, now_msec: int) -> void:
	peer = p_peer
	peer.set_no_delay(true)
	remote_address = peer.get_connected_host()
	remote_port = peer.get_connected_port()
	client_address = remote_address
	accepted_msec = now_msec
	last_rx_msec = now_msec
	last_tx_msec = now_msec
	head_started_msec = now_msec


## Whether the socket is still usable.
func is_open() -> bool:
	return mode != Mode.CLOSED


## Updates the socket status. Returns false if the peer has gone away.
func poll_status() -> bool:
	if mode == Mode.CLOSED:
		return false
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		close_now("peer closed")
		return false
	return true


## Bytes queued but not yet written (excluding the rest of a streamed file).
func out_pending() -> int:
	return _out.size() - _out_off


## Whether any output (bytes or a file) is still pending.
func has_pending_output() -> bool:
	return _out.size() > _out_off or _file != null


## Whether a file body is being streamed.
func is_streaming() -> bool:
	return _file != null


## Bytes received but not yet consumed.
func buffered_in() -> int:
	if mode == Mode.WS and ws != null:
		return ws.buffered()
	return _in.size() - _in_off


## Queues bytes for sending.
func queue(bytes: PackedByteArray) -> void:
	if mode == Mode.CLOSED or bytes.is_empty():
		return
	if _out_off == _out.size():
		_out = bytes  # Packed arrays are copy-on-write, so sharing one broadcast frame is free.
		_out_off = 0
		last_tx_msec = Time.get_ticks_msec()
	else:
		_out.append_array(bytes)


## Streams [param length] bytes from the already-positioned [param file] after the queued bytes.
func start_file(file: FileAccess, length: int) -> void:
	_file = file
	_file_remaining = length
	last_tx_msec = Time.get_ticks_msec()


## Writes up to [param max_bytes]. Returns the bytes written.
func flush(max_bytes: int) -> int:
	var written := 0
	while mode != Mode.CLOSED and written < max_bytes:
		if _out_off >= _out.size():
			if _file == null:
				break
			var n := mini(CHUNK, _file_remaining)
			var chunk := _file.get_buffer(n)
			if chunk.size() == 0 and n > 0:
				close_now("file read error")
				break
			_file_remaining -= chunk.size()
			if _file_remaining <= 0:
				_file.close()
				_file = null
			_out = chunk
			_out_off = 0
		var end := mini(_out.size(), _out_off + mini(CHUNK, max_bytes - written))
		var piece := _out if (_out_off == 0 and end == _out.size()) else _out.slice(_out_off, end)
		var r := peer.put_partial_data(piece)
		if r[0] != OK:
			close_now("write error")
			break
		var sent: int = r[1]
		if sent > 0:
			last_tx_msec = Time.get_ticks_msec()
		written += sent
		_out_off += sent
		if _out_off >= _out.size():
			_out = PackedByteArray()
			_out_off = 0
		elif _out_off > 1 << 20 and _out_off * 2 > _out.size():
			_out = _out.slice(_out_off)
			_out_off = 0
		if sent < piece.size():
			break
	if mode != Mode.CLOSED and close_after_flush and not has_pending_output():
		close_now("done")
	return written


## Reads up to [param max_bytes] available bytes into the input (or WS decoder) buffer. Returns the bytes read.
func read(max_bytes: int, now_msec: int) -> int:
	if mode == Mode.CLOSED or max_bytes <= 0:
		return 0
	var avail := peer.get_available_bytes()
	if avail <= 0:
		return 0
	var r := peer.get_partial_data(mini(avail, max_bytes))
	if r[0] != OK:
		close_now("read error")
		return 0
	var data: PackedByteArray = r[1]
	if data.is_empty():
		return 0
	last_rx_msec = now_msec
	if mode == Mode.WS:
		ws.push(data)
	elif _in_off == _in.size():
		_in = data
		_in_off = 0
	else:
		_in.append_array(data)
	return data.size()


## Extracts the next complete HTTP request.
## Returns [code]{}[/code] if incomplete, [code]{"request": PMCHttpRequest}[/code], or [code]{"error": int, "reason": String}[/code].
func next_http_request(max_header_bytes: int, max_body_bytes: int) -> Dictionary:
	if _pending_req != null:
		if _in.size() - _in_off < _pending_body_len:
			return {}
		var req := _pending_req
		req.body = _in.slice(_in_off, _in_off + _pending_body_len)
		_in_off += _pending_body_len
		_pending_req = null
		_pending_body_len = 0
		_compact_in()
		return {"request": req}
	var avail := _in.size() - _in_off
	if avail == 0:
		return {}
	var ends := PMCHttpParser.find_head_end(_in, _in_off, max_header_bytes + 4)
	if ends[0] < 0:
		if avail > max_header_bytes:
			return {"error": 431, "reason": "request header too large"}
		return {}
	if ends[0] - _in_off > max_header_bytes:
		return {"error": 431, "reason": "request header too large"}
	var head := _in.slice(_in_off, ends[0]).get_string_from_ascii()
	_in_off = ends[1]
	_compact_in()
	var res := PMCHttpParser.parse_head(head)
	if not res.ok:
		return {"error": res.status, "reason": res.reason}
	var req: PMCHttpRequest = res.request
	req.remote_address = remote_address
	req.remote_port = remote_port
	if req.headers.has("transfer-encoding"):
		return {"error": 501, "reason": "chunked request bodies are not supported"}
	var cl := req.header("content-length")
	if cl != "":
		var digits := cl.length() <= 18
		for ch in cl:
			if ch < "0" or ch > "9":
				digits = false
				break
		if not digits:
			return {"error": 400, "reason": "bad Content-Length"}
		var n := cl.to_int()
		if n > max_body_bytes:
			return {"error": 413, "reason": "request body too large"}
		if n > 0:
			_pending_req = req
			_pending_body_len = n
			return next_http_request(max_header_bytes, max_body_bytes)
	return {"request": req}


## Whether a request body is still being received.
func awaiting_body() -> bool:
	return _pending_req != null


## Switches to WebSocket mode. Bytes already buffered after the upgrade request go to the decoder.
func upgrade_to_ws(max_message_bytes: int, now_msec: int, hello_timeout_msec: int, heartbeat_msec: int) -> void:
	mode = Mode.WS
	ws = PMCWsDecoder.new()
	ws.max_message_bytes = max_message_bytes
	if _in.size() > _in_off:
		ws.push(_in.slice(_in_off))
		ws_more = true
	_in = PackedByteArray()
	_in_off = 0
	hello_deadline_msec = now_msec + hello_timeout_msec
	next_ping_msec = now_msec + heartbeat_msec


## Closes the socket immediately.
func close_now(reason := "") -> void:
	if mode == Mode.CLOSED:
		return
	mode = Mode.CLOSED
	close_reason = reason
	if _file != null:
		_file.close()
		_file = null
	_out = PackedByteArray()
	_out_off = 0
	_in = PackedByteArray()
	_in_off = 0
	peer.disconnect_from_host()


func _compact_in() -> void:
	if _in_off >= _in.size():
		_in = PackedByteArray()
		_in_off = 0
	elif _in_off > 32768 and _in_off * 2 > _in.size():
		_in = _in.slice(_in_off)
		_in_off = 0
