class_name PMCHttpRequest
extends RefCounted
## A parsed HTTP/1.x request, as handed to [method PMCHost.add_route] handlers.

## Request method, e.g. [code]"GET"[/code].
var method := ""
## Raw request target as sent (e.g. [code]"/a%20b?x=1"[/code]).
var target := ""
## Percent-decoded path without the query (e.g. [code]"/a b"[/code]). Always starts with [code]"/"[/code].
var path := ""
## Raw (still percent-encoded) path without the query.
var raw_path := ""
## Raw query string without the leading [code]"?"[/code].
var query_string := ""
## Decoded query parameters. If a key repeats, the last value wins.
var query: Dictionary = {}
## Protocol version, [code]"HTTP/1.1"[/code] or [code]"HTTP/1.0"[/code].
var version := "HTTP/1.1"
## Headers keyed by lower-case name. Repeated headers are joined with [code]", "[/code].
var headers: Dictionary = {}
## Request body. Only [code]Content-Length[/code] bodies are accepted, capped by [member PMCHost.max_body_bytes].
var body := PackedByteArray()
## Peer IP address.
var remote_address := ""
## Peer TCP port.
var remote_port := 0
## For routes registered with [method PMCHost.add_route]: the matched prefix.
var route_prefix := ""


## Returns the header [param name] (case-insensitive), or [param default] when it's absent.
func header(name: String, default := "") -> String:
	return headers.get(name.to_lower(), default)


## Whether the header [param name] contains [param token] as a comma-separated, case-insensitive element.
func header_has_token(name: String, token: String) -> bool:
	for part in header(name).split(","):
		if part.strip_edges().to_lower() == token.to_lower():
			return true
	return false


## The path relative to [member route_prefix] (for prefix routes).
func sub_path() -> String:
	return path.substr(route_prefix.length()) if path.begins_with(route_prefix) else path


## Whether the connection should stay open after the response (HTTP/1.1 default, or HTTP/1.0 with keep-alive).
func wants_keep_alive() -> bool:
	if header_has_token("connection", "close"):
		return false
	if version == "HTTP/1.0":
		return header_has_token("connection", "keep-alive")
	return true


## The body decoded as UTF-8 text.
func body_text() -> String:
	return body.get_string_from_utf8()
