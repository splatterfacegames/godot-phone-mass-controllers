@tool
class_name PMCTunnel
extends Node
## One-click outside-LAN access through a Cloudflare Quick Tunnel.
##
## Runs [code]cloudflared tunnel --no-autoupdate --url http://127.0.0.1:<port>[/code] as a child process,
## reads its log for the public [code]https://<random>.trycloudflare.com[/code] URL and reports progress
## through [signal state_changed]. If cloudflared isn't installed it can download the official release
## binary from GitHub (see [member allow_download]).
## [br][br]
## Quick Tunnels need no Cloudflare account, but the URL changes every run and there is no uptime
## guarantee. The process is killed on [method stop], when the node leaves the tree, when it is freed
## and on window close.
## [codeblock]
## var tunnel := PMCTunnel.new()
## add_child(tunnel)
## tunnel.state_changed.connect(func(state, detail): print(state, " ", detail))
## tunnel.start(8080)
## [/codeblock]

## Progress: [code]"downloading"[/code] (detail = progress text), [code]"starting"[/code] (detail = binary path),
## [code]"ready"[/code] (detail = public URL), [code]"failed"[/code] (detail = reason), [code]"stopped"[/code].
signal state_changed(state: String, detail: String)
## Emitted when a download started by [method download] or [method start] finishes.
## [param path_or_error] is the installed binary path on success, else the reason.
signal download_finished(ok: bool, path_or_error: String)

## Where the downloader installs cloudflared.
const INSTALL_DIR := "user://pmc/bin"
## GitHub "latest release" download base for the official cloudflared binaries.
const RELEASE_BASE := "https://github.com/cloudflare/cloudflared/releases/latest/download/"
## GitHub API endpoint describing the latest release (asset URLs and SHA-256 digests).
const RELEASE_API := "https://api.github.com/repos/cloudflare/cloudflared/releases/latest"

## Public tunnel URL once [code]"ready"[/code], else empty.
var url: String = ""
## Allow downloading cloudflared when it can't be found. Defaults to true in the editor, false in games.
var allow_download: bool = Engine.is_editor_hint()
## Explicit cloudflared executable. Empty = env [code]PMC_CLOUDFLARED[/code], then [code]PATH[/code],
## then [constant INSTALL_DIR].
var cloudflared_path: String = ""
## Verify the download against the SHA-256 digest GitHub publishes for the release asset. When the digest
## can't be fetched (API blocked or rate limited) the download fails instead of running an unverified binary.
var verify_checksum: bool = true
## Seconds to wait for the URL and the first registered edge connection before failing.
var ready_timeout_sec: float = 60.0
## Before reporting [code]"ready"[/code], wait until the new hostname resolves in public DNS (checked over
## DNS-over-HTTPS so the system resolver doesn't cache an early "no such host" answer).
var verify_dns: bool = true
## Longest wait for the DNS check; after this the tunnel is reported ready anyway.
var dns_timeout_sec: float = 30.0
## DNS-over-HTTPS JSON endpoint used by [member verify_dns].
var dns_over_https_url: String = "https://cloudflare-dns.com/dns-query"
## Extra arguments appended to the cloudflared command line (e.g. [code]["--protocol", "http2"][/code]).
var extra_args: PackedStringArray = PackedStringArray()
## Current state: [code]"stopped"[/code], [code]"downloading"[/code], [code]"starting"[/code], [code]"ready"[/code] or [code]"failed"[/code].
var state: String = "stopped"
## Recent cloudflared log lines (newest last, capped), useful for diagnostics.
var log_lines: PackedStringArray = PackedStringArray()

var _port := 0
var _pid := -1
var _stderr: FileAccess
var _stdout: FileAccess
var _reader_thread: Thread
var _reader_mutex := Mutex.new()
var _reader_buffer := ""
var _line_buffer := ""
var _started_msec := 0
var _registered := false
var _last_error := ""
var _http: HTTPRequest
var _download_target := ""
var _download_part := ""
var _download_then_start := false
var _expected_sha256 := ""
var _release_tag := ""
var _last_progress_msec := 0
var _dns_http: HTTPRequest
var _dns_started_msec := 0
var _dns_next_msec := 0
static var _url_regex: RegEx

const _MAX_LOG_LINES := 200


## Starts a quick tunnel to [code]http://127.0.0.1:[param local_port][/code]. Resolves (or downloads)
## cloudflared first. Restarts if already running.
func start(local_port: int) -> void:
	if state != "stopped" and state != "failed":
		_kill(false)
	_port = local_port
	url = ""
	var why := unsupported_reason()
	if why != "":
		_fail(why)
		return
	var bin := resolve_binary(cloudflared_path)
	if bin != "":
		_launch(bin)
		return
	if not allow_download:
		_fail("cloudflared not found. Set cloudflared_path or PMC_CLOUDFLARED, put it on PATH, or allow downloading it")
		return
	_download_then_start = true
	_begin_download()


## Kills cloudflared (or cancels a download) and emits [code]"stopped"[/code].
func stop() -> void:
	var was := state
	_kill(false)
	if was != "stopped":
		_set_state("stopped", "")


## Download progress from 0.0 to 1.0, or -1.0 when no download is running or the size is unknown.
func get_download_progress() -> float:
	if _http == null or not is_instance_valid(_http) or _http.get_body_size() <= 0:
		return -1.0
	return clampf(float(_http.get_downloaded_bytes()) / _http.get_body_size(), 0.0, 1.0)


## Is the tunnel process running (starting or ready)?
func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


## Downloads cloudflared into [constant INSTALL_DIR] without starting a tunnel (ignores [member allow_download]).
## Progress arrives as [code]"downloading"[/code] states, the result as [signal download_finished].
func download() -> void:
	if _http != null:
		return
	var why := unsupported_reason()
	if why != "":
		download_finished.emit(false, why)
		return
	_download_then_start = false
	_begin_download()


## Returns a reason string when quick tunnels can't run on this platform, else "".
static func unsupported_reason() -> String:
	var os_name := OS.get_name()
	if os_name in ["Android", "iOS", "Web"]:
		return "cloudflared can't run as a subprocess on %s" % os_name
	if not OS.has_method("execute_with_pipe"):
		return "OS.execute_with_pipe is not available (needs Godot 4.3+)"
	return ""


## Finds cloudflared: [param explicit] path, env [code]PMC_CLOUDFLARED[/code], [code]PATH[/code], then the
## downloaded copy in [constant INSTALL_DIR]. Returns an absolute path, or "" when not found.
static func resolve_binary(explicit := "") -> String:
	if explicit != "":
		var p := _globalize(explicit)
		return p if FileAccess.file_exists(p) else _search_path(explicit)
	var env := OS.get_environment("PMC_CLOUDFLARED")
	if env != "" and FileAccess.file_exists(_globalize(env)):
		return _globalize(env)
	var found := _search_path(executable_name())
	if found != "":
		return found
	var local := install_path()
	return local if FileAccess.file_exists(local) else ""


## Executable file name on this OS ([code]cloudflared.exe[/code] on Windows).
static func executable_name() -> String:
	return "cloudflared.exe" if OS.get_name() == "Windows" else "cloudflared"


## Absolute path the downloader installs to.
static func install_path() -> String:
	return ProjectSettings.globalize_path(INSTALL_DIR).path_join(executable_name())


## Official release asset name for this OS/CPU, or "" if Cloudflare doesn't publish one.
static func asset_name() -> String:
	var arch := Engine.get_architecture_name()
	match OS.get_name():
		"Windows":
			return {"x86_64": "cloudflared-windows-amd64.exe", "x86_32": "cloudflared-windows-386.exe", "arm64": "cloudflared-windows-amd64.exe"}.get(arch, "")
		"macOS":
			return {"x86_64": "cloudflared-darwin-amd64.tgz", "arm64": "cloudflared-darwin-arm64.tgz"}.get(arch, "")
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			if OS.get_name() != "Linux":
				return ""
			return {"x86_64": "cloudflared-linux-amd64", "arm64": "cloudflared-linux-arm64", "arm32": "cloudflared-linux-arm", "x86_32": "cloudflared-linux-386"}.get(arch, "")
	return ""


## Extracts the public quick-tunnel URL from a cloudflared log line, or "".
static func parse_url(line: String) -> String:
	if _url_regex == null:
		_url_regex = RegEx.create_from_string("https://([a-z0-9-]+)\\.trycloudflare\\.com")
	for m in _url_regex.search_all(line):
		if m.get_string(1) != "api":
			return m.get_string()
	return ""


# ---------------------------------------------------------------------------

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PREDELETE:
			_kill(true)
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_EXIT_TREE:
			if _pid > 0 or _http != null:
				stop()


func _process(_delta: float) -> void:
	if _http != null:
		_poll_download()
	if _pid <= 0:
		return
	_pump_output()
	if _pid <= 0:
		return
	if not OS.is_process_running(_pid):
		_pump_output()
		if _pid > 0 and _line_buffer.strip_edges() != "":
			_handle_line(_line_buffer.strip_edges())
			_line_buffer = ""
		if _pid <= 0:
			return
		var code := -1
		if OS.has_method("get_process_exit_code"):
			code = OS.call("get_process_exit_code", _pid)
		var detail := "cloudflared exited" + (" (code %d)" % code if code != -1 else "")
		if _last_error != "":
			detail += ": " + _last_error
		_kill(false)
		_fail(detail)
		return
	if state == "starting" and _dns_started_msec > 0:
		_poll_dns()
	elif state == "starting" and Time.get_ticks_msec() - _started_msec > int(ready_timeout_sec * 1000.0):
		var detail := "timed out after %.0f s waiting for the tunnel" % ready_timeout_sec
		if url == "":
			detail += " URL"
		else:
			detail += " connection"
		if _last_error != "":
			detail += ": " + _last_error
		_kill(false)
		_fail(detail)


func _launch(bin: String) -> void:
	var args := PackedStringArray(["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:%d" % _port])
	args.append_array(extra_args)
	_registered = false
	_dns_started_msec = 0
	_last_error = ""
	_line_buffer = ""
	log_lines.clear()
	var info: Dictionary
	var non_blocking := _pipe_supports_non_blocking()
	if non_blocking:
		info = OS.callv("execute_with_pipe", [bin, args, false])
	else:
		info = OS.execute_with_pipe(bin, args)
	if info.is_empty() or int(info.get("pid", -1)) <= 0:
		_fail("failed to launch %s" % bin)
		return
	_pid = int(info.pid)
	_stdout = info.get("stdio")
	_stderr = info.get("stderr")
	_started_msec = Time.get_ticks_msec()
	if not non_blocking:
		# Godot 4.3: pipes only block, so read them on a thread.
		_reader_thread = Thread.new()
		_reader_thread.start(_reader_loop.bind(_stderr, _stdout))
	set_process(true)
	_set_state("starting", bin)


func _pump_output() -> void:
	var chunk := ""
	if _reader_thread != null:
		_reader_mutex.lock()
		chunk = _reader_buffer
		_reader_buffer = ""
		_reader_mutex.unlock()
	else:
		for f in [_stderr, _stdout]:
			if f == null:
				continue
			for i in 64:
				var b: PackedByteArray = f.get_buffer(4096)
				if b.is_empty():
					break
				chunk += b.get_string_from_utf8()
	if chunk == "":
		return
	_line_buffer += chunk
	var lines := _line_buffer.split("\n")
	_line_buffer = lines[lines.size() - 1]
	for i in lines.size() - 1:
		_handle_line(lines[i].strip_edges())
		if _pid <= 0:
			return


func _handle_line(line: String) -> void:
	if line == "":
		return
	log_lines.append(line)
	if log_lines.size() > _MAX_LOG_LINES:
		log_lines.remove_at(0)
	if line.contains(" ERR ") or line.contains("error=") or line.begins_with("ERR"):
		_last_error = line
	if url == "":
		var found := parse_url(line)
		if found != "":
			url = found
	if line.contains("Registered tunnel connection"):
		_registered = true
	if state == "starting" and url != "" and _registered and _dns_started_msec == 0:
		if verify_dns:
			_dns_started_msec = Time.get_ticks_msec()
			_dns_next_msec = 0
			log_lines.append("PMCTunnel: waiting for %s to resolve" % url.trim_prefix("https://"))
		else:
			_set_state("ready", url)


func _reader_loop(err_file: FileAccess, out_file: FileAccess) -> void:
	# Fallback for engines without non-blocking pipes. Reads stderr (cloudflared logs there); stdout is
	# drained afterwards. Ends when the process exits and the pipe closes.
	while err_file != null and err_file.is_open() and err_file.get_error() == OK:
		var line := err_file.get_line()
		if err_file.get_error() != OK and line == "":
			break
		_reader_mutex.lock()
		_reader_buffer += line + "\n"
		_reader_mutex.unlock()
	if out_file != null and out_file.is_open():
		var rest := out_file.get_as_text()
		_reader_mutex.lock()
		_reader_buffer += rest
		_reader_mutex.unlock()


func _kill(silent: bool) -> void:
	if _pid > 0:
		if OS.is_process_running(_pid):
			OS.kill(_pid)
		_pid = -1
	_stderr = null
	_stdout = null
	if _reader_thread != null:
		if _reader_thread.is_started():
			_reader_thread.wait_to_finish()
		_reader_thread = null
	if _http != null:
		if is_instance_valid(_http):
			_http.cancel_request()
			if not silent:
				_http.queue_free()
		_http = null
		_download_then_start = false
		if _download_part != "" and FileAccess.file_exists(_download_part):
			DirAccess.remove_absolute(_download_part)
	_stop_dns()
	url = ""
	_registered = false
	if silent:
		state = "stopped"


func _fail(reason: String) -> void:
	url = ""
	_set_state("failed", reason)


func _set_state(new_state: String, detail: String) -> void:
	state = new_state
	state_changed.emit(new_state, detail)


static func _pipe_supports_non_blocking() -> bool:
	for m in ClassDB.class_get_method_list("OS", true):
		if m.name == "execute_with_pipe":
			return (m.args as Array).size() >= 3
	return false


static func _globalize(p: String) -> String:
	return ProjectSettings.globalize_path(p) if p.begins_with("res://") or p.begins_with("user://") else p


static func _search_path(exe: String) -> String:
	if exe.contains("/") or exe.contains("\\"):
		return ""
	var sep := ";" if OS.get_name() == "Windows" else ":"
	var names := [exe]
	if OS.get_name() == "Windows" and not exe.to_lower().ends_with(".exe"):
		names.append(exe + ".exe")
	for dir in OS.get_environment("PATH").split(sep, false):
		for n: String in names:
			var candidate := dir.strip_edges().trim_prefix("\"").trim_suffix("\"").path_join(n)
			if FileAccess.file_exists(candidate):
				return candidate
	return ""


# ---------------------------------------------------------------------------
# DNS readiness

func _poll_dns() -> void:
	var now := Time.get_ticks_msec()
	if now - _dns_started_msec > int(dns_timeout_sec * 1000.0):
		log_lines.append("PMCTunnel: DNS check timed out; reporting ready anyway")
		_stop_dns()
		_dns_started_msec = -1
		_set_state("ready", url)
		return
	if _dns_http != null or now < _dns_next_msec:
		return
	_dns_next_msec = now + 1000
	_dns_http = HTTPRequest.new()
	_dns_http.timeout = 5.0
	add_child(_dns_http)
	_dns_http.request_completed.connect(_on_dns_completed)
	var q := "%s?name=%s&type=A" % [dns_over_https_url, url.trim_prefix("https://")]
	if _dns_http.request(q, PackedStringArray(["accept: application/dns-json"])) != OK:
		_stop_dns()


func _on_dns_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_stop_dns()
	if state != "starting" or _dns_started_msec <= 0:
		return
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var data = JSON.parse_string(body.get_string_from_utf8())
		if data is Dictionary and int(data.get("Status", -1)) == 0 and (data.get("Answer", []) as Array).size() > 0:
			log_lines.append("PMCTunnel: DNS resolves after %d ms" % (Time.get_ticks_msec() - _dns_started_msec))
			_dns_started_msec = -1
			_set_state("ready", url)


func _stop_dns() -> void:
	if _dns_http != null:
		if is_instance_valid(_dns_http):
			_dns_http.cancel_request()
			_dns_http.queue_free()
		_dns_http = null


# ---------------------------------------------------------------------------
# Download

func _begin_download() -> void:
	var asset := asset_name()
	if asset == "":
		_download_failed("no official cloudflared build for %s/%s" % [OS.get_name(), Engine.get_architecture_name()])
		return
	var dir := ProjectSettings.globalize_path(INSTALL_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	_download_target = dir.path_join(asset if asset.ends_with(".tgz") else executable_name())
	_download_part = _download_target + ".part"
	if FileAccess.file_exists(_download_part):
		DirAccess.remove_absolute(_download_part)
	_expected_sha256 = ""
	set_process(true)
	_last_progress_msec = 0
	if verify_checksum:
		# Phase 1: ask the GitHub API for the latest release's asset URL and SHA-256 digest.
		_http = _new_http("")
		_http.request_completed.connect(_on_release_info.bind(asset))
		var err := _http.request(RELEASE_API, PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: godot-phone-mass-controllers"]))
		if err != OK:
			_download_failed("release info request failed: %s" % error_string(err))
			return
		_set_state("downloading", "checking the latest release")
	else:
		_download_asset(RELEASE_BASE + asset, asset)


func _new_http(download_file: String) -> HTTPRequest:
	var h := HTTPRequest.new()
	h.use_threads = true
	h.max_redirects = 10
	h.download_file = download_file
	h.timeout = 300.0
	add_child(h)
	return h


func _on_release_info(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, asset: String) -> void:
	_free_http()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_download_failed("could not read the latest cloudflared release from the GitHub API (result %d, HTTP %d). Install cloudflared yourself or disable verify_checksum" % [result, code])
		return
	var info = JSON.parse_string(body.get_string_from_utf8())
	if not info is Dictionary:
		_download_failed("unexpected GitHub API response")
		return
	for a in info.get("assets", []):
		if a is Dictionary and a.get("name", "") == asset:
			var digest := str(a.get("digest", ""))
			if not digest.begins_with("sha256:"):
				_download_failed("the release lists no SHA-256 digest for %s" % asset)
				return
			_expected_sha256 = digest.trim_prefix("sha256:").to_lower()
			_release_tag = str(info.get("tag_name", ""))
			_download_asset(str(a.get("browser_download_url", RELEASE_BASE + asset)), asset)
			return
	_download_failed("latest cloudflared release has no asset named %s" % asset)


func _download_asset(asset_url: String, asset: String) -> void:
	_http = _new_http(_download_part)
	_http.request_completed.connect(_on_download_completed)
	var err := _http.request(asset_url)
	if err != OK:
		_download_failed("download request failed: %s" % error_string(err))
		return
	_set_state("downloading", "0 MB (%s %s)" % [asset, _release_tag])


func _poll_download() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_progress_msec < 250 or _http.download_file == "":
		return
	_last_progress_msec = now
	var got := _http.get_downloaded_bytes()
	var total := _http.get_body_size()
	var text := "%.1f MB" % (got / 1048576.0)
	if total > 0:
		text = "%.1f / %.1f MB (%d%%)" % [got / 1048576.0, total / 1048576.0, int(100.0 * got / total)]
	_set_state("downloading", text)


func _on_download_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_free_http()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(_download_part)
		_download_failed("download failed (result %d, HTTP %d)" % [result, code])
		return
	if _expected_sha256 != "":
		var actual := file_sha256(_download_part)
		if actual != _expected_sha256:
			DirAccess.remove_absolute(_download_part)
			_download_failed("checksum mismatch for the downloaded cloudflared (expected %s, got %s)" % [_expected_sha256, actual])
			return
		log_lines.append("PMCTunnel: SHA-256 verified %s" % actual)
	if FileAccess.file_exists(_download_target):
		DirAccess.remove_absolute(_download_target)
	var err := DirAccess.rename_absolute(_download_part, _download_target)
	if err != OK:
		_download_failed("could not move download into place: %s" % error_string(err))
		return
	var final_path := install_path()
	var out := []
	if _download_target.ends_with(".tgz"):
		var code_tar := OS.execute("tar", ["-xzf", _download_target, "-C", _download_target.get_base_dir()], out, true)
		DirAccess.remove_absolute(_download_target)
		if code_tar != 0 or not FileAccess.file_exists(final_path):
			_download_failed("could not extract cloudflared: %s" % "".join(out))
			return
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", final_path], out, true)
	out.clear()
	var code_ver := OS.execute(final_path, ["--version"], out, true)
	var version_text := "".join(out).strip_edges()
	if code_ver != 0 or not version_text.to_lower().contains("cloudflared"):
		_download_failed("downloaded cloudflared does not run (exit %d): %s" % [code_ver, version_text])
		return
	log_lines.append(version_text)
	download_finished.emit(true, final_path)
	if _download_then_start:
		_download_then_start = false
		_launch(final_path)
	else:
		_set_state("stopped", "")


## SHA-256 of a file as lowercase hex, or "" if it can't be read.
static func file_sha256(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		var chunk := f.get_buffer(1 << 20)
		if chunk.is_empty():
			break
		ctx.update(chunk)
	return ctx.finish().hex_encode()


func _free_http() -> void:
	if _http != null:
		if is_instance_valid(_http):
			_http.queue_free()
		_http = null


func _download_failed(reason: String) -> void:
	_free_http()
	download_finished.emit(false, reason)
	_download_then_start = false
	_fail(reason)
