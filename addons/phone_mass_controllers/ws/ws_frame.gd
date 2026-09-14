class_name PMCWsFrame
extends RefCounted
## RFC 6455 frame encoding helpers. Internal. Server frames are unmasked. Masked encoding exists for test clients.

const OP_CONTINUATION := 0x0
const OP_TEXT := 0x1
const OP_BINARY := 0x2
const OP_CLOSE := 0x8
const OP_PING := 0x9
const OP_PONG := 0xA

const GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


## Encodes one frame. When [param mask_key] has 4 bytes, the payload is masked (client-style).
static func encode(opcode: int, payload: PackedByteArray, fin := true, mask_key := PackedByteArray()) -> PackedByteArray:
	var n := payload.size()
	var masked := mask_key.size() == 4
	var out := PackedByteArray()
	out.append((0x80 if fin else 0) | (opcode & 0x0F))
	var mbit := 0x80 if masked else 0
	if n < 126:
		out.append(mbit | n)
	elif n < 65536:
		out.append(mbit | 126)
		out.append((n >> 8) & 0xFF)
		out.append(n & 0xFF)
	else:
		out.append(mbit | 127)
		for i in range(7, -1, -1):
			out.append((n >> (i * 8)) & 0xFF)
	if masked:
		out.append_array(mask_key)
		out.append_array(xor_mask(payload, mask_key))
	else:
		out.append_array(payload)
	return out


## A text frame.
static func text(s: String) -> PackedByteArray:
	return encode(OP_TEXT, s.to_utf8_buffer())


## A binary frame.
static func binary(data: PackedByteArray) -> PackedByteArray:
	return encode(OP_BINARY, data)


## A close frame with [param code] and a UTF-8 [param reason] (truncated so the payload fits 125 bytes).
static func close(code: int, reason := "") -> PackedByteArray:
	var p := PackedByteArray()
	if code > 0:
		p.append((code >> 8) & 0xFF)
		p.append(code & 0xFF)
		var r := reason.to_utf8_buffer()
		if r.size() > 123:
			r = r.slice(0, 123)
			# Don't cut through a multi-byte sequence.
			while r.size() > 0 and (r[r.size() - 1] & 0xC0) == 0x80:
				r.resize(r.size() - 1)
			if r.size() > 0 and (r[r.size() - 1] & 0xC0) == 0xC0:
				r.resize(r.size() - 1)
		p.append_array(r)
	return encode(OP_CLOSE, p)


## A ping frame.
static func ping(data := PackedByteArray()) -> PackedByteArray:
	return encode(OP_PING, data)


## A pong frame.
static func pong(data := PackedByteArray()) -> PackedByteArray:
	return encode(OP_PONG, data)


## [code]Sec-WebSocket-Accept[/code] value for a client key.
static func accept_key(key: String) -> String:
	return Marshalls.raw_to_base64((key + GUID).sha1_buffer())


## Whether [param code] may be sent in a close frame (RFC 6455 7.4).
static func is_valid_close_code(code: int) -> bool:
	if code >= 3000 and code <= 4999:
		return true
	return code in [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014]


## XORs [param data] with the 4-byte [param key] (masking is symmetric). 8 bytes per step for speed.
## [param offset] is the position of [code]data[0][/code] within the whole payload (for chunked unmasking).
static func xor_mask(data: PackedByteArray, key: PackedByteArray, offset := 0) -> PackedByteArray:
	var n := data.size()
	if n == 0:
		return data
	if offset & 3 != 0:
		var o := offset & 3
		key = PackedByteArray([key[o], key[(o + 1) & 3], key[(o + 2) & 3], key[(o + 3) & 3]])
	if n < 8:
		var out := data.duplicate()
		for i in n:
			out[i] = out[i] ^ key[i & 3]
		return out
	# Pad to a multiple of 8, XOR 64-bit words, then trim. The padding bytes are discarded.
	var padded := data
	if n & 7 != 0:
		padded = data.duplicate()
		padded.resize((n + 7) & ~7)
	var k8 := PackedByteArray([key[0], key[1], key[2], key[3], key[0], key[1], key[2], key[3]])
	var m := k8.decode_s64(0)
	var words := padded.to_int64_array()
	for i in words.size():
		words[i] = words[i] ^ m
	var result := words.to_byte_array()
	if result.size() != n:
		result.resize(n)
	return result
