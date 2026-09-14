class_name PMCIoWorker
extends RefCounted
## Optional socket-I/O thread for [PMCHost] ([member PMCHost.io_thread_enabled]).
##
## The worker owns accept, read, write and HTTP/WS frame decode for the connections it is handed via
## [method add_conn]. Complete events go to [member events] under [member mutex]; the main thread drains
## them in [method PMCHost.poll] and runs all game logic and signals there. Per-connection output crosses
## the other way through [member PMCConnection.io_mutex].
##
## Event kinds:
## [code]{"kind": "accept", "peer": StreamPeerTCP}[/code] — a newly accepted socket (untouched by the worker
##   after this; the host either disconnects it or hands a [PMCConnection] back via [method add_conn]);
## [code]{"kind": "http", "conn": c, "request": PMCHttpRequest}[/code];
## [code]{"kind": "http_error", "conn": c, "status": int, "reason": String}[/code];
## [code]{"kind": "ws", "conn": c, "ev": Dictionary}[/code] — a decoded [PMCWsDecoder] event.
## Closed sockets are reported implicitly: the worker sets [code]conn.mode[/code] to CLOSED and drops the
## connection; the host reaps it and emits its signals.

## Complete events for the main thread (guarded by [member mutex]).
var events: Array = []
## Connections to start servicing (guarded by [member mutex]).
var cmds: Array = []
## Guards [member events], [member cmds], [member stop], [member bytes_in] and [member bytes_out].
var mutex := Mutex.new()
## Set under [member mutex] to end [method run].
var stop := false
## The listening socket. Written before the thread starts; read by the worker only.
var server: TCPServer = null
## Bytes read since the last drain (guarded by [member mutex]).
var bytes_in := 0
## Bytes written since the last drain (guarded by [member mutex]).
var bytes_out := 0

# Snapshots of the host limits, taken at start() — tune them before the thread runs.
var max_header_bytes := 16384
var max_body_bytes := 65536
var max_message_bytes := 1 << 20

const _ACCEPT_CAP := 64
const _HTTP_REQ_CAP := 16
const _WS_EV_CAP := 256
const _READ_CAP := 262144
const _WRITE_CAP := 1 << 20
const _STATUS_EVERY_FRAMES := 15

var _conns: Array[PMCConnection] = []
var _pending: Array = []
var _bi := 0
var _bo := 0


## Host-side: hands an accepted connection to the worker.
func add_conn(c: PMCConnection) -> void:
	mutex.lock()
	cmds.append(c)
	mutex.unlock()


## The thread body. Loops until [member stop] is set.
func run() -> void:
	var frame := 0
	while true:
		mutex.lock()
		var done := stop
		var new_conns := cmds
		cmds = []
		mutex.unlock()
		if done:
			return
		for c: PMCConnection in new_conns:
			_conns.append(c)

		var did := false
		var now := Time.get_ticks_msec()
		frame += 1
		var accepted := 0
		while server != null and server.is_connection_available() and accepted < _ACCEPT_CAP:
			var peer := server.take_connection()
			if peer == null:
				break
			accepted += 1
			did = true
			_pending.append({"kind": "accept", "peer": peer})

		var i := 0
		while i < _conns.size():
			var c := _conns[i]
			if c.mode == PMCConnection.Mode.CLOSED:
				_conns.remove_at(i)
				continue
			if _service(c, now, frame):
				did = true
			if c.mode == PMCConnection.Mode.CLOSED:
				_conns.remove_at(i)
			else:
				i += 1

		mutex.lock()
		events.append_array(_pending)
		_pending.clear()
		bytes_in += _bi
		bytes_out += _bo
		mutex.unlock()
		_bi = 0
		_bo = 0
		if not did:
			OS.delay_msec(1)


# Returns true when the connection did work worth another pass without sleeping.
func _service(c: PMCConnection, now: int, frame: int) -> bool:
	var did := false
	c.io_mutex.lock()
	var want_close := c.close_requested
	if c.upgrade_pending:
		c.apply_upgrade()
	c.io_mutex.unlock()
	if want_close:
		c.close_now(c.close_reason)
		return true
	# The status check is a select() call, so it's staggered like the main-thread service loop.
	if (frame + c.slot) % _STATUS_EVERY_FRAMES == 0:
		if not c.poll_status():
			return true
	var avail := c.peer.get_available_bytes()
	if avail < 0:
		if not c.poll_status():
			return true
		avail = 0
	if c.mode == PMCConnection.Mode.HTTP:
		if avail > 0 and not c.close_after_flush and c._in.size() - c._in_off < max_header_bytes + max_body_bytes + 8:
			var n := c.read(_READ_CAP, now)
			_bi += n
			did = did or n > 0
		var handled := 0
		while c.mode == PMCConnection.Mode.HTTP and not c.close_after_flush and not c.upgrade_pending \
				and not c.is_streaming() and c.out_pending() < _WRITE_CAP and handled < _HTTP_REQ_CAP:
			var r := c.next_http_request(max_header_bytes, max_body_bytes)
			if r.is_empty():
				break
			handled += 1
			did = true
			if r.has("error"):
				_pending.append({"kind": "http_error", "conn": c, "status": r.error, "reason": r.reason})
				break
			_pending.append({"kind": "http", "conn": c, "request": r.request})
		c.io_partial_in = c.buffered_in() > 0 or c.awaiting_body()
		if handled >= _HTTP_REQ_CAP:
			did = true
	elif c.mode == PMCConnection.Mode.WS:
		if avail > 0 and c.ws.buffered() < max_message_bytes + 16:
			var n := c.read(_READ_CAP, now)
			_bi += n
			did = did or n > 0
		var count := 0
		while c.is_open():
			if count >= _WS_EV_CAP:
				did = true
				break
			var ev := c.ws.next()
			if ev.is_empty():
				break
			count += 1
			did = true
			_pending.append({"kind": "ws", "conn": c, "ev": ev})
	var n_out := c.flush(_WRITE_CAP)
	_bo += n_out
	return did or n_out > 0
