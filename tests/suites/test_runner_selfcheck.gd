extends RefCounted
## Sanity checks for the test runner helpers themselves.


func run(t) -> void:
	t.section("eq")
	t.eq(1, 1.0, "int vs float")
	t.eq([1, 2, {"a": [3]}], [1.0, 2, {"a": [3.0]}], "deep")
	var typed: Array[int] = [1, 2]
	t.eq(typed, [1, 2], "typed vs untyped")
	t.ok(not PMCTestContext._deep_eq({"a": 1}, {"a": 2}), "dict differs")
	t.ok(not PMCTestContext._deep_eq("1", 1), "string vs int")
	t.near(0.1 + 0.2, 0.3)

	t.section("async")
	var n := [0]
	_tick(t, n)
	t.ok(await t.wait_until(func(): return n[0] > 0, 1.0), "wait_until sees coroutine progress")
	t.ok(not await t.wait_until(func(): return false, 0.05), "wait_until times out")

	t.section("tmp_dir")
	var d: String = t.tmp_dir()
	t.ok(DirAccess.dir_exists_absolute(d), "tmp dir exists")


func _tick(t, n: Array) -> void:
	await t.frame()
	n[0] += 1
