@tool
class_name PMCTunnelTestResponder
extends Node
## Tiny HTTP responder used to smoke-test a tunnel without a running game.
##
## Answers [code]GET /pmc/healthz[/code] with [code]ok[/code] and every other path with a small HTML page.
## One request per connection ([code]Connection: close[/code]). Works in the editor ([code]@tool[/code]).

## Emitted for every request served, with the request path.
signal request_served(path: String)

## Page title shown at "/".
var page_title := "Phone Mass Controllers: tunnel test"

var _server: TCPServer
var _port := 0
var _clients: Array[Dictionary] = []


## Listens on 127.0.0.1, trying [param port] then the next [param search] ports. Returns the bound port, or 0.
func listen(port := 8090, search := 20) -> int:
	close()
	for p in range(port, port + search + 1):
		var s := TCPServer.new()
		if s.listen(p, "127.0.0.1") == OK:
			_server = s
			_port = p
			set_process(true)
			return p
	return 0


## The bound port (0 when closed).
func get_port() -> int:
	return _port


## Stops listening and drops open connections.
func close() -> void:
	if _server != null:
		_server.stop()
		_server = null
	for c in _clients:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	_port = 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		close()


func _process(_delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buf": PackedByteArray(), "t": Time.get_ticks_msec()})
	for i in range(_clients.size() - 1, -1, -1):
		var c: Dictionary = _clients[i]
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - int(c.t) > 10000:
			peer.disconnect_from_host()
			_clients.remove_at(i)
			continue
		var buf: PackedByteArray = c.buf
		var avail := peer.get_available_bytes()
		if avail > 0:
			var got := peer.get_data(mini(avail, 16384))
			if got[0] == OK:
				buf.append_array(got[1])
				c.buf = buf
		var text := buf.get_string_from_ascii()
		var end := text.find("\r\n\r\n")
		if end < 0:
			if buf.size() > 16384:
				peer.disconnect_from_host()
				_clients.remove_at(i)
			continue
		var request_line := text.substr(0, text.find("\r\n")).split(" ")
		var path := request_line[1] if request_line.size() > 1 else "/"
		var q := path.find("?")
		if q >= 0:
			path = path.substr(0, q)
		var head := request_line[0] == "HEAD"
		var body: PackedByteArray
		var ctype := "text/html; charset=utf-8"
		if path == "/pmc/healthz":
			body = "ok".to_utf8_buffer()
			ctype = "text/plain; charset=utf-8"
		else:
			body = ("<!doctype html><meta name=viewport content='width=device-width'><title>%s</title><h1>%s</h1><p>If you can read this on your phone, the tunnel works.</p>" % [page_title, page_title]).to_utf8_buffer()
		var header := "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" % [ctype, body.size()]
		peer.put_data(header.to_utf8_buffer())
		if not head:
			peer.put_data(body)
		peer.disconnect_from_host()
		_clients.remove_at(i)
		request_served.emit(path)
