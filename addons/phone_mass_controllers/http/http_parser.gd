class_name PMCHttpParser
extends RefCounted
## HTTP/1.x request-head parsing helpers. Internal. Pure functions, no I/O.

const _TCHAR := "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


## Finds the end of the header block in [param buf], starting at [param from] (and scanning at most
## [param limit] bytes). Returns [code][head_end, body_start][/code], or [code][-1, -1][/code] if it isn't complete yet.
## Accepts CRLF CRLF, and bare LF LF for lenient clients.
static func find_head_end(buf: PackedByteArray, from: int, limit: int) -> Array[int]:
	var end := mini(buf.size(), from + limit)
	var i := buf.find(10, from)
	while i >= 0 and i < end:
		# i points at a LF. Check for LF LF or CRLF CRLF ending here.
		if i + 1 < buf.size() and buf[i + 1] == 10:
			return [i, i + 2]
		if i + 2 < buf.size() and buf[i + 1] == 13 and buf[i + 2] == 10:
			return [i, i + 3]
		i = buf.find(10, i + 1)
	return [-1, -1]


## Parses the request line plus headers (the text before the blank line).
## Returns [code]{"ok": true, "request": PMCHttpRequest}[/code] or [code]{"ok": false, "status": int, "reason": String}[/code].
static func parse_head(head: String) -> Dictionary:
	var lines := head.split("\n")
	for i in lines.size():
		if lines[i].ends_with("\r"):
			lines[i] = lines[i].left(-1)
	# RFC 9112 2.2: ignore at least one empty line before the request line.
	while lines.size() > 0 and lines[0] == "":
		lines.remove_at(0)
	if lines.is_empty():
		return _err(400, "empty request")
	var parts := lines[0].split(" ")
	if parts.size() != 3:
		return _err(400, "malformed request line")
	var req := PMCHttpRequest.new()
	req.method = parts[0]
	req.target = parts[1]
	req.version = parts[2]
	if req.method == "" or not _is_token(req.method):
		return _err(400, "bad method")
	if req.version != "HTTP/1.1" and req.version != "HTTP/1.0":
		if req.version.begins_with("HTTP/"):
			return _err(505, "unsupported HTTP version")
		return _err(400, "bad version")
	if req.target.length() > 8192:
		return _err(414, "URI too long")

	var target := req.target
	if target.begins_with("http://") or target.begins_with("https://"):
		var after := target.find("/", target.find("//") + 2)
		target = "/" if after < 0 else target.substr(after)
	if not target.begins_with("/"):
		return _err(400, "bad request target")
	for c in target:
		var u := c.unicode_at(0)
		if u <= 32 or u >= 127:
			return _err(400, "bad character in target")
	var hash := target.find("#")
	if hash >= 0:
		target = target.substr(0, hash)
	var q := target.find("?")
	req.raw_path = target if q < 0 else target.substr(0, q)
	req.query_string = "" if q < 0 else target.substr(q + 1)
	var decoded = percent_decode(req.raw_path, false)
	if decoded == null:
		return _err(400, "bad percent-encoding")
	req.path = decoded
	req.query = parse_query(req.query_string)

	for i in range(1, lines.size()):
		var line := lines[i]
		if line == "":
			continue
		if line[0] == " " or line[0] == "\t":
			return _err(400, "obsolete header folding")
		var colon := line.find(":")
		if colon <= 0:
			return _err(400, "malformed header")
		var name := line.substr(0, colon)
		if not _is_token(name):
			return _err(400, "bad header name")
		var value := line.substr(colon + 1).strip_edges()
		var key := name.to_lower()
		if req.headers.has(key):
			if key == "content-length" or key == "host":
				if req.headers[key] != value:
					return _err(400, "conflicting %s" % key)
				continue
			req.headers[key] = req.headers[key] + ", " + value
		else:
			req.headers[key] = value
	if req.version == "HTTP/1.1" and not req.headers.has("host"):
		return _err(400, "missing Host header")
	return {"ok": true, "request": req}


## Percent-decodes [param s] as UTF-8. Returns [code]null[/code] for malformed escapes, invalid UTF-8,
## or (in paths) encoded NUL. When [param plus_is_space] is set, [code]+[/code] becomes a space (query strings).
static func percent_decode(s: String, plus_is_space: bool):
	if s.find("%") < 0 and (not plus_is_space or s.find("+") < 0):
		return s
	var out := PackedByteArray()
	var src := s.to_utf8_buffer()
	var i := 0
	var n := src.size()
	while i < n:
		var c := src[i]
		if c == 37:  # %
			if i + 2 >= n:
				return null
			var hi := _hex(src[i + 1])
			var lo := _hex(src[i + 2])
			if hi < 0 or lo < 0:
				return null
			var v := hi * 16 + lo
			if v == 0:
				return null
			out.append(v)
			i += 3
		elif c == 43 and plus_is_space:
			out.append(32)
			i += 1
		else:
			out.append(c)
			i += 1
	var text := out.get_string_from_utf8()
	if text.to_utf8_buffer() != out:
		return null
	return text


## Parses [code]a=1&b=x%20y[/code] into a Dictionary. Malformed pairs are skipped.
static func parse_query(qs: String) -> Dictionary:
	var d := {}
	if qs == "":
		return d
	for pair in qs.split("&", false):
		var eq := pair.find("=")
		var k = percent_decode(pair if eq < 0 else pair.substr(0, eq), true)
		var v = "" if eq < 0 else percent_decode(pair.substr(eq + 1), true)
		if k == null or v == null:
			continue
		d[k] = v
	return d


static func _hex(c: int) -> int:
	if c >= 48 and c <= 57:
		return c - 48
	if c >= 97 and c <= 102:
		return c - 87
	if c >= 65 and c <= 70:
		return c - 55
	return -1


static func _is_token(s: String) -> bool:
	for c in s:
		if _TCHAR.find(c) < 0:
			return false
	return true


static func _err(status: int, reason: String) -> Dictionary:
	return {"ok": false, "status": status, "reason": reason}
