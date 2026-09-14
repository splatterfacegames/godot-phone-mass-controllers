class_name PMCVote
extends RefCounted
## A proposal vote with majority lock-in, vetoes and a timeout. Pure logic, no networking.
##
## Rules:
## - It's [code]"approved"[/code] as soon as yes votes are more than half of the eligible voters.
## - It's [code]"rejected"[/code] as soon as no votes are more than half of the eligible voters.
## - A veto (from an id with vetoes left) ends the vote as [code]"vetoed"[/code]. Call
##   [method repropose] to open the next proposal with the same voters and the remaining vetoes.
## - At the deadline, [method expire] approves when yes >= no and rejects otherwise.

## Current proposal id, or [code]-1[/code] before [method open].
var proposal_id := -1
## Deadline in milliseconds, on the same clock you pass to [method expire].
var ends_msec := 0

var _eligible: Array[int] = []
var _votes: Dictionary = {}     # id -> bool
var _vetoers: Dictionary = {}   # id -> vetoes left
var _decided := ""
var _open := false


## Starts a vote on [param p_proposal_id]. Only ids in [param eligible] may vote.
## [param vetoers] maps id to the number of vetoes it has left. The dictionary is copied.
func open(p_proposal_id: int, eligible: Array[int], p_ends_msec: int, vetoers: Dictionary = {}) -> void:
	proposal_id = p_proposal_id
	ends_msec = p_ends_msec
	_eligible = eligible.duplicate()
	_vetoers = vetoers.duplicate()
	_votes.clear()
	_decided = ""
	_open = true


## Re-opens voting on a new proposal after a veto (or any decision). Keeps the voters and the remaining vetoes.
func repropose(p_proposal_id: int, p_ends_msec: int) -> void:
	open(p_proposal_id, _eligible, p_ends_msec, _vetoers)


## Whether a vote is open and still undecided.
func is_open() -> bool:
	return _open and _decided == ""


## Records (or changes) [param id]'s vote. Returns false if [param id] isn't eligible or the vote is closed.
func cast(id: int, approve: bool) -> bool:
	if not is_open() or not _eligible.has(id):
		return false
	_votes[id] = approve
	_evaluate()
	return true


## Uses one of [param id]'s vetoes. Returns false if it has none left or the vote is closed.
func veto(id: int) -> bool:
	if not is_open() or int(_vetoers.get(id, 0)) <= 0:
		return false
	_vetoers[id] = int(_vetoers[id]) - 1
	_decided = "vetoed"
	return true


## Vetoes [param id] has left.
func vetoes_left(id: int) -> int:
	return int(_vetoers.get(id, 0))


## Removes [param id] from the electorate (e.g. the player left), drops its vote and re-evaluates.
func remove_voter(id: int) -> void:
	_eligible.erase(id)
	_votes.erase(id)
	if is_open():
		_evaluate()


## [code]{yes, no, eligible, decided, proposal_id}[/code]. [code]decided[/code] is
## [code]""[/code], [code]"approved"[/code], [code]"rejected"[/code] or [code]"vetoed"[/code].
func tally() -> Dictionary:
	var yes := 0
	var no := 0
	for id in _votes:
		if _votes[id]:
			yes += 1
		else:
			no += 1
	return {"yes": yes, "no": no, "eligible": _eligible.size(), "decided": _decided, "proposal_id": proposal_id}


## Applies the timeout rule when [param now_msec] >= [member ends_msec]. Returns the decision, or
## [code]""[/code] while it's still open and not yet due.
func expire(now_msec: int) -> String:
	if is_open() and now_msec >= ends_msec:
		var t := tally()
		_decided = "approved" if t.yes >= t.no else "rejected"
	return _decided


func _evaluate() -> void:
	var t := tally()
	var n: int = t.eligible
	if t.yes * 2 > n:
		_decided = "approved"
	elif t.no * 2 > n:
		_decided = "rejected"
