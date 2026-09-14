extends SceneTree
## Headless test runner. Discovers res://tests/suites/test_*.gd and runs each suite's run(t).
## Usage: godot --headless --path . --script res://tests/run_tests.gd [-- --filter=<substr> --verbose]
## Exit code: 0 when all suites pass, 1 otherwise.

const SUITES_DIR := "res://tests/suites"
const DEFAULT_TIMEOUT := 120.0


class ScriptErrorLogger extends Logger:
	var errors: Array[String] = []
	var mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		mutex.lock()
		errors.append("%s (%s:%d in %s)" % [rationale if rationale != "" else code, file.get_file(), line, function])
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> Array[String]:
		mutex.lock()
		var out := errors.duplicate()
		errors.clear()
		mutex.unlock()
		return out


var _logger := ScriptErrorLogger.new()


func _initialize() -> void:
	OS.add_logger(_logger)
	_main.call_deferred()


func _main() -> void:
	var filter := ""
	var verbose := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr(9)
		elif a == "--verbose":
			verbose = true

	var files: Array[String] = []
	for f in DirAccess.get_files_at(SUITES_DIR):
		if f.begins_with("test_") and f.ends_with(".gd") and (filter == "" or f.contains(filter)):
			files.append(f)
	files.sort()

	var total_pass := 0
	var total_fail := 0
	var suites_pass := 0
	var suites_fail := 0
	var suites_skip := 0
	var failed_lines: Array[String] = []
	var t0 := Time.get_ticks_msec()

	for f in files:
		var name := f.get_basename()
		var path := SUITES_DIR.path_join(f)
		print("== %s" % name)
		var started := Time.get_ticks_msec()
		_logger.take()
		var script = load(path)
		if script == null or not script.can_instantiate():
			suites_fail += 1
			failed_lines.append("%s: failed to load/compile" % name)
			print("   FAIL (failed to load/compile)")
			continue
		var suite = script.new()
		var t := PMCTestContext.new(self, name)
		t.verbose = verbose
		var timeout: float = DEFAULT_TIMEOUT
		if script.get_script_constant_map().has("TIMEOUT"):
			timeout = float(script.get_script_constant_map()["TIMEOUT"])
		_run_suite(suite, t)
		var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
		while not t.done and Time.get_ticks_msec() < deadline:
			await process_frame
		if not t.done:
			t.fail("suite timed out after %.0f s" % timeout)
		t.cleanup()
		await process_frame
		for e in _logger.take():
			t.fail("script error: " + e)
		total_pass += t.passed
		total_fail += t.failed
		var ms := Time.get_ticks_msec() - started
		if t.failed > 0:
			suites_fail += 1
			failed_lines.append_array(t.failures)
			print("   FAIL  %d passed, %d failed  (%d ms)" % [t.passed, t.failed, ms])
		elif t.skipped:
			suites_skip += 1
			print("   SKIP  %s  (%d passed)" % [t.skip_reason, t.passed])
		else:
			suites_pass += 1
			print("   PASS  %d checks  (%d ms)" % [t.passed, ms])

	print("")
	if failed_lines.size() > 0:
		print("Failures:")
		for l in failed_lines:
			print("  - " + l)
		print("")
	print("Summary: %d suites passed, %d failed, %d skipped; %d checks passed, %d failed (%.1f s)" % [
		suites_pass, suites_fail, suites_skip, total_pass, total_fail, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(1 if (suites_fail > 0 or files.is_empty() and filter == "") else 0)


func _run_suite(suite, t: PMCTestContext) -> void:
	await suite.run(t)
	t.done = true
