extends RefCounted
## Table-driven unit tests for PMCQueue, PMCVote and PMCRotation.


func run(t) -> void:
	_queue(t)
	_vote(t)
	_rotation(t)


func _q(ids: Array) -> PMCQueue:
	var q := PMCQueue.new()
	for id in ids:
		q.push(id)
	return q


func _queue(t) -> void:
	t.section("queue basics")
	var q := _q([1, 2, 3])
	q.push(2)
	t.eq(q.ids(), [1, 2, 3], "push ignores duplicates")
	t.eq(q.position(3), 2, "position")
	t.eq(q.position(9), -1, "position of absent")
	q.remove(2)
	t.eq(q.ids(), [1, 3], "remove")
	q.remove(42)
	t.eq(q.size(), 2, "remove absent is a no-op")
	q.push_front(3)
	t.eq(q.ids(), [3, 1], "push_front moves existing")
	q.clear()
	t.eq(q.size(), 0, "clear")

	t.section("queue pop_next table")
	# [queue, n, ineligible ids, expected popped, expected remaining]
	var cases := [
		[[1, 2, 3, 4], 2, [], [1, 2], [3, 4]],
		[[1, 2, 3, 4], 2, [1], [2, 3], [1, 4]],
		[[1, 2, 3, 4], 2, [1, 2, 3], [4], [1, 2, 3]],
		[[1, 2, 3], 5, [], [1, 2, 3], []],
		[[1, 2, 3], 0, [], [], [1, 2, 3]],
		[[], 2, [], [], []],
		[[5, 6, 7], 1, [5, 6, 7], [], [5, 6, 7]],
	]
	for c in cases:
		var qq := _q(c[0])
		var bad: Array = c[2]
		var got := qq.pop_next(c[1], func(id: int) -> bool: return not bad.has(id))
		t.eq(got, c[3], "pop_next %s n=%d skip=%s" % [c[0], c[1], bad])
		t.eq(qq.ids(), c[4], "remaining after pop_next %s" % [c[0]])
	var q2 := _q([1, 2])
	t.eq(q2.pop_next(1), [1], "invalid Callable = all eligible")
	t.ok(q2.pop_next(1) is Array[int], "returns Array[int]")


func _vote(t) -> void:
	t.section("vote table")
	# [eligible, vetoers, actions, expected decided, expected yes, expected no]
	# actions: ["y", id] / ["n", id] / ["v", id] / ["x", now_msec]
	var cases := [
		[[1, 2, 3], {}, [["y", 1], ["y", 2]], "approved", 2, 0],
		[[1, 2, 3], {}, [["y", 1]], "", 1, 0],
		[[1, 2, 3, 4], {}, [["y", 1], ["y", 2]], "", 2, 0],       # 2 of 4 is not > half
		[[1, 2, 3, 4], {}, [["y", 1], ["y", 2], ["y", 3]], "approved", 3, 0],
		[[1, 2, 3], {}, [["n", 1], ["n", 2]], "rejected", 0, 2],
		[[1, 2, 3], {}, [["y", 1], ["n", 1], ["n", 2]], "rejected", 0, 2],  # vote change
		[[1, 2, 3], {}, [["y", 9]], "", 0, 0],                     # not eligible
		[[1, 2, 3], {3: 1}, [["y", 1], ["v", 3]], "vetoed", 1, 0],
		[[1, 2, 3], {}, [["v", 3]], "", 0, 0],                     # no vetoes
		[[1, 2, 3], {}, [["y", 1], ["x", 999]], "", 1, 0],         # not due yet
		[[1, 2, 3], {}, [["y", 1], ["x", 1000]], "approved", 1, 0],
		[[1, 2, 3, 4], {}, [["y", 1], ["n", 2], ["x", 2000]], "approved", 1, 1],  # tie approves
		[[1, 2, 3, 4], {}, [["n", 2], ["x", 2000]], "rejected", 0, 1],
		[[1, 2, 3], {}, [["x", 1000]], "approved", 0, 0],          # nobody voted: 0 >= 0
		[[], {}, [["x", 1000]], "approved", 0, 0],
		[[1, 2, 3], {}, [["y", 1], ["y", 2], ["n", 3]], "approved", 2, 0],  # locked: late vote refused
	]
	var i := 0
	for c in cases:
		var v := PMCVote.new()
		var el: Array[int] = []
		el.assign(c[0])
		v.open(100 + i, el, 1000, c[1])
		for a in c[2]:
			match a[0]:
				"y": v.cast(a[1], true)
				"n": v.cast(a[1], false)
				"v": v.veto(a[1])
				"x": v.expire(a[1])
		var tl := v.tally()
		t.eq(tl.decided, c[3], "case %d decided" % i)
		t.eq(tl.yes, c[4], "case %d yes" % i)
		t.eq(tl.no, c[5], "case %d no" % i)
		t.eq(tl.eligible, c[0].size(), "case %d eligible" % i)
		i += 1

	t.section("vote veto re-proposes")
	var v := PMCVote.new()
	var el: Array[int] = [1, 2, 3]
	v.open(1, el, 1000, {3: 1})
	t.ok(v.cast(1, true), "cast accepted")
	t.ok(v.veto(3), "veto accepted")
	t.ok(not v.cast(2, true), "cast refused after veto")
	t.eq(v.expire(5000), "vetoed", "expire keeps vetoed")
	v.repropose(2, 3000)
	t.eq(v.tally(), {"yes": 0, "no": 0, "eligible": 3, "decided": "", "proposal_id": 2}, "fresh tally")
	t.eq(v.vetoes_left(3), 0, "veto consumed")
	t.ok(not v.veto(3), "no vetoes left")
	t.ok(v.cast(1, true) and v.cast(2, true), "votes on new proposal")
	t.eq(v.tally().decided, "approved", "new proposal approved")
	t.ok(not v.is_open(), "closed after decision")

	t.section("vote remove_voter")
	var v2 := PMCVote.new()
	var el2: Array[int] = [1, 2, 3, 4]
	v2.open(1, el2, 1000)
	v2.cast(1, true)
	v2.cast(2, true)
	t.eq(v2.tally().decided, "", "2/4 undecided")
	v2.remove_voter(4)
	t.eq(v2.tally().decided, "approved", "2/3 approves after a voter leaves")


func _rotation(t) -> void:
	var WS := PMCRotation.Policy.WINNER_STAYS
	var LS := PMCRotation.Policy.LOSER_STAYS
	var ST := PMCRotation.Policy.STRICT
	t.section("rotation table")
	# [policy, last_blue, last_red, winner, streaks_in, queue_in, ineligible, expected pair, streaks_out, queue_out]
	var cases := [
		[WS, -1, -1, -1, {}, [1, 2, 3], [], [1, 2], {}, [3]],                          # first match
		[WS, 1, 2, 1, {}, [3, 4], [], [1, 3], {1: 1}, [4, 2]],                         # winner stays blue
		[WS, 1, 2, 2, {}, [3, 4], [], [3, 2], {2: 1}, [4, 1]],                         # winner stays red
		[WS, 1, 3, 1, {1: 1}, [4, 2], [], [4, 2], {}, [3, 1]],                         # streak 2 reached: both go
		[WS, 1, 2, 1, {}, [3, 4], [1], [3, 4], {}, [2, 1]],                            # winner ineligible
		[WS, 1, 2, 1, {}, [], [], [1, 2], {1: 1}, []],                                 # two players only
		[WS, 1, 2, 1, {1: 1}, [], [], [2, 1], {}, []],                                 # two players, streak maxed
		[WS, 1, 2, -1, {1: 1}, [3, 4], [], [3, 4], {}, [1, 2]],                        # draw rotates both
		[WS, 1, 2, 7, {}, [3, 4], [], [3, 4], {}, [1, 2]],                             # winner not on court = draw
		[WS, 1, 2, 1, {}, [3, 4], [3], [1, 4], {1: 1}, [3, 2]],                        # skip ineligible, keeps spot
		[WS, 1, 2, 1, {}, [3], [3], [1, 2], {1: 1}, [3]],                              # loser is the only eligible opponent
		[WS, 1, 2, 1, {}, [3], [1, 3], [], {}, [3, 2, 1]],                             # not enough eligible, order kept
		[WS, 1, 2, 1, {}, [], [2], [], {}, [1, 2]],                                    # stayer has no opponent: queued at front
		[LS, 1, 2, 1, {}, [3, 4], [], [3, 2], {2: 1}, [4, 1]],                         # loser stays
		[LS, 1, 3, 1, {3: 1}, [4, 2], [], [4, 2], {}, [1, 3]],                         # loser streak maxed
		[ST, 1, 2, 1, {1: 1}, [3, 4], [], [3, 4], {}, [1, 2]],                         # strict
		[ST, 1, 2, 1, {}, [], [], [1, 2], {}, []],                                     # strict, two players
		[WS, 1, 2, 1, {1: 5}, [3], [], [1, 3], {1: 6}, [2]],                           # max_streak 0 = unlimited (see below)
	]
	var i := 0
	for c in cases:
		var streaks: Dictionary = c[4].duplicate()
		var q := _q(c[5])
		var bad: Array = c[6]
		var max_streak := 0 if i == cases.size() - 1 else 2
		var pair := PMCRotation.next_pair(c[0], c[1], c[2], c[3], streaks, q,
				func(id: int) -> bool: return not bad.has(id), max_streak)
		t.eq(pair, c[7], "case %d pair" % i)
		t.eq(streaks, c[8], "case %d streaks" % i)
		t.eq(q.ids(), c[9], "case %d queue" % i)
		i += 1

	t.section("rotation sequence: winner-stays over several matches")
	var q := _q([1, 2, 3, 4])
	var streaks := {}
	var pair := PMCRotation.next_pair(WS, -1, -1, -1, streaks, q)
	var log: Array = [pair.duplicate()]
	for w in [0, 0, 1, 1]:  # index into pair of who wins
		pair = PMCRotation.next_pair(WS, pair[0], pair[1], pair[w], streaks, q)
		log.append(pair.duplicate())
	# 1v2 (1 wins) -> 1v3 (1 wins, streak 2: both out) -> 4v2 (2 wins) -> 3v2 (2 wins, streak 2: both out) -> 1v4
	t.eq(log, [[1, 2], [1, 3], [4, 2], [3, 2], [1, 4]], "sequence")
