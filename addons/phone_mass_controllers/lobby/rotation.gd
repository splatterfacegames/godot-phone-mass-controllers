class_name PMCRotation
extends RefCounted
## Picks the next two players for a two-sided ("blue" vs "red") match. Pure logic, no networking.
##
## The [PMCQueue] holds waiting players only. Players on court aren't in it.
## [br]- [code]WINNER_STAYS[/code]: the winner keeps their side and the loser goes to the back of the queue.
## [code]streaks[winner][/code] counts consecutive wins. When it reaches [code]max_streak[/code], the winner goes back too
## (after the loser). With the default of 2, a player plays at most two matches in a row by winning.
## [br]- [code]LOSER_STAYS[/code]: the same, with the roles swapped. The streak counts consecutive losses.
## [br]- [code]STRICT[/code]: both go back (blue first) and the next two come in.
## [br]A draw ([code]winner[/code] isn't one of the two players) rotates both players, as [code]STRICT[/code] does.
## A stayer who isn't eligible anymore goes to the back of the queue. Leavers are queued before new
## players are drawn, so with only two players the same pair plays again.
## [br][code]max_streak <= 0[/code] means no limit.

## Rotation policy.
enum Policy { WINNER_STAYS, LOSER_STAYS, STRICT }


## Returns [code][blue, red][/code] for the next match, or [code][][/code] when fewer than two eligible
## players are available. In that case everyone from the last match is queued (a would-be stayer goes
## to the front) and all of their streaks are cleared.
## [param streaks] ([code]id -> streak[/code]) is updated in place: the stayer's count goes up and everyone who
## leaves the court is erased. Pass [code]-1[/code] for [param last_blue]/[param last_red] before the first match.
static func next_pair(policy: int, last_blue: int, last_red: int, winner: int, streaks: Dictionary,
		queue: PMCQueue, is_eligible: Callable = Callable(), max_streak := 2) -> Array[int]:
	var eligible := func(id: int) -> bool:
		return id >= 0 and (not is_eligible.is_valid() or bool(is_eligible.call(id)))

	var stayer := -1
	var leavers: Array[int] = []
	var decided := winner >= 0 and (winner == last_blue or winner == last_red) and last_blue >= 0 and last_red >= 0
	if policy != Policy.STRICT and decided:
		var loser := last_red if winner == last_blue else last_blue
		var candidate := winner if policy == Policy.WINNER_STAYS else loser
		var other := loser if policy == Policy.WINNER_STAYS else winner
		var streak := int(streaks.get(candidate, 0)) + 1
		leavers.append(other)
		if (max_streak <= 0 or streak < max_streak) and eligible.call(candidate):
			stayer = candidate
			streaks[candidate] = streak
		else:
			leavers.append(candidate)
	else:
		for id in [last_blue, last_red]:
			if id >= 0:
				leavers.append(id)

	for id in leavers:
		streaks.erase(id)
		queue.push(id)

	var need := 1 if stayer >= 0 else 2
	var available := 0
	for id in queue.ids():
		if eligible.call(id):
			available += 1
	if available < need:
		if stayer >= 0:
			streaks.erase(stayer)
			queue.push_front(stayer)
		var empty: Array[int] = []
		return empty

	var drawn := queue.pop_next(need, eligible)
	var out: Array[int] = []
	if stayer < 0:
		out.assign([drawn[0], drawn[1]])
	elif stayer == last_blue:
		out.assign([stayer, drawn[0]])
	else:
		out.assign([drawn[0], stayer])
	return out
