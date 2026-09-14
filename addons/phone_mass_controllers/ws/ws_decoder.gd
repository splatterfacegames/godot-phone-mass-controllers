class_name PMCWsDecoder
extends RefCounted
## Incremental RFC 6455 frame decoder with message reassembly. Internal.
##
## Feed bytes with [method push], then drain events with [method next] until it returns an empty Dictionary.
## Event shapes:
## [br][code]{"op": "text", "data": String}[/code], [code]{"op": "binary", "data": PackedByteArray}[/code]
## [br][code]{"op": "ping", "data": PackedByteArray}[/code], [code]{"op": "pong", "data": PackedByteArray}[/code]
## [br][code]{"op": "close", "code": int, "reason": String}[/code] (code 1005 when there's no status)
## [br][code]{"op": "error", "code": int, "reason": String}[/code]: a protocol violation. Close with [code]code[/code].
## After a close or error event, the decoder stops producing events.

## Largest reassembled message accepted. Larger ones produce error 1009.
var max_message_bytes := 1 << 20
## Reject unmasked frames (server side). Set false to decode server frames in test clients.
var require_mask := true

var _buf := PackedByteArray()
var _off := 0
var _frag_op := -1
var _frag_parts: Array[PackedByteArray] = []
var _frag_size := 0
var _done := false
# Current frame (header parsed, payload arriving).
var _f_active := false
var _f_op := 0
var _f_fin := true
var _f_len := 0
var _f_got := 0
var _f_key := PackedByteArray()
var _f_payload := PackedByteArray()


## Appends received bytes.
func push(data: PackedByteArray) -> void:
	if _done or data.is_empty():
		return
	if _off == _buf.size():
		_buf = data
		_off = 0
	else:
		_buf.append_array(data)


## Bytes buffered but not yet decoded.
func buffered() -> int:
	return _buf.size() - _off


## Whether a close or error event was produced.
func is_done() -> bool:
	return _done


## Decodes the next event, or returns [code]{}[/code] if more bytes are needed.
func next() -> Dictionary:
	while not _done:
		if _f_active:
			# Accumulate (and unmask) whatever part of the payload has arrived, so large messages
			# spread their unmasking cost over the frames in which the bytes arrive.
			var take := mini(_f_len - _f_got, _buf.size() - _off)
			if take > 0:
				var chunk := _buf.slice(_off, _off + take)
				if _f_key.size() == 4:
					chunk = PMCWsFrame.xor_mask(chunk, _f_key, _f_got)
				if _f_got == 0:
					_f_payload = chunk
				else:
					_f_payload.append_array(chunk)
				_f_got += take
				_off += take
				_compact()
			if _f_got < _f_len:
				return {}
			_f_active = false
			var ev := _dispatch(_f_op, _f_fin, _f_payload)
			_f_payload = PackedByteArray()
			if not ev.is_empty():
				return ev
			continue
		var avail := _buf.size() - _off
		if avail < 2:
			return {}
		var b0 := _buf[_off]
		var b1 := _buf[_off + 1]
		var fin := (b0 & 0x80) != 0
		var op := b0 & 0x0F
		var masked := (b1 & 0x80) != 0
		var len := b1 & 0x7F
		var hdr := 2
		if (b0 & 0x70) != 0:
			return _fail(1002, "reserved bits set")
		if (op > 2 and op < 8) or op > 10:
			return _fail(1002, "unknown opcode")
		if require_mask and not masked:
			return _fail(1002, "unmasked client frame")
		if len == 126:
			if avail < 4:
				return {}
			len = (_buf[_off + 2] << 8) | _buf[_off + 3]
			hdr = 4
		elif len == 127:
			if avail < 10:
				return {}
			if (_buf[_off + 2] & 0x80) != 0:
				return _fail(1002, "bad payload length")
			len = 0
			for i in 8:
				len = (len << 8) | _buf[_off + 2 + i]
			hdr = 10
		var control := op >= 8
		if control:
			if not fin:
				return _fail(1002, "fragmented control frame")
			if len > 125:
				return _fail(1002, "control frame too long")
		else:
			if op == 0 and _frag_op < 0:
				return _fail(1002, "unexpected continuation")
			if op != 0 and _frag_op >= 0:
				return _fail(1002, "expected continuation")
			if _frag_size + len > max_message_bytes:
				return _fail(1009, "message too big")
		if masked:
			hdr += 4
		if avail < hdr:
			return {}
		_f_key = _buf.slice(_off + hdr - 4, _off + hdr) if masked else PackedByteArray()
		_off += hdr
		_compact()
		_f_active = true
		_f_op = op
		_f_fin = fin
		_f_len = len
		_f_got = 0
		_f_payload = PackedByteArray()
	return {}


func _dispatch(op: int, fin: bool, payload: PackedByteArray) -> Dictionary:
	match op:
		PMCWsFrame.OP_PING:
			return {"op": "ping", "data": payload}
		PMCWsFrame.OP_PONG:
			return {"op": "pong", "data": payload}
		PMCWsFrame.OP_CLOSE:
			return _close_event(payload)
	if not fin:
		if op != 0:
			_frag_op = op
		_frag_parts.append(payload)
		_frag_size += payload.size()
		return {}
	var full_op := op
	if op == 0:
		full_op = _frag_op
		_frag_parts.append(payload)
		payload = _join(_frag_parts)
		_frag_parts.clear()
		_frag_size = 0
		_frag_op = -1
	if full_op == PMCWsFrame.OP_TEXT:
		var s := payload.get_string_from_utf8()
		if payload.size() > 0 and s.to_utf8_buffer() != payload:
			return _fail(1007, "invalid UTF-8")
		return {"op": "text", "data": s}
	return {"op": "binary", "data": payload}


func _close_event(payload: PackedByteArray) -> Dictionary:
	_done = true
	if payload.size() == 0:
		return {"op": "close", "code": 1005, "reason": ""}
	if payload.size() == 1:
		return _fail(1002, "bad close payload")
	var code := (payload[0] << 8) | payload[1]
	if not PMCWsFrame.is_valid_close_code(code):
		return _fail(1002, "bad close code")
	var rb := payload.slice(2)
	var reason := rb.get_string_from_utf8()
	if reason.to_utf8_buffer() != rb:
		return _fail(1007, "invalid UTF-8 in close reason")
	return {"op": "close", "code": code, "reason": reason}


func _fail(code: int, reason: String) -> Dictionary:
	_done = true
	_buf = PackedByteArray()
	_off = 0
	_frag_parts.clear()
	_f_active = false
	_f_payload = PackedByteArray()
	return {"op": "error", "code": code, "reason": reason}


func _compact() -> void:
	if _off == _buf.size():
		_buf = PackedByteArray()
		_off = 0
	elif _off > 65536 and _off * 2 > _buf.size():
		_buf = _buf.slice(_off)
		_off = 0


static func _join(parts: Array[PackedByteArray]) -> PackedByteArray:
	if parts.size() == 1:
		return parts[0]
	var out := PackedByteArray()
	for p in parts:
		out.append_array(p)
	return out
