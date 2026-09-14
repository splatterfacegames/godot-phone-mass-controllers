class_name PMCStaticFiles
extends RefCounted
## Traversal-safe static file serving helpers (MIME types, path resolution, Range support).
##
## Note: in exported games, Godot only packs [i]imported[/i] resources (png, ogg, ...) in converted form.
## For files under res:// to be served as-is, add their folder to the export preset's
## "Filters to export non-resource files" (e.g. [code]controller/*[/code]), or serve from user:// or an absolute path.

const MIME := {
	"html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
	"js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
	"css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
	"map": "application/json; charset=utf-8", "webmanifest": "application/manifest+json; charset=utf-8",
	"txt": "text/plain; charset=utf-8", "md": "text/markdown; charset=utf-8",
	"xml": "application/xml; charset=utf-8", "csv": "text/csv; charset=utf-8",
	"ts": "text/plain; charset=utf-8",
	"svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
	"gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
	"bmp": "image/bmp",
	"woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
	"mp3": "audio/mpeg", "ogg": "audio/ogg", "oga": "audio/ogg", "wav": "audio/wav", "m4a": "audio/mp4",
	"flac": "audio/flac", "mp4": "video/mp4", "webm": "video/webm", "ogv": "video/ogg",
	"wasm": "application/wasm", "pdf": "application/pdf", "zip": "application/zip",
	"glb": "model/gltf-binary", "gltf": "model/gltf+json", "bin": "application/octet-stream",
	"pck": "application/octet-stream",
}

const _NO_CACHE_EXT := ["html", "htm", "js", "mjs", "css", "json", "ts", "webmanifest"]


## MIME type for a file path (by extension). Defaults to [code]application/octet-stream[/code].
static func mime_for(path: String) -> String:
	return MIME.get(path.get_extension().to_lower(), "application/octet-stream")


## Whether a file of this type gets [code]Cache-Control: no-cache[/code].
static func is_no_cache(path: String) -> bool:
	return _NO_CACHE_EXT.has(path.get_extension().to_lower())


## Resolves the decoded URL sub-path [param rel] under [param root] (res://, user:// or absolute).
## Returns [code]""[/code] if it's unsafe: [code]..[/code] segments, backslashes, colons, NUL or control characters.
## Otherwise returns the joined path, with a trailing [code]"/"[/code] if [param rel] had one.
static func resolve(root: String, rel: String) -> String:
	if root == "":
		return ""
	var segments: PackedStringArray = []
	for seg in rel.split("/"):
		if seg == "" or seg == ".":
			continue
		if seg == ".." or seg.contains("\\") or seg.contains(":"):
			return ""
		for c in seg:
			if c.unicode_at(0) < 32 or c.unicode_at(0) == 127:
				return ""
		# Windows ignores trailing dots/spaces (".. " or "..." can alias the parent), so refuse them.
		if seg.ends_with(".") or seg.ends_with(" "):
			return ""
		segments.append(seg)
	var base := root
	if base.ends_with("/") and not base.ends_with("://"):
		base = base.left(-1)
	var joined := base
	for seg in segments:
		joined = joined + ("" if joined.ends_with("/") else "/") + seg
	if rel.ends_with("/") and not joined.ends_with("/"):
		joined += "/"
	return joined


## Serves [param rel] (the decoded sub-path below the mount prefix) from [param root] for [param req].
## Directories without a trailing slash redirect (301), and directories serve [param index_file].
## Returns [code]null[/code] when nothing matches, so the caller can fall through to a 404.
static func serve(root: String, rel: String, req: PMCHttpRequest, index_file := "index.html") -> PMCHttpResponse:
	var p := resolve(root, rel)
	if p == "":
		if rel.contains("..") or rel.contains("\\") or rel.contains(":"):
			return PMCHttpResponse.error(400, "bad path")
		return null
	var dir_path := p.trim_suffix("/") if not p.ends_with("://") else p
	var is_dir := p.ends_with("/") or rel == ""
	if not is_dir and DirAccess.dir_exists_absolute(dir_path) and not FileAccess.file_exists(p):
		# Directory without a trailing slash: redirect so relative URLs work.
		if FileAccess.file_exists(dir_path.path_join(index_file)):
			var loc := req.raw_path + "/"
			if req.query_string != "":
				loc += "?" + req.query_string
			return PMCHttpResponse.redirect(loc, 301)
		return null
	if is_dir:
		p = (p if p.ends_with("/") else p + "/") + index_file
	if not FileAccess.file_exists(p):
		return null
	if req.method != "GET" and req.method != "HEAD":
		return PMCHttpResponse.error(405).set_header("Allow", "GET, HEAD")
	return file_response(p, req)


## A streamed file response with single-range support ([code]Range: bytes=a-b[/code] -> 206).
## Returns [code]null[/code] if the file can't be opened.
static func file_response(path: String, req: PMCHttpRequest = null) -> PMCHttpResponse:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var size := f.get_length()
	f.close()
	var r := PMCHttpResponse.file(path)
	if r == null:
		return null
	r.headers["Accept-Ranges"] = "bytes"
	r.file_length = size
	if req != null and req.headers.has("range"):
		var range := parse_range(req.header("range"), size)
		if range.size() == 0:
			return PMCHttpResponse.error(416).set_header("Content-Range", "bytes */%d" % size)
		if range[0] >= 0:
			r.status = 206
			r.file_offset = range[0]
			r.file_length = range[1] - range[0] + 1
			r.headers["Content-Range"] = "bytes %d-%d/%d" % [range[0], range[1], size]
	return r


## Parses a single [code]bytes=[/code] range against [param size]. Returns [code][start, end][/code] (inclusive),
## [code][-1, -1][/code] if the header should be ignored (multi-range or another unit), or [code][][/code] if it's unsatisfiable.
static func parse_range(value: String, size: int) -> Array[int]:
	var ignore: Array[int] = [-1, -1]
	var none: Array[int] = []
	var v := value.strip_edges()
	if not v.begins_with("bytes=") or v.contains(","):
		return ignore
	var spec := v.substr(6).strip_edges()
	var dash := spec.find("-")
	if dash < 0:
		return ignore
	var a := spec.substr(0, dash).strip_edges()
	var b := spec.substr(dash + 1).strip_edges()
	if (a != "" and not a.is_valid_int()) or (b != "" and not b.is_valid_int()):
		return ignore
	var start: int
	var end: int
	if a == "":
		if b == "":
			return ignore
		var suffix := b.to_int()
		if suffix <= 0 or size == 0:
			return none
		start = maxi(0, size - suffix)
		end = size - 1
	else:
		start = a.to_int()
		end = size - 1 if b == "" else mini(b.to_int(), size - 1)
		if start >= size or end < start:
			return none
	return [start, end]
