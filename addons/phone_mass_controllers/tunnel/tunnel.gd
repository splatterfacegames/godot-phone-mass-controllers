@tool
class_name PMCTunnel
extends Node
## Outside-LAN access through a Cloudflare tunnel — quick or named.
##
## Quick mode ([member mode] [code]"quick"[/code]) runs
## [code]cloudflared tunnel --no-autoupdate --url http://127.0.0.1:<port>[/code] as a child process,
## reads its log for the public [code]https://<random>.trycloudflare.com[/code] URL and reports progress
## through [signal state_changed]. Quick tunnels need no Cloudflare account, but the URL changes every
## run and there is no uptime guarantee or SLA.
## [br][br]
## Named mode ([member mode] [code]"named"[/code]) runs a tunnel from your own Cloudflare account on a
## stable hostname: either the dashboard "run with token" token ([member named_token] +
## [member named_hostname]), or a locally created tunnel ([member named_tunnel] +
## [member named_credentials_file] + [member named_hostname]).
## [br][br]
## If cloudflared isn't installed it can download the official release binary from GitHub (see
## [member allow_download]). The process is killed on [method stop], when the node is freed and on
## window close. If the engine dies first, the next [method start] reaps the orphan recorded in
## [constant PID_FILE].
## [codeblock]
## var tunnel := PMCTunnel.new()
## add_child(tunnel)
## tunnel.state_changed.connect(func(state, detail): print(state, " ", detail))
## tunnel.start(8080)
## [/codeblock]

## Progress: [code]"downloading"[/code] (detail = progress text), [code]"starting"[/code] (detail =
## binary path or retry note), [code]"ready"[/code] (detail = public URL), [code]"lost"[/code]
## (detail = reason — the tunnel was up and dropped; it can return to [code]"ready"[/code] while the
## process lives), [code]"failed"[/code] (detail = reason), [code]"stopped"[/code].
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
## Records the child pid so a cloudflared orphaned by an engine crash can be reaped on the next start.
const PID_FILE := "user://pmc/cloudflared.pid"
## Written on demand; an (almost) empty config isolates us from a default ~/.cloudflared/config.yml,
## which breaks quick tunnels.
const EMPTY_CONFIG := "user://pmc/empty-cloudflared.yml"
## Generated config for named mode with name + credentials file.
const NAMED_CONFIG := "user://pmc/named-tunnel.yml"

## Public tunnel URL once [code]"ready"[/code], else empty. In named mode it is
## [code]https://<named_hostname>[/code] and is known as soon as the process launches.
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
## In named mode they land after [code]run[/code].
var extra_args: PackedStringArray = PackedStringArray()
## [code]"quick"[/code] (account-less, random trycloudflare URL) or [code]"named"[/code] (your Cloudflare
## account, stable hostname).
var mode: String = "quick"
## Named mode: token from the dashboard's "run with token" flow ([code]cloudflared tunnel run --token[/code]).
var named_token: String = ""
## Named mode: the public hostname routed to the tunnel (e.g. [code]party.example.com[/code]). Required —
## token mode prints no trycloudflare URL, so the join URL is built from this.
var named_hostname: String = ""
## Named mode without a token: tunnel name or UUID from [code]cloudflared tunnel create[/code].
var named_tunnel: String = ""
## Named mode without a token: credentials JSON written by [code]cloudflared tunnel create[/code].
var named_credentials_file: String = ""
## Retries when tunnel creation or registration fails before [code]"ready"[/code] (e.g. HTTP 429 /
## error 1015 rate limiting), with exponential backoff.
var max_retries: int = 2
## Delay before the first retry, in seconds; doubles each retry.
var retry_backoff_sec: float = 4.0
## When QUIC (outbound UDP 7844) looks blocked — its log errors, or registration stalling after the URL
## was issued — relaunch once with [code]--protocol http2[/code] (plain TCP 443). Skipped when
## [member extra_args] already sets a protocol.
var protocol_fallback: bool = true
## Seconds without a registered edge connection (after the URL exists) that count as "QUIC blocked".
var protocol_fallback_sec: float = 20.0
## All edge connections may stay unregistered this long while [code]"ready"[/code] before the state
## becomes [code]"lost"[/code]. A re-registration returns to [code]"ready"[/code].
var lost_grace_sec: float = 10.0
## Kill a leftover cloudflared recorded in [constant PID_FILE] before starting (engine crash recovery).
var reap_orphan: bool = true
## Directories checked for a default cloudflared config.yml/.yaml (which breaks quick tunnels).
## Empty = platform defaults: [code]%USERPROFILE%/.cloudflared[/code] on Windows;
## [code]~/.cloudflared[/code], [code]~/.cloudflare-warp[/code], [code]~/cloudflare-warp[/code],
## [code]/etc/cloudflared[/code], [code]/usr/local/etc/cloudflared[/code] elsewhere. When one is found
## the tunnel launches with an isolated [code]--config[/code] instead of failing.
var config_dirs: PackedStringArray = PackedStringArray()
## Minimum accepted cloudflared version ([code]"YYYY.M.D"[/code]). Older resolved binaries are rejected
## (named token mode needs 2022.6+).
var minimum_version: String = "2022.6.2"
## Re-verify the downloaded binary against the latest release once it's older than this many days
## (0 = never). Needs [member allow_download] to refresh; otherwise the cached copy is re-checked in place.
var binary_max_age_days: int = 30
## Verify the code signature of downloaded binaries: Authenticode (must be valid and signed by
## Cloudflare, Inc. when a signature is present) on Windows, [code]codesign --verify[/code] on macOS.
## Unsigned binaries fall back to the SHA-256 check.
var verify_signature: bool = true
## Set when the tunnel was detached from a freed host (e.g. a scene reload) and waits to be adopted.
## The child process keeps running; if nothing adopts it within ~2 minutes it shuts down.
var detached: bool = false:
	set(v):
		if v == detached:
			return
		detached = v
		_detached_at_msec = Time.get_ticks_msec()
## Current state: [code]"stopped"[/code], [code]"downloading"[/code], [code]"starting"[/code],
## [code]"ready"[/code], [code]"lost"[/code] or [code]"failed"[/code].
var state: String = "stopped"
## Recent cloudflared log lines (newest last, capped), useful for diagnostics.
var log_lines: PackedStringArray = PackedStringArray()

var _port := 0
var _pid := -1
var _bin := ""
var _stderr: FileAccess
var _stdout: FileAccess
var _reader_thread: Thread
var _reader_mutex := Mutex.new()
var _reader_buffer := ""
var _line_buffer := ""
var _started_msec := 0
var _deadline_msec := 0
var _registered := false
var _conns := {}                  # connIndex -> true (live edge connections)
var _conns_lost_msec := 0         # when the last connection unregistered (0 = fine / not ready)
var _quic_failed := false         # QUIC-specific error seen in this launch's log
var _use_http2 := false           # current launches inject --protocol http2
var _fell_back_http2 := false     # http2 fallback already used this start()
var _retries := 0                 # creation-failure retries used this start()
var _retry_at_msec := 0           # pending relaunch time (0 = none)
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
var _detached_at_msec := 0
static var _url_regex: RegEx
static var _conn_regex: RegEx
static var _version_regex: RegEx
static var _live_pids := {}       # pids owned by live PMCTunnel instances in this process
static var _checked_bins := {}    # binary path -> true, verified once per process

const _MAX_LOG_LINES := 200
const _DETACHED_TTL_MSEC := 120000


## Starts a tunnel to [code]http://127.0.0.1:[param local_port][/code]. Resolves (or downloads)
## cloudflared first. Restarts if already running.
func start(local_port: int) -> void:
	if state != "stopped" and state != "failed":
		_kill(false)
	_port = local_port
	url = ""
	_retries = 0
	_retry_at_msec = 0
	_deadline_msec = 0
	_quic_failed = false
	_use_http2 = false
	_fell_back_http2 = false
	_conns.clear()
	_conns_lost_msec = 0
	_registered = false
	var why := unsupported_reason()
	if why == "":
		why = _validate_mode()
	if why != "":
		_fail(why)
		return
	if reap_orphan:
		_reap_stale()
	var bin := resolve_binary(cloudflared_path)
	if bin != "":
		if _is_stale(bin) and allow_download:
			_download_then_start = true
			_begin_download()
			return
		var bwhy := _check_binary(bin)
		if bwhy != "":
			_fail(bwhy)
			return
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


## Is the tunnel process running (starting, ready or lost-but-alive)?
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


## Returns a reason string when tunnels can't run on this platform, else "".
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


## Directories searched for a default cloudflared config file (used when [member config_dirs] is empty).
static func default_config_dirs() -> PackedStringArray:
	var out := PackedStringArray()
	if OS.get_name() == "Windows":
		var home := OS.get_environment("USERPROFILE")
		if home == "":
			home = OS.get_environment("HOMEDRIVE") + OS.get_environment("HOMEPATH")
		if home != "":
			out.append(home.path_join(".cloudflared"))
	else:
		var home := OS.get_environment("HOME")
		if home != "":
			out.append(home.path_join(".cloudflared"))
			out.append(home.path_join(".cloudflare-warp"))
			out.append(home.path_join("cloudflare-warp"))
		out.append("/etc/cloudflared")
		out.append("/usr/local/etc/cloudflared")
	return out


## First existing config.yml/config.yaml in [param dirs] (platform defaults when empty), else "".
## Cloudflare's docs say a default config.yml prevents quick tunnels from starting.
static func find_default_config(dirs := PackedStringArray()) -> String:
	if dirs.is_empty():
		dirs = default_config_dirs()
	for d in dirs:
		for n in ["config.yml", "config.yaml"]:
			var p := d.path_join(n)
			if FileAccess.file_exists(p):
				return p
	return ""


## The [code]--version[/code] string of a cloudflared binary (e.g. [code]"2025.8.1"[/code]), or "".
static func binary_version(path: String) -> String:
	var out := []
	var code := _run_bin(path, ["--version"], out)
	var text := "".join(out).strip_edges()
	if code != 0 or not text.to_lower().contains("cloudflared"):
		return ""
	if _version_regex == null:
		_version_regex = RegEx.create_from_string("cloudflared version (\\d+\\.\\d+(\\.\\d+)?)")
	var m := _version_regex.search(text)
	return m.get_string(1) if m != null else ""


## True when [param v] >= [param min_v] (both dotted numbers).
static func version_at_least(v: String, min_v: String) -> bool:
	var a := v.split(".")
	var b := min_v.split(".")
	for i in maxi(a.size(), b.size()):
		var x := int(a[i]) if i < a.size() else 0
		var y := int(b[i]) if i < b.size() else 0
		if x != y:
			return x > y
	return true


## Checks a resolved cloudflared binary before running it: it must answer [code]--version[/code] and be
## at least [param min_version] (when both parse), and — for the managed download when [param signature]
## is on — pass Authenticode (Windows) or [code]codesign[/code] (macOS) verification. A binary carrying a
## signature must be valid and issued to Cloudflare; an unsigned one falls back to the SHA-256 check.
## Returns "" when acceptable, else the rejection reason.
static func verify_binary(path: String, min_version := "", signature := false) -> String:
	var v := binary_version(path)
	if v == "":
		return "not a working cloudflared binary: %s" % path
	if min_version != "" and not version_at_least(v, min_version):
		return "cloudflared %s is older than the supported minimum %s" % [v, min_version]
	if signature:
		return _verify_signature(path)
	return ""


## Turns a cloudflared error line into an actionable hint (appended to the original line).
static func friendly_error(line: String) -> String:
	var l := line.to_lower()
	if l.contains("code: 1015") or l.contains("429") or l.contains("too many requests"):
		return "Cloudflare rate-limited the request (HTTP 429 / error 1015) — it usually succeeds on retry. " + line
	if l.contains("no recent network activity") or l.contains("failed to create new quic connection"):
		return "QUIC (UDP 7844) seems blocked on this network — forcing --protocol http2 helps. " + line
	if l.contains("lookup api.trycloudflare.com") or l.contains("lookup ") and l.contains("no such host"):
		return "DNS lookup failed — a DNS filter or the network may be blocking trycloudflare.com. " + line
	return line


# ---------------------------------------------------------------------------

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PREDELETE:
			detached = false
			_kill(true)
		NOTIFICATION_WM_CLOSE_REQUEST:
			if _pid > 0 or _http != null:
				stop()
		NOTIFICATION_EXIT_TREE:
			# Children exit before the host does, so a stop here would kill the tunnel before the
			# host can detach it to the root for scene-reload adoption. Leaving the tree alive keeps
			# the process up; PREDELETE (free) and window close still end it.
			if not is_queued_for_deletion():
				detached = true


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _http != null:
		_poll_download()
	if detached and ((_pid <= 0 and _http == null and _retry_at_msec <= 0) or now - _detached_at_msec > _DETACHED_TTL_MSEC):
		queue_free()  # dead detached tunnels have nothing to adopt; live ones wait out the TTL
		return
	if _pid <= 0:
		if _retry_at_msec > 0:
			if now > _deadline_msec:
				_retry_at_msec = 0
				_fail("timed out after %.0f s waiting for the tunnel%s" % [ready_timeout_sec, _err_suffix()])
			elif now >= _retry_at_msec:
				_retry_at_msec = 0
				_launch(_bin)
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
		_on_process_exit(code)
		return
	if state == "starting" and _want_http2_fallback(now):
		_fall_back_http2()
	elif state == "ready" and _conns_lost_msec > 0 and now - _conns_lost_msec >= int(lost_grace_sec * 1000.0):
		_conns_lost_msec = 0
		_set_state("lost", "all tunnel connections unregistered")
	if state == "starting" and _dns_started_msec > 0:
		_poll_dns()
	elif state == "starting" and now > _deadline_msec:
		var detail := "timed out after %.0f s waiting for the tunnel" % ready_timeout_sec
		detail += " URL" if url == "" else " connection"
		if _last_error != "":
			detail += ": " + friendly_error(_last_error)
		_kill(false)
		_fail(detail)


func _validate_mode() -> String:
	if mode == "quick":
		return ""
	if mode != "named":
		return "unknown tunnel mode '%s' (expected quick or named)" % mode
	if named_hostname.strip_edges() == "":
		return "named mode needs named_hostname (the public hostname routed to your tunnel)"
	if named_token == "" and (named_tunnel == "" or named_credentials_file == ""):
		return "named mode needs named_token, or named_tunnel + named_credentials_file"
	return ""


func _named_url() -> String:
	if mode != "named":
		return ""
	var h := named_hostname.strip_edges()
	if h == "":
		return ""
	if h.contains("://"):
		h = h.substr(h.find("://") + 3)
	return "https://" + h.trim_suffix("/")


func _launch(bin: String) -> void:
	_bin = bin
	_registered = false
	_conns.clear()
	_conns_lost_msec = 0
	_quic_failed = false
	_dns_started_msec = 0
	_last_error = ""
	_line_buffer = ""
	url = _named_url()
	# Keep our own diagnostic lines (orphan reap, config isolation, earlier fallback note) across
	# the per-launch clear; only cloudflared's log is reset.
	var kept := PackedStringArray()
	for l in log_lines:
		if l.begins_with("PMCTunnel:"):
			kept.append(l)
	log_lines = kept
	var args := _build_args()
	if args.is_empty():
		return  # _fail already called
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
	if _deadline_msec == 0:
		_deadline_msec = _started_msec + int(ready_timeout_sec * 1000.0)
	_live_pids[_pid] = true
	_write_pidfile()
	if not non_blocking:
		# Godot 4.3: pipes only block, so read them on a thread.
		_reader_thread = Thread.new()
		_reader_thread.start(_reader_loop.bind(_stderr, _stdout))
	set_process(true)
	_set_state("starting", bin)


## Builds the cloudflared command line. On a config problem it calls [method _fail] and returns empty.
func _build_args() -> PackedStringArray:
	var args := PackedStringArray(["tunnel", "--no-autoupdate"])
	var cfg := ""
	if mode == "named" and named_token == "":
		cfg = _write_named_config()
		if cfg == "":
			_fail("could not write %s" % NAMED_CONFIG)
			return PackedStringArray()
	elif mode == "quick" or named_token != "":
		# Any default config.yml breaks quick tunnels (and can confuse token mode): isolate.
		var found := find_default_config(config_dirs)
		if found != "":
			log_lines.append("PMCTunnel: a default cloudflared config exists at %s; starting with an isolated config" % found)
		cfg = _empty_config()
		if cfg == "" and found != "":
			_fail("cloudflared config %s breaks %s tunnels, and an isolated config could not be written" % [found, mode])
			return PackedStringArray()
	if cfg != "":
		args.append_array(["--config", cfg])
	if _use_http2:
		args.append_array(["--protocol", "http2"])
	if mode == "named":
		if named_token != "":
			args.append_array(["run", "--token", named_token])
		else:
			args.append_array(["run", named_tunnel])
	else:
		args.append_array(["--url", "http://127.0.0.1:%d" % _port])
	args.append_array(extra_args)
	return args


## A nearly-empty config file, so a default ~/.cloudflared/config.yml can't leak in. "" on write failure.
func _empty_config() -> String:
	var p := ProjectSettings.globalize_path(EMPTY_CONFIG)
	if FileAccess.file_exists(p):
		return p
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string("no-autoupdate: true\n")
	f.close()
	return p


## Generated config for named mode with a credentials file. "" on write failure.
func _write_named_config() -> String:
	var p := ProjectSettings.globalize_path(NAMED_CONFIG)
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string("".join([
		"tunnel: %s\n" % named_tunnel.strip_edges(),
		"credentials-file: %s\n" % JSON.stringify(_globalize(named_credentials_file)),
		"ingress:\n",
		"  - hostname: %s\n" % named_hostname.strip_edges(),
		"    service: http://127.0.0.1:%d\n" % _port,
		"  - service: http_status:404\n",
	]))
	f.close()
	return p


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
	if _is_quic_error(line):
		_quic_failed = true
	if url == "" and mode == "quick":
		var found := parse_url(line)
		if found != "":
			url = found
	if line.contains("Registered tunnel connection"):
		_registered = true
		_conns[_conn_index(line)] = true
		_conns_lost_msec = 0
		if state == "lost":
			log_lines.append("PMCTunnel: edge connection re-registered; tunnel is back")
			_set_state("ready", url)
	elif line.contains("Unregistered tunnel connection"):
		_conns.erase(_conn_index(line))
		if _conns.is_empty() and _conns_lost_msec == 0 and state == "ready":
			_conns_lost_msec = Time.get_ticks_msec()
	if state == "starting" and url != "" and _registered and _dns_started_msec == 0:
		if verify_dns:
			_dns_started_msec = Time.get_ticks_msec()
			_dns_next_msec = 0
			log_lines.append("PMCTunnel: waiting for %s to resolve" % url.trim_prefix("https://"))
		else:
			_set_state("ready", url)


static func _conn_index(line: String) -> String:
	if _conn_regex == null:
		_conn_regex = RegEx.create_from_string("connIndex=(\\d+)")
	var m := _conn_regex.search(line)
	return m.get_string(1) if m != null else ""


static func _is_quic_error(line: String) -> bool:
	# "QuickTunnel" (the API object name in 429 errors) contains "quic" — strip it first.
	var l := line.to_lower().replace("quicktunnel", "")
	if l.contains("no recent network activity") or l.contains("failed to create new quic connection"):
		return true
	return (line.contains(" ERR ") or line.begins_with("ERR")) and l.contains("quic")


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


func _want_http2_fallback(now: int) -> bool:
	if not protocol_fallback or _fell_back_http2 or _has_protocol_arg():
		return false
	if _quic_failed:
		return true
	return url != "" and not _registered and now - _started_msec > int(protocol_fallback_sec * 1000.0)


func _has_protocol_arg() -> bool:
	for a in extra_args:
		if a == "--protocol" or a.begins_with("--protocol="):
			return true
	return false


func _fall_back_http2() -> void:
	_fell_back_http2 = true
	_use_http2 = true
	log_lines.append("PMCTunnel: QUIC (UDP 7844) looks blocked; retrying over HTTP/2 (TCP 443)")
	_clear_process()
	_launch(_bin)


func _on_process_exit(code: int) -> void:
	var detail := "cloudflared exited" + (" (code %d)" % code if code != -1 else "")
	if _last_error != "":
		detail += ": " + friendly_error(_last_error)
	if state == "starting" and _retries < max_retries:
		_retries += 1
		if _quic_failed and not _fell_back_http2:
			_fell_back_http2 = true
			_use_http2 = true
			log_lines.append("PMCTunnel: QUIC appears blocked; retrying over HTTP/2")
			detail = "QUIC appears blocked; retrying over HTTP/2 — " + detail
		_retry_at_msec = Time.get_ticks_msec() + int(retry_backoff_sec * 1000.0 * (1 << (_retries - 1)))
		_clear_process()
		url = ""
		_set_state("starting", "retry %d/%d: %s" % [_retries, max_retries, detail])
		return
	var was := state
	_kill(false)
	if was == "ready" or was == "lost":
		_set_state("lost", detail)
	else:
		_fail(detail)


## Kills the child process and releases its handles/pid bookkeeping. State and url are untouched.
func _clear_process() -> void:
	var was_pid := _pid
	if _pid > 0:
		if OS.is_process_running(_pid):
			OS.kill(_pid)
		_live_pids.erase(_pid)
		_pid = -1
	_stderr = null
	_stdout = null
	if _reader_thread != null:
		if _reader_thread.is_started():
			_reader_thread.wait_to_finish()
		_reader_thread = null
	_remove_pidfile(was_pid)


func _kill(silent: bool) -> void:
	_clear_process()
	_retry_at_msec = 0
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
	_conns.clear()
	_conns_lost_msec = 0
	_deadline_msec = 0
	if silent:
		state = "stopped"


func _fail(reason: String) -> void:
	url = ""
	_set_state("failed", reason)


func _set_state(new_state: String, detail: String) -> void:
	state = new_state
	state_changed.emit(new_state, detail)


func _err_suffix() -> String:
	return "" if _last_error == "" else ": " + friendly_error(_last_error)


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


## Runs [param path] with [param args] synchronously, collecting output. Batch files go through cmd /c.
static func _run_bin(path: String, args: Array, out: Array) -> int:
	if OS.get_name() == "Windows" and (path.to_lower().ends_with(".cmd") or path.to_lower().ends_with(".bat")):
		var cmd := "\"" + path + "\" " + " ".join(args)
		return OS.execute("cmd.exe", ["/c", cmd], out, true)
	return OS.execute(path, args, out, true)


# ---------------------------------------------------------------------------
# Orphan reaping (pid file)

func _write_pidfile() -> void:
	var p := ProjectSettings.globalize_path(PID_FILE)
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"pid": _pid, "exe": _bin, "port": _port, "mode": mode,
		"started": Time.get_unix_time_from_system(),
	}))
	f.close()


func _remove_pidfile(expect_pid: int) -> void:
	var p := ProjectSettings.globalize_path(PID_FILE)
	if not FileAccess.file_exists(p):
		return
	# Another live tunnel may have overwritten it; only remove records that name us.
	var data = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not data is Dictionary or int(data.get("pid", -1)) == expect_pid:
		DirAccess.remove_absolute(p)


## If the pid file records a still-running cloudflared from a dead engine instance, kill it.
## Best-effort: a recycled pid whose command line doesn't mention cloudflared is left alone.
func _reap_stale() -> void:
	var p := ProjectSettings.globalize_path(PID_FILE)
	if not FileAccess.file_exists(p):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not data is Dictionary:
		DirAccess.remove_absolute(p)
		return
	var pid := int(data.get("pid", -1))
	if pid <= 0:
		DirAccess.remove_absolute(p)
		return
	if pid == _pid or _live_pids.has(pid):
		return  # a live tunnel in this process owns it
	if not OS.is_process_running(pid):
		DirAccess.remove_absolute(p)
		return
	if _pid_looks_like_cloudflared(pid, str(data.get("exe", ""))):
		log_lines.append("PMCTunnel: killing leftover cloudflared (pid %d) recorded in %s" % [pid, p])
		OS.kill(pid)
	else:
		log_lines.append("PMCTunnel: pid file names live pid %d that doesn't look like cloudflared; left alone" % pid)
	DirAccess.remove_absolute(p)


## Is [param pid] plausibly the recorded cloudflared? Compares its command line / image name against
## "cloudflared" and the recorded exe path. False when it can't be verified — never murder a stranger.
static func _pid_looks_like_cloudflared(pid: int, recorded_exe: String) -> bool:
	var base := recorded_exe.get_file().to_lower()
	var probe := "cloudflared"
	var hay := _pid_cmdline(pid)
	if hay == "":
		hay = _pid_image_name(pid)
	hay = hay.to_lower()
	if hay == "":
		return false
	return hay.contains(probe) or (base != "" and hay.contains(base))


static func _pid_cmdline(pid: int) -> String:
	var out := []
	if OS.get_name() == "Windows":
		var code := OS.execute("powershell", ["-NoProfile", "-Command",
			"(Get-CimInstance Win32_Process -Filter 'ProcessId=%d').CommandLine" % pid], out, true)
		if code != 0:
			return ""
	else:
		if OS.execute("ps", ["-p", str(pid), "-o", "args="], out, true) != 0:
			return ""
	return "".join(out).strip_edges()


static func _pid_image_name(pid: int) -> String:
	var out := []
	if OS.get_name() == "Windows":
		if OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"], out, true) != 0:
			return ""
	else:
		if OS.execute("ps", ["-p", str(pid), "-o", "comm="], out, true) != 0:
			return ""
	return "".join(out).strip_edges()


# ---------------------------------------------------------------------------
# Binary verification (version, signature, cache age)

func _check_binary(bin: String) -> String:
	if _checked_bins.has(bin):
		return ""
	var why := verify_binary(bin, minimum_version, verify_signature and bin == install_path())
	if why == "":
		_checked_bins[bin] = true
	return why


## True when the managed download is older than [member binary_max_age_days].
func _is_stale(bin: String) -> bool:
	if binary_max_age_days <= 0 or bin != install_path():
		return false
	return Time.get_unix_time_from_system() - FileAccess.get_modified_time(bin) > binary_max_age_days * 86400.0


static func _verify_signature(path: String) -> String:
	match OS.get_name():
		"Windows":
			var out := []
			var script := "$s = Get-AuthenticodeSignature -LiteralPath '%s'; '{0}|{1}' -f $s.Status, $s.SignerCertificate.Subject" % path.replace("'", "''")
			if OS.execute("powershell", ["-NoProfile", "-Command", script], out, true) != 0:
				return ""  # no verifier available; the SHA-256 check is the floor
			var line := "".join(out).strip_edges()
			if line == "":
				return ""
			var status := line.get_slice("|", 0)
			var signer := line.get_slice("|", 1)
			if status == "Valid":
				if signer.contains("Cloudflare"):
					return ""
				return "the downloaded cloudflared is signed, but not by Cloudflare (%s)" % signer
			if status == "NotSigned":
				return ""
			return "Authenticode check failed for the downloaded cloudflared: %s" % status
		"macOS":
			var out := []
			if OS.execute("codesign", ["--verify", "--strict", path], out, true) == 0:
				var sp := []
				OS.execute("spctl", ["-a", "-t", "execute", "-vv", path], sp, true)  # informational (notarization)
				return ""
			var text := "".join(out).to_lower()
			if text.contains("not signed") or text.contains("code object is not signed"):
				return ""
			return "codesign verification failed for the downloaded cloudflared"
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
			# Refresh path: the installed binary already matches the latest release, so re-verify and reuse.
			if not asset.ends_with(".tgz") and FileAccess.file_exists(_download_target) and file_sha256(_download_target) == _expected_sha256:
				var why := verify_binary(_download_target, minimum_version, verify_signature)
				if why == "":
					log_lines.append("PMCTunnel: installed cloudflared still matches the latest release (%s)" % _release_tag)
					_finish_install(_download_target)
					return
				log_lines.append("PMCTunnel: installed binary failed re-verification (%s); re-downloading" % why)
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
	var why := verify_binary(final_path, minimum_version, verify_signature)
	if why != "":
		DirAccess.remove_absolute(final_path)
		_download_failed("downloaded cloudflared rejected: %s" % why)
		return
	_finish_install(final_path)


func _finish_install(final_path: String) -> void:
	var v := binary_version(final_path)
	log_lines.append("cloudflared version %s" % v if v != "" else "cloudflared ready at %s" % final_path)
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
