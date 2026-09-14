class_name PMCTestContext
extends RefCounted
## Assertion and async helper handed to every test suite's [code]run(t)[/code]. See tests/README.md.

## The running [SceneTree].
var tree: SceneTree
## The root [Window] of [member tree].
var root: Window
## Suite name (file name without extension).
var suite_name := ""
## Current section name.
var current_section := ""
## Passed check count.
var passed := 0
## Failed check count.
var failed := 0
## Failure descriptions.
var failures: Array[String] = []
## Whether [method skip] was called.
var skipped := false
## Skip reason.
var skip_reason := ""
## Set by the runner when [code]run[/code] returns.
var done := false
## Print every passing check too.
var verbose := false

var _nodes: Array[Node] = []


func _init(p_tree: SceneTree, p_suite_name: String) -> void:
	tree = p_tree
	root = p_tree.root
	suite_name = p_suite_name


## Starts a named section.
func section(name: String) -> void:
	current_section = name
	if verbose:
		print("  [%s]" % name)


## Passes when [param cond] is truthy.
func ok(cond, msg := "") -> bool:
	if cond:
		passed += 1
		if verbose:
			print("    ok  %s" % msg)
		return true
	_record("expected true" if msg == "" else msg)
	return false


## Deep equality (int/float compare numerically, typed/untyped arrays by contents).
func eq(actual, expected, msg := "") -> bool:
	if _deep_eq(actual, expected):
		passed += 1
		if verbose:
			print("    ok  %s" % msg)
		return true
	_record("%s: got %s, expected %s" % [msg if msg != "" else "eq", _repr(actual), _repr(expected)])
	return false


## Numeric closeness.
func near(actual, expected, eps := 1e-4, msg := "") -> bool:
	if (typeof(actual) == TYPE_INT or typeof(actual) == TYPE_FLOAT) and absf(float(actual) - float(expected)) <= eps:
		passed += 1
		return true
	_record("%s: got %s, expected %s ± %s" % [msg if msg != "" else "near", _repr(actual), _repr(expected), eps])
	return false


## Records a failure.
func fail(msg: String) -> void:
	_record(msg)


## Marks the suite skipped. Call it and then return from [code]run[/code].
func skip(reason: String) -> void:
	skipped = true
	skip_reason = reason


## Prints an informational line.
func note(msg: String) -> void:
	print("    note: %s" % msg)


## Waits one process frame.
func frame() -> void:
	await tree.process_frame


## Waits [param seconds] of wall-clock time while frames run.
func wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await tree.process_frame


## Pumps frames until [param cond] returns truthy. Returns false on timeout.
func wait_until(cond: Callable, timeout := 5.0) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while true:
		if cond.call():
			return true
		if Time.get_ticks_msec() >= end:
			return false
		await tree.process_frame
	return false


## Adds [param node] under the root. It's freed when the suite ends.
func add_node(node: Node) -> Node:
	root.add_child(node)
	_nodes.append(node)
	return node


## Returns an empty scratch directory [code]user://pmc_tests/<suite>/[/code].
func tmp_dir() -> String:
	var path := "user://pmc_tests/%s/" % suite_name
	_rm_rf(ProjectSettings.globalize_path(path))
	DirAccess.make_dir_recursive_absolute(path)
	return path


## Whether a global class_name exists in this project.
func class_available(name: String) -> bool:
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == name:
			return true
	return false


## Frees nodes added via [method add_node]. Called by the runner.
func cleanup() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()


func _record(msg: String) -> void:
	failed += 1
	var where := suite_name
	if current_section != "":
		where += " > " + current_section
	var line := "%s: %s" % [where, msg]
	var bt := Engine.capture_script_backtraces()
	if bt.size() > 0:
		var gd: ScriptBacktrace = bt[0]
		for i in gd.get_frame_count():
			var file := gd.get_frame_file(i)
			if not file.ends_with("test_context.gd"):
				line += "  (%s:%d)" % [file.get_file(), gd.get_frame_line(i)]
				break
	failures.append(line)
	print("    FAIL %s" % line)


func _rm_rf(abs_path: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	for f in DirAccess.get_files_at(abs_path):
		DirAccess.remove_absolute(abs_path.path_join(f))
	for d in DirAccess.get_directories_at(abs_path):
		_rm_rf(abs_path.path_join(d))
	DirAccess.remove_absolute(abs_path)


static func _is_num(v) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


static func _deep_eq(a, b) -> bool:
	if _is_num(a) and _is_num(b):
		return float(a) == float(b)
	var ta := typeof(a)
	var tb := typeof(b)
	var a_arr := ta >= TYPE_ARRAY and ta <= TYPE_PACKED_VECTOR4_ARRAY and ta != TYPE_PACKED_BYTE_ARRAY
	var b_arr := tb >= TYPE_ARRAY and tb <= TYPE_PACKED_VECTOR4_ARRAY and tb != TYPE_PACKED_BYTE_ARRAY
	if a_arr and b_arr:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _deep_eq(a[i], b[i]):
				return false
		return true
	if ta == TYPE_DICTIONARY and tb == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _deep_eq(a[k], b[k]):
				return false
		return true
	if (ta == TYPE_STRING or ta == TYPE_STRING_NAME) and (tb == TYPE_STRING or tb == TYPE_STRING_NAME):
		return String(a) == String(b)
	if ta != tb:
		return false
	return a == b


static func _repr(v) -> String:
	var s: String
	if typeof(v) == TYPE_PACKED_BYTE_ARRAY:
		s = "PackedByteArray(%d)" % v.size()
	elif typeof(v) == TYPE_STRING:
		s = JSON.stringify(v)
	else:
		s = var_to_str(v)
	if s.length() > 300:
		s = s.substr(0, 300) + "…"
	return s
