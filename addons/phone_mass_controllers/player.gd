class_name PMCPlayer
extends RefCounted
## A connected (or reconnecting) phone controller, owned by a [PMCHost].
##
## The same instance survives reconnects within [member PMCHost.grace_seconds], so keep game state for a
## player in [member meta] or in your own dictionary keyed by [member id].

## Stable player id (1, 2, 3, ...). It isn't reused by another player during the host's lifetime.
var id := 0
## Secret rejoin token (128-bit hex). Don't show it to other players.
var token := ""
## Display name (trimmed, at most [constant PMCHost.MAX_NAME_LENGTH] characters).
var name := ""
## Free-form profile sent by the controller (e.g. avatar, colour).
var profile: Dictionary = {}
## Whether a socket is currently attached.
var connected := false
## Whether the player authenticated with [member PMCHost.admin_pin].
var is_admin := false
## Game-owned data. Preserved across rejoins and restored from tombstones.
var meta: Dictionary = {}
## [method Time.get_ticks_msec] when the player first joined.
var joined_msec := 0
## [method Time.get_ticks_msec] of the last message (or disconnect).
var last_seen_msec := 0
## When disconnected: the [method Time.get_ticks_msec] at which the player is removed with reason "timeout". 0 while connected.
var grace_deadline_msec := 0
## Remote IP of the current (or last) socket. Behind a tunnel this is the tunnel's local address.
var remote_address := ""

## Internal: the attached PMCConnection, or null.
var _conn: RefCounted = null


func _to_string() -> String:
	return "PMCPlayer(%d, %s%s)" % [id, name, "" if connected else ", disconnected"]
