extends RefCounted
## Buzzer Party demo: round logic (demo/buzzer_game.gd).

const Game := preload("res://demo/buzzer_game.gd")


func run(t) -> void:
	t.section("secrets are distinct per round")
	var g = Game.new(42)
	t.ok(not g.start_round([], 0), "no players, no round")
	t.ok(g.start_round([1, 2, 3, 4, 5, 6], 0), "round starts")
	t.eq(g.phase, "round")
	t.eq(g.round_no, 1)
	var seen := {}
	for id in [1, 2, 3, 4, 5, 6]:
		seen[g.secrets[id]] = true
	t.eq(seen.size(), 6, "six distinct secrets")

	t.section("more players than symbols")
	var big = Game.new(7)
	var ids: Array = range(1, 21)
	big.start_round(ids, 0)
	t.eq(big.secrets.size(), 20)

	t.section("no flash before lead time")
	t.eq(g.tick(100), [], "still in lead")
	t.eq(g.buzz(1, 100)["result"], Game.Buzz.IDLE, "buzz before any flash is ignored")
	var ev: Array = g.tick(1500)
	t.eq(ev.size(), 1)
	t.eq(ev[0]["type"], "flash")
	t.eq(g.flash_seq, 1)

	t.section("wrong buzz locks out")
	var shown: int = g.flash_symbol
	var wrong_id := -1
	var right_id := -1
	for id in g.secrets:
		if g.secrets[id] == shown:
			right_id = id
		elif wrong_id == -1:
			wrong_id = id
	t.eq(g.buzz(wrong_id, 1600)["result"], Game.Buzz.WRONG)
	var locked: Dictionary = g.buzz(wrong_id, 1700)
	t.eq(locked["result"], Game.Buzz.LOCKED)
	t.eq(locked["locked_ms"], 1400)
	t.eq(g.scores[wrong_id], 0, "wrong buzz costs no points")

	t.section("correct buzz wins")
	if right_id == -1:
		# Flash a symbol that someone holds.
		right_id = 1
		g.flash_symbol = g.secrets[1]
	t.eq(g.buzz(right_id, 1800)["result"], Game.Buzz.WIN)
	t.eq(g.scores[right_id], 1)
	t.eq(g.winner_id, right_id)
	t.eq(g.phase, "reveal")
	t.eq(g.buzz(wrong_id, 1900)["result"], Game.Buzz.IDLE, "no buzzing after the round is won")

	t.section("late buzz grace for previous flash")
	g.start_round([1, 2], 10000)
	g.tick(11500)
	var first: int = g.flash_symbol
	var holder := 1 if g.secrets[1] == first else 2 if g.secrets[2] == first else -1
	if holder == -1:
		g.secrets[1] = first
		holder = 1
	g.tick(12900)
	t.ok(g.flash_symbol != first, "flash changed")
	t.eq(g.buzz(holder, 13000)["result"], Game.Buzz.WIN, "100 ms after the change still counts")

	t.section("timeout with no winner")
	var q = Game.new(3)
	q.max_flashes = 3
	q.start_round([1], 0)
	var events: Array = []
	var now := 0
	while q.phase == "round" and now < 100000:
		now += 100
		events.append_array(q.tick(now))
	t.eq(q.phase, "reveal")
	t.eq(events.back()["type"], "timeout")
	t.eq(q.winner_id, -1)

	t.section("flash never repeats back to back")
	var r = Game.new(9)
	r.max_flashes = 200
	r.start_round([1], 0)
	var last := -1
	var repeats := 0
	for i in 200:
		for e in r.tick(1500 + i * 1400):
			if e["type"] == "flash":
				if e["symbol"] == last:
					repeats += 1
				last = e["symbol"]
	t.eq(repeats, 0)

	t.section("match win and reset")
	var m = Game.new(5)
	m.target_score = 2
	for i in 2:
		m.start_round([1, 2], 0)
		m.tick(1500)
		m.flash_symbol = m.secrets[1]
		m.buzz(1, 1600)
	t.eq(m.phase, "over")
	t.eq(m.match_winner_id, 1)
	t.eq(m.ranking(), [1, 2])
	m.start_round([1, 2], 5000)
	t.eq(m.scores[1], 0, "new match resets scores")
	t.eq(m.round_no, 1)

	t.section("late joiner gets an unused secret")
	var l = Game.new(11)
	l.start_round([1, 2, 3], 0)
	var s: int = l.assign_late_secret(9)
	t.ok(s >= 0)
	t.ok(not [l.secrets[1], l.secrets[2], l.secrets[3]].has(s), "unused symbol")
	t.eq(l.assign_late_secret(9), s, "stable on repeat")
	l.phase = "reveal"
	t.eq(l.assign_late_secret(10), -1, "no secret outside a round")
