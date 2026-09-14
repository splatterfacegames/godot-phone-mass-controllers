class_name PMCQueue
extends RefCounted
## Ordered play queue of player ids. Pure logic, no networking.
##
## Players wait in insertion order. [method pop_next] takes the first eligible players and leaves
## ineligible ones (e.g. temporarily disconnected) in place, so they keep their spot.

var _ids: Array[int] = []


## Appends [param id] to the back. Does nothing if it's already queued.
func push(id: int) -> void:
	if not _ids.has(id):
		_ids.append(id)


## Inserts [param id] at the front, or moves it there if it's already queued.
func push_front(id: int) -> void:
	_ids.erase(id)
	_ids.insert(0, id)


## Removes [param id] from the queue. Does nothing if it's absent.
func remove(id: int) -> void:
	_ids.erase(id)


## Zero-based position of [param id], or [code]-1[/code] when it isn't queued.
func position(id: int) -> int:
	return _ids.find(id)


## Whether [param id] is queued.
func has(id: int) -> bool:
	return _ids.has(id)


## Number of queued ids.
func size() -> int:
	return _ids.size()


## Removes every id.
func clear() -> void:
	_ids.clear()


## A copy of the queued ids, front first.
func ids() -> Array[int]:
	return _ids.duplicate()


## Removes and returns up to [param n] eligible ids from the front.
## [param is_eligible] is [code]func(id: int) -> bool[/code]. An invalid Callable treats everyone as eligible.
## Ineligible ids are skipped but stay where they are.
func pop_next(n: int, is_eligible: Callable = Callable()) -> Array[int]:
	var out: Array[int] = []
	if n <= 0:
		return out
	var check := is_eligible.is_valid()
	for id in _ids:
		if out.size() >= n:
			break
		if not check or is_eligible.call(id):
			out.append(id)
	for id in out:
		_ids.erase(id)
	return out
