class_name PMCHttpResponse
extends RefCounted
## An HTTP response returned from a [method PMCHost.add_route] handler, or built by the host.
##
## Use the static constructors ([method text], [method json], [method bytes], [method file], [method error],
## [method redirect]) and chain [method set_header]. File responses are streamed in chunks, so a large
## file doesn't block the frame.

## Status code.
var status := 200
## Response headers (name -> value). [code]Content-Length[/code] and [code]Connection[/code] are set by the host.
var headers: Dictionary = {}
## In-memory body. Ignored when [member file_path] is set.
var body := PackedByteArray()
## When non-empty, the body is streamed from this file (res://, user:// or an absolute path).
var file_path := ""
## Byte offset into [member file_path] to start streaming from.
var file_offset := 0
## Bytes to stream from [member file_path]. [code]-1[/code] means to the end of the file.
var file_length := -1


## Sets a header and returns [code]self[/code] for chaining.
func set_header(name: String, value: String) -> PMCHttpResponse:
	for k in headers.keys():
		if String(k).to_lower() == name.to_lower():
			headers.erase(k)
	headers[name] = value
	return self


## Returns a header value (case-insensitive), or [code]""[/code].
func get_header(name: String) -> String:
	for k in headers:
		if String(k).to_lower() == name.to_lower():
			return headers[k]
	return ""


## A UTF-8 text response.
static func text(content: String, code := 200, content_type := "text/plain; charset=utf-8") -> PMCHttpResponse:
	var r := PMCHttpResponse.new()
	r.status = code
	r.body = content.to_utf8_buffer()
	r.headers["Content-Type"] = content_type
	return r


## An HTML response with [code]Cache-Control: no-cache[/code].
static func html(content: String, code := 200) -> PMCHttpResponse:
	return text(content, code, "text/html; charset=utf-8").set_header("Cache-Control", "no-cache")


## A JSON response ([code]JSON.stringify(data)[/code]) with [code]Cache-Control: no-cache[/code].
static func json(data, code := 200) -> PMCHttpResponse:
	return text(JSON.stringify(data), code, "application/json; charset=utf-8").set_header("Cache-Control", "no-cache")


## A binary response.
static func bytes(data: PackedByteArray, content_type := "application/octet-stream", code := 200) -> PMCHttpResponse:
	var r := PMCHttpResponse.new()
	r.status = code
	r.body = data
	r.headers["Content-Type"] = content_type
	return r


## A streamed file response. Returns [code]null[/code] if the file can't be opened. The MIME type comes from
## the extension. Use [method PMCStaticFiles.file_response] if you also want Range support.
static func file(path: String, content_type := "") -> PMCHttpResponse:
	if not FileAccess.file_exists(path):
		return null
	var r := PMCHttpResponse.new()
	r.file_path = path
	r.headers["Content-Type"] = content_type if content_type != "" else PMCStaticFiles.mime_for(path)
	if PMCStaticFiles.is_no_cache(path):
		r.headers["Cache-Control"] = "no-cache"
	return r


## A plain-text error page for [param code].
static func error(code: int, message := "") -> PMCHttpResponse:
	var msg := message if message != "" else status_text(code)
	return text("%d %s\n" % [code, msg], code)


## A redirect to [param location].
static func redirect(location: String, code := 302) -> PMCHttpResponse:
	return text("", code).set_header("Location", location)


## Reason phrase for a status code.
static func status_text(code: int) -> String:
	match code:
		101: return "Switching Protocols"
		200: return "OK"
		204: return "No Content"
		206: return "Partial Content"
		301: return "Moved Permanently"
		302: return "Found"
		304: return "Not Modified"
		400: return "Bad Request"
		403: return "Forbidden"
		404: return "Not Found"
		405: return "Method Not Allowed"
		408: return "Request Timeout"
		411: return "Length Required"
		413: return "Content Too Large"
		414: return "URI Too Long"
		416: return "Range Not Satisfiable"
		426: return "Upgrade Required"
		429: return "Too Many Requests"
		431: return "Request Header Fields Too Large"
		500: return "Internal Server Error"
		501: return "Not Implemented"
		503: return "Service Unavailable"
		505: return "HTTP Version Not Supported"
	return "Status"


## Serializes the status line and headers. Internal: used by the host.
func build_head(content_length: int, keep_alive: bool) -> PackedByteArray:
	var s := "HTTP/1.1 %d %s\r\n" % [status, status_text(status)]
	for k in headers:
		var lk := String(k).to_lower()
		if lk == "content-length" or (lk == "connection" and status != 101):
			continue
		s += "%s: %s\r\n" % [k, _clean(str(headers[k]))]
	if status != 101 and status != 204 and status != 304:
		s += "Content-Length: %d\r\n" % content_length
	if status != 101:
		s += "Connection: %s\r\n" % ("keep-alive" if keep_alive else "close")
	s += "\r\n"
	return s.to_utf8_buffer()


static func _clean(v: String) -> String:
	return v.replace("\r", "").replace("\n", "")
