extends RefCounted
## Buzzer Party rules, as pure logic (no networking, no nodes). Time is passed in as msec so
## tests can drive it deterministically.
##
## Each round every player privately gets a secret symbol. The big screen flashes symbols one
## after another. Buzz while YOUR symbol is showing: the first correct buzz wins the round.
## A wrong buzz locks that phone out for a moment. First to [member target_score] wins the match.

const SYMBOLS := [
	{"id": 0, "label": "Red Circle", "color": "#ff5a5f", "shape": "circle"},
	{"id": 1, "label": "Blue Square", "color": "#3d8bfd", "shape": "square"},
	{"id": 2, "label": "Green Triangle", "color": "#2ec27e", "shape": "triangle"},
	{"id": 3, "label": "Yellow Star", "color": "#ffc53d", "shape": "star"},
	{"id": 4, "label": "Purple Diamond", "color": "#a371f7", "shape": "diamond"},
	{"id": 5, "label": "Orange Hexagon", "color": "#ff8c42", "shape": "hexagon"},
	{"id": 6, "label": "Pink Heart", "color": "#ff6fb5", "shape": "heart"},
	{"id": 7, "label": "Teal Ring", "color": "#26c6da", "shape": "ring"},
]

enum Buzz { WIN, WRONG, LOCKED, IDLE }

## "lobby" | "round" | "reveal" | "over"
var phase := "lobby"
var round_no := 0
var target_score := 5
var flash_ms := 1400
var lead_ms := 1500           # "get ready" pause before the first flash
var max_flashes := 30         # round ends with no winner after this many
var lockout_ms := 1500
var late_ms := 250            # a buzz this soon after a flash changes still counts for the previous one

var scores := {}              # player id -> int. Kept for the whole match, so rejoin keeps the score.
var secrets := {}             # player id -> symbol index (current round)
var locked_until := {}        # player id -> msec
var winner_id := -1
var match_winner_id := -1
var flash_symbol := -1        # symbol index on screen, -1 = none
var flash_seq := 0
var rng := RandomNumberGenerator.new()

const STEAL_MS := 400         # a late-arriving earlier tap can still take the win within this window

var _flash_log := []          # [msec, symbol] per change this round; lets us judge a buzz at its own timestamp
var _next_flash_msec := 0
var _win_at_msec := 0
var _win_seen_msec := -1      # -1 = nobody has won this round yet


func _init(seed_value := 0) -> void:
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()


## Makes sure a player has a score entry.
func add_player(id: int) -> void:
	if not scores.has(id):
		scores[id] = 0


## Starts a round for [param ids]. Secrets are distinct while there are enough symbols.
## Returns false if nobody can play.
func start_round(ids: Array, now_msec: int) -> bool:
	if ids.is_empty():
		return false
	if phase == "over":
		reset_match()
	round_no += 1
	phase = "round"
	winner_id = -1
	secrets.clear()
	locked_until.clear()
	flash_symbol = -1
	flash_seq = 0
	_win_seen_msec = -1
	_flash_log = [[now_msec, -1]]
	var bag := _shuffled_symbols()
	for i in ids.size():
		add_player(ids[i])
		if i > 0 and i % bag.size() == 0:
			bag = _shuffled_symbols()
		secrets[ids[i]] = bag[i % bag.size()]
	_next_flash_msec = now_msec + lead_ms
	return true


## Gives a player who joined mid-round a secret. Returns the symbol index, or -1 outside a round.
func assign_late_secret(id: int) -> int:
	add_player(id)
	if phase != "round":
		return -1
	if not secrets.has(id):
		var used := {}
		for s in secrets.values():
			used[s] = true
		var free: Array = []
		for i in SYMBOLS.size():
			if not used.has(i):
				free.append(i)
		secrets[id] = free[rng.randi() % free.size()] if not free.is_empty() else rng.randi() % SYMBOLS.size()
	return secrets[id]


## Advances the flash cycle. Returns a list of events: {"type": "flash", "symbol": int, "seq": int}
## and {"type": "timeout"} when the round ends with no winner.
func tick(now_msec: int) -> Array:
	var events: Array = []
	if phase != "round" or now_msec < _next_flash_msec:
		return events
	if flash_seq >= max_flashes:
		phase = "reveal"
		flash_symbol = -1
		events.append({"type": "timeout"})
		return events
	flash_symbol = _pick_flash()
	flash_seq += 1
	_flash_log.append([now_msec, flash_symbol])
	_next_flash_msec = now_msec + flash_ms
	events.append({"type": "flash", "symbol": flash_symbol, "seq": flash_seq})
	return events


## Handles a buzz. [param at_msec] is when the phone says it tapped, on the host clock —
## clamp it to [param seen_msec] - rtt at the edge so backdating stays bounded by latency.
## A correct buzz tapped before the winner's but arriving within STEAL_MS of the win steals
## the round (first tap wins, not first packet). A match-ending win is final.
## Returns {"result": Buzz, "locked_ms": int}.
func buzz(id: int, at_msec: int, seen_msec := -1) -> Dictionary:
	if seen_msec < 0:
		seen_msec = at_msec
	if phase == "reveal" and _win_seen_msec >= 0:
		if secrets.has(id) and at_msec < _win_at_msec and seen_msec - _win_seen_msec <= STEAL_MS \
				and seen_msec >= locked_until.get(id, 0) and _hit(id, at_msec, seen_msec):
			scores[winner_id] = int(scores[winner_id]) - 1
			scores[id] = int(scores.get(id, 0)) + 1
			winner_id = id
			_win_at_msec = at_msec
			_win_seen_msec = seen_msec
			if scores[id] >= target_score:
				phase = "over"
				match_winner_id = id
			return {"result": Buzz.WIN, "locked_ms": 0}
		return {"result": Buzz.IDLE, "locked_ms": 0}
	if phase != "round" or not secrets.has(id) or flash_symbol == -1:
		return {"result": Buzz.IDLE, "locked_ms": 0}
	var until: int = locked_until.get(id, 0)
	if seen_msec < until:
		return {"result": Buzz.LOCKED, "locked_ms": until - seen_msec}
	if not _hit(id, at_msec, seen_msec):
		locked_until[id] = seen_msec + lockout_ms
		return {"result": Buzz.WRONG, "locked_ms": lockout_ms}
	scores[id] = int(scores.get(id, 0)) + 1
	winner_id = id
	_win_at_msec = at_msec
	_win_seen_msec = seen_msec
	flash_symbol = -1
	if scores[id] >= target_score:
		phase = "over"
		match_winner_id = id
	else:
		phase = "reveal"
	return {"result": Buzz.WIN, "locked_ms": 0}


## Was [param id]'s secret on screen at [param at_msec] (with [member late_ms] grace for a tap
## that lands right as the flash changes)? [param seen_msec] caps how far ahead a claim can reach.
func _hit(id: int, at_msec: int, seen_msec: int) -> bool:
	var mine: int = secrets.get(id, -1)
	if mine < 0:
		return false
	# The live flash covers taps since it appeared (and a flash_symbol a host set directly).
	if mine == flash_symbol and _flash_log.back()[0] <= at_msec and at_msec <= seen_msec:
		return true
	var i := _symbol_idx_at(at_msec)
	if i >= 0 and _flash_log[i][1] == mine:
		return true
	return i > 0 and _flash_log[i - 1][1] == mine and at_msec - _flash_log[i][0] <= late_ms


## Index into _flash_log of the symbol showing at [param at_msec]; -1 if before the round.
func _symbol_idx_at(at_msec: int) -> int:
	for i in range(_flash_log.size() - 1, -1, -1):
		if _flash_log[i][0] <= at_msec:
			return i
	return -1


## Back to the lobby with all scores at zero (players stay).
func reset_match() -> void:
	for id in scores:
		scores[id] = 0
	round_no = 0
	phase = "lobby"
	winner_id = -1
	match_winner_id = -1
	secrets.clear()
	locked_until.clear()
	flash_symbol = -1


## Forget a player completely (e.g. kicked).
func remove_player(id: int) -> void:
	scores.erase(id)
	secrets.erase(id)
	locked_until.erase(id)


## Players sorted by score, highest first, ties by id.
func ranking() -> Array:
	var ids := scores.keys()
	ids.sort_custom(func(a, b): return scores[a] > scores[b] or scores[a] == scores[b] and a < b)
	return ids


func _shuffled_symbols() -> Array:
	var bag: Array = range(SYMBOLS.size())
	for i in range(bag.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = bag[i]
		bag[i] = bag[j]
		bag[j] = tmp
	return bag


# Mostly symbols someone actually holds, with a few decoys; never the same symbol twice in a row.
func _pick_flash() -> int:
	var held: Array = []
	for s in secrets.values():
		if not held.has(s):
			held.append(s)
	for _i in 8:
		var pick: int
		if not held.is_empty() and rng.randf() < 0.6:
			pick = held[rng.randi() % held.size()]
		else:
			pick = rng.randi() % SYMBOLS.size()
		if pick != flash_symbol:
			return pick
	return (flash_symbol + 1) % SYMBOLS.size()
