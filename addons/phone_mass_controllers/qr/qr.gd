@tool
class_name PMCQr
extends RefCounted
## Pure GDScript QR Code (Model 2) encoder.
##
## Supports numeric, alphanumeric and byte (UTF-8) modes, error correction levels
## L/M/Q/H, versions 1-40, Reed-Solomon over GF(256), and automatic mask selection
## using the standard penalty rules.
## [codeblock]
## var m := PMCQr.encode("http://192.168.1.87:8086/?code=ABCD")
## var tex := ImageTexture.create_from_image(PMCQr.to_image(m))
## [/codeblock]

## Error correction level L (~7% recovery).
const ECC_L := 0
## Error correction level M (~15% recovery).
const ECC_M := 1
## Error correction level Q (~25% recovery).
const ECC_Q := 2
## Error correction level H (~30% recovery).
const ECC_H := 3

const _ALNUM := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

# Indexed [ecc][version]; index 0 is unused padding.
const _ECC_CODEWORDS_PER_BLOCK := [
	[-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
	[-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
]
const _NUM_ERROR_CORRECTION_BLOCKS := [
	[-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
	[-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
	[-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
	[-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
]
# Format-info bits for each ECC level (L=01, M=00, Q=11, H=10).
const _ECC_FORMAT_BITS := [1, 0, 3, 2]

const _PENALTY_N1 := 3
const _PENALTY_N2 := 3
const _PENALTY_N3 := 40
const _PENALTY_N4 := 10

static var _gf_exp: PackedInt32Array
static var _gf_log: PackedInt32Array
static var _divisors: Dictionary = {}


## Encodes [param text] with error correction level [param ecc] (0=L, 1=M, 2=Q, 3=H),
## choosing the smallest version that fits and the best mask.
## Returns null if the text does not fit in version 40.
static func encode(text: String, ecc := 1) -> PMCQrMatrix:
	return encode_advanced(text, ecc)


## Like [method encode] but with control over the version range and mask.
## [param mode] may be "" (auto), "numeric", "alphanumeric" or "byte".
## [param mask] of -1 selects the mask with the lowest penalty.
## Returns null if the text cannot be encoded within [param max_version] or the mode is invalid.
static func encode_advanced(text: String, ecc := 1, min_version := 1, max_version := 40, mask := -1, mode := "") -> PMCQrMatrix:
	ecc = clampi(ecc, 0, 3)
	min_version = clampi(min_version, 1, 40)
	max_version = clampi(max_version, min_version, 40)
	if mode == "":
		mode = _pick_mode(text)
	var payload: PackedByteArray
	var char_count := 0
	match mode:
		"numeric":
			if not _is_numeric(text):
				return null
			char_count = text.length()
		"alphanumeric":
			if not _is_alphanumeric(text):
				return null
			char_count = text.length()
		"byte":
			payload = text.to_utf8_buffer()
			char_count = payload.size()
		_:
			return null

	var version := -1
	for v in range(min_version, max_version + 1):
		var cap_bits := _num_data_codewords(v, ecc) * 8
		var used := 4 + _char_count_bits(mode, v) + _payload_bits(mode, char_count)
		if char_count < (1 << _char_count_bits(mode, v)) and used <= cap_bits:
			version = v
			break
	if version < 0:
		return null

	# Build the bit stream.
	var bits := PackedByteArray()
	_append_bits(bits, {"numeric": 1, "alphanumeric": 2, "byte": 4}[mode], 4)
	_append_bits(bits, char_count, _char_count_bits(mode, version))
	match mode:
		"numeric":
			var i := 0
			while i < char_count:
				var n := mini(3, char_count - i)
				_append_bits(bits, text.substr(i, n).to_int(), n * 3 + 1)
				i += n
		"alphanumeric":
			var i := 0
			while i < char_count:
				if i + 1 < char_count:
					_append_bits(bits, _ALNUM.find(text[i]) * 45 + _ALNUM.find(text[i + 1]), 11)
					i += 2
				else:
					_append_bits(bits, _ALNUM.find(text[i]), 6)
					i += 1
		"byte":
			for b in payload:
				_append_bits(bits, b, 8)

	var capacity_bits := _num_data_codewords(version, ecc) * 8
	_append_bits(bits, 0, mini(4, capacity_bits - bits.size()))
	_append_bits(bits, 0, (8 - bits.size() % 8) % 8)
	var data := PackedByteArray()
	data.resize(bits.size() >> 3)
	for i in bits.size():
		if bits[i] != 0:
			data[i >> 3] |= 0x80 >> (i & 7)
	var pad := 0xEC
	while data.size() * 8 < capacity_bits:
		data.append(pad)
		pad = 0x11 if pad == 0xEC else 0xEC

	var codewords := _add_ecc_and_interleave(data, version, ecc)
	var m := _build_matrix(codewords, version, ecc, mask)
	m.mode = mode
	return m


## Renders [param m] as a black-on-white RGB8 image with [param module_px] pixels per module
## and a quiet zone of [param quiet] modules on each side.
static func to_image(m: PMCQrMatrix, module_px := 8, quiet := 4) -> Image:
	module_px = maxi(1, module_px)
	quiet = maxi(0, quiet)
	var n := m.size * m.size
	# Module bytes 0/1 -> luminance 255/0, eight bytes at a time.
	var bytes := m.modules.duplicate()
	bytes.resize((n + 7) & ~7)
	var words := bytes.to_int64_array()
	for i in words.size():
		var x := words[i]
		x |= x << 1
		x |= x << 2
		x |= x << 4
		words[i] = ~x
	bytes = words.to_byte_array()
	bytes.resize(n)
	var symbol := Image.create_from_data(m.size, m.size, false, Image.FORMAT_L8, bytes)
	var across := m.size + quiet * 2
	var img := Image.create(across, across, false, Image.FORMAT_L8)
	img.fill(Color.WHITE)
	img.blit_rect(symbol, Rect2i(0, 0, m.size, m.size), Vector2i(quiet, quiet))
	img.convert(Image.FORMAT_RGB8)
	if module_px > 1:
		img.resize(across * module_px, across * module_px, Image.INTERPOLATE_NEAREST)
	return img


# ---------------------------------------------------------------------------
# Segment helpers

static func _is_numeric(text: String) -> bool:
	for i in text.length():
		var c := text.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true


static func _is_alphanumeric(text: String) -> bool:
	for i in text.length():
		if _ALNUM.find(text[i]) < 0:
			return false
	return true


static func _pick_mode(text: String) -> String:
	if text.length() > 0 and _is_numeric(text):
		return "numeric"
	if text.length() > 0 and _is_alphanumeric(text):
		return "alphanumeric"
	return "byte"


static func _char_count_bits(mode: String, version: int) -> int:
	var idx := 0 if version <= 9 else (1 if version <= 26 else 2)
	match mode:
		"numeric":
			return [10, 12, 14][idx]
		"alphanumeric":
			return [9, 11, 13][idx]
	return [8, 16, 16][idx]


@warning_ignore("integer_division")
static func _payload_bits(mode: String, count: int) -> int:
	match mode:
		"numeric":
			return count / 3 * 10 + [0, 4, 7][count % 3]
		"alphanumeric":
			return count / 2 * 11 + (count % 2) * 6
	return count * 8


static func _append_bits(bits: PackedByteArray, value: int, length: int) -> void:
	for i in range(length - 1, -1, -1):
		bits.append((value >> i) & 1)


# ---------------------------------------------------------------------------
# Capacity

@warning_ignore("integer_division")
static func _num_raw_data_modules(ver: int) -> int:
	var result := (16 * ver + 128) * ver + 64
	if ver >= 2:
		var num_align := ver / 7 + 2
		result -= (25 * num_align - 10) * num_align - 55
		if ver >= 7:
			result -= 36
	return result


@warning_ignore("integer_division")
static func _num_data_codewords(ver: int, ecc: int) -> int:
	return _num_raw_data_modules(ver) / 8 - _ECC_CODEWORDS_PER_BLOCK[ecc][ver] * _NUM_ERROR_CORRECTION_BLOCKS[ecc][ver]


# ---------------------------------------------------------------------------
# Reed-Solomon over GF(256), primitive polynomial 0x11D

static func _init_gf() -> void:
	if _gf_exp.size() == 512:
		return
	var exp := PackedInt32Array()
	exp.resize(512)
	var log := PackedInt32Array()
	log.resize(256)
	var x := 1
	for i in 255:
		exp[i] = x
		log[x] = i
		x <<= 1
		if x & 0x100:
			x ^= 0x11D
	for i in range(255, 512):
		exp[i] = exp[i - 255]
	_gf_exp = exp
	_gf_log = log


static func _gf_mul(a: int, b: int) -> int:
	if a == 0 or b == 0:
		return 0
	return _gf_exp[_gf_log[a] + _gf_log[b]]


static func _rs_divisor(degree: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	result.resize(degree)
	result[degree - 1] = 1
	var root := 1
	for i in degree:
		for j in degree:
			result[j] = _gf_mul(result[j], root)
			if j + 1 < degree:
				result[j] ^= result[j + 1]
		root = _gf_mul(root, 2)
	return result


static func _rs_remainder(data: PackedByteArray, divisor: PackedInt32Array) -> PackedByteArray:
	var n := divisor.size()
	# Generator polynomial coefficients are never zero, so their logs are always defined.
	var div_log := PackedInt32Array()
	div_log.resize(n)
	for i in n:
		div_log[i] = _gf_log[divisor[i]]
	var result := PackedInt32Array()
	result.resize(n)
	var exp := _gf_exp
	for b in data:
		var factor: int = b ^ result[0]
		result = result.slice(1)
		result.append(0)
		if factor != 0:
			var flog := _gf_log[factor]
			for i in n:
				result[i] ^= exp[div_log[i] + flog]
	var out := PackedByteArray()
	out.resize(n)
	for i in n:
		out[i] = result[i]
	return out


@warning_ignore("integer_division")
static func _add_ecc_and_interleave(data: PackedByteArray, ver: int, ecc: int) -> PackedByteArray:
	_init_gf()
	var num_blocks: int = _NUM_ERROR_CORRECTION_BLOCKS[ecc][ver]
	var block_ecc_len: int = _ECC_CODEWORDS_PER_BLOCK[ecc][ver]
	var raw_codewords := _num_raw_data_modules(ver) / 8
	var num_short_blocks := num_blocks - raw_codewords % num_blocks
	var short_block_len := raw_codewords / num_blocks

	if not _divisors.has(block_ecc_len):
		_divisors[block_ecc_len] = _rs_divisor(block_ecc_len)
	var divisor: PackedInt32Array = _divisors[block_ecc_len]
	var data_blocks: Array[PackedByteArray] = []
	var ecc_blocks: Array[PackedByteArray] = []
	var k := 0
	for i in num_blocks:
		var dat_len := short_block_len - block_ecc_len + (0 if i < num_short_blocks else 1)
		var dat := data.slice(k, k + dat_len)
		k += dat_len
		data_blocks.append(dat)
		ecc_blocks.append(_rs_remainder(dat, divisor))

	var result := PackedByteArray()
	var long_len := short_block_len - block_ecc_len + (1 if num_short_blocks < num_blocks else 0)
	for i in long_len:
		for j in num_blocks:
			if i < data_blocks[j].size():
				result.append(data_blocks[j][i])
	for i in block_ecc_len:
		for j in num_blocks:
			result.append(ecc_blocks[j][i])
	return result




# ---------------------------------------------------------------------------
# Matrix construction
#
# Each candidate symbol is held twice: as rows and as columns (transposed). Both use a byte
# layout of one separator byte (value 2) before every line plus one at the end, padded with 2s
# to a multiple of 8. Masking then runs on 64-bit words, and the penalty rules run as native
# regex searches and byte counts instead of per-module script loops. Everything that depends
# only on the version (function patterns, data placement order, mask patterns) is cached.

const _SEP := 2
const _ASCII_WORD := 0x3030303030303030

static var _layouts: Dictionary = {}


static func _build_matrix(codewords: PackedByteArray, ver: int, ecc: int, forced_mask: int) -> PMCQrMatrix:
	var lay := _layout(ver)
	var size := ver * 4 + 17
	var w := size + 1
	var r: PackedByteArray = (lay.base_r as PackedByteArray).duplicate()
	var c: PackedByteArray = (lay.base_c as PackedByteArray).duplicate()
	var order_r: PackedInt32Array = lay.order_r
	var order_c: PackedInt32Array = lay.order_c
	var total := mini(codewords.size() * 8, order_r.size())
	var i := 0
	for byte in codewords:
		for k in 8:
			if i >= total:
				break
			var bit := (byte >> (7 - k)) & 1
			r[order_r[i]] = bit
			c[order_c[i]] = bit
			i += 1

	var masks_r: Array = lay.masks_r
	var masks_c: Array = lay.masks_c
	var fmt_pos: Array = lay.format_pos
	var rw := r.to_int64_array()
	var best := forced_mask
	var best_r: PackedByteArray
	if best >= 0 and best <= 7:
		best_r = _xor_words(rw, masks_r[best]).to_byte_array()
		_put_format(best_r, PackedByteArray(), fmt_pos, ecc, best)
	else:
		var cw := c.to_int64_array()
		var min_penalty := 1 << 62
		for msk in 8:
			var mr := _xor_words(rw, masks_r[msk]).to_byte_array()
			var mc := _xor_words(cw, masks_c[msk]).to_byte_array()
			_put_format(mr, mc, fmt_pos, ecc, msk)
			var p := _penalty(mr, mc, size)
			if p < min_penalty:
				min_penalty = p
				best = msk
				best_r = mr

	var out := PackedByteArray()
	for y in size:
		var start := y * w + 1
		out.append_array(best_r.slice(start, start + size))
	var m := PMCQrMatrix.new()
	m.size = size
	m.version = ver
	m.ecc = ecc
	m.mask = best
	m.modules = out
	return m


static func _layout(ver: int) -> Dictionary:
	if _layouts.has(ver):
		return _layouts[ver]
	var size := ver * 4 + 17
	var w := size + 1
	var n := size * w + 1
	var padded := (n + 7) & ~7

	var mods := PackedByteArray()
	mods.resize(size * size)
	var fm := PackedByteArray()
	fm.resize(size * size)
	_draw_function_patterns(mods, fm, size, ver)

	var base_r := PackedByteArray()
	base_r.resize(padded)
	base_r.fill(_SEP)
	var base_c := base_r.duplicate()
	var free_r := PackedByteArray()
	free_r.resize(padded)
	free_r.fill(0)
	var free_c := free_r.duplicate()
	for y in size:
		for x in size:
			var ri := y * w + 1 + x
			var ci := x * w + 1 + y
			var v := mods[y * size + x]
			base_r[ri] = v
			base_c[ci] = v
			if fm[y * size + x] == 0:
				free_r[ri] = 1
				free_c[ci] = 1

	# Data placement order: two-module-wide columns, zig-zagging from the bottom right.
	var order_r := PackedInt32Array()
	var order_c := PackedInt32Array()
	var right := size - 1
	while right >= 1:
		if right == 6:
			right = 5
		var upward := ((right + 1) & 2) == 0
		for vert in size:
			var y := size - 1 - vert if upward else vert
			for j in 2:
				var x := right - j
				if fm[y * size + x] == 0:
					order_r.append(y * w + 1 + x)
					order_c.append(x * w + 1 + y)
		right -= 2

	var free_r_words := free_r.to_int64_array()
	var free_c_words := free_c.to_int64_array()
	var masks_r: Array[PackedInt64Array] = []
	var masks_c: Array[PackedInt64Array] = []
	for msk in 8:
		masks_r.append(_and_words(_mask_pattern(msk, size, padded, false), free_r_words))
		masks_c.append(_and_words(_mask_pattern(msk, size, padded, true), free_c_words))

	var fmt_pos: Array[Vector3i] = []
	for p in _format_positions(size):
		fmt_pos.append(Vector3i(p.y * w + 1 + p.x, p.x * w + 1 + p.y, p.z))

	var lay := {
		"base_r": base_r, "base_c": base_c, "order_r": order_r, "order_c": order_c,
		"masks_r": masks_r, "masks_c": masks_c, "format_pos": fmt_pos,
	}
	_layouts[ver] = lay
	return lay


# Words with byte 1 wherever mask [param msk] inverts a module (separators 0).
@warning_ignore("integer_division")
static func _mask_pattern(msk: int, size: int, padded: int, transposed: bool) -> PackedInt64Array:
	# Every mask pattern repeats with period 12 on both axes.
	var lines: Array[String] = []
	for a in 12:
		var unit := ""
		for b in 12:
			var x := a if transposed else b
			var y := b if transposed else a
			var inv := false
			match msk:
				0: inv = (x + y) % 2 == 0
				1: inv = y % 2 == 0
				2: inv = x % 3 == 0
				3: inv = (x + y) % 3 == 0
				4: inv = (x / 3 + y / 2) % 2 == 0
				5: inv = x * y % 2 + x * y % 3 == 0
				6: inv = (x * y % 2 + x * y % 3) % 2 == 0
				7: inv = ((x + y) % 2 + x * y % 3) % 2 == 0
			unit += "1" if inv else "0"
		lines.append("0" + unit.repeat(size / 12 + 1).substr(0, size))
	var parts := PackedStringArray()
	for a in size:
		parts.append(lines[a % 12])
	var s := "".join(parts)
	s += "0".repeat(padded - s.length())
	return _xor_const(s.to_ascii_buffer().to_int64_array(), _ASCII_WORD)


# (x, y, bit index) for both copies of the 15 format bits.
static func _format_positions(size: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for i in 6:
		out.append(Vector3i(8, i, i))
	out.append(Vector3i(8, 7, 6))
	out.append(Vector3i(8, 8, 7))
	out.append(Vector3i(7, 8, 8))
	for i in range(9, 15):
		out.append(Vector3i(14 - i, 8, i))
	for i in 8:
		out.append(Vector3i(size - 1 - i, 8, i))
	for i in range(8, 15):
		out.append(Vector3i(8, size - 15 + i, i))
	return out


static func _format_bits(ecc: int, msk: int) -> int:
	var data: int = (_ECC_FORMAT_BITS[ecc] << 3) | msk
	var rem := data
	for i in 10:
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	return ((data << 10) | rem) ^ 0x5412


static func _put_format(mr: PackedByteArray, mc: PackedByteArray, fmt_pos: Array, ecc: int, msk: int) -> void:
	var bits := _format_bits(ecc, msk)
	var has_c := not mc.is_empty()
	for p: Vector3i in fmt_pos:
		var v := (bits >> p.z) & 1
		mr[p.x] = v
		if has_c:
			mc[p.y] = v


static func _xor_words(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var out := a.duplicate()
	for i in out.size():
		out[i] ^= b[i]
	return out


static func _and_words(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var out := a.duplicate()
	for i in out.size():
		out[i] &= b[i]
	return out


static func _xor_const(a: PackedInt64Array, k: int) -> PackedInt64Array:
	for i in a.size():
		a[i] ^= k
	return a


static func _pad8(a: PackedByteArray, v: int) -> PackedInt64Array:
	var n := a.size()
	var p := (8 - n % 8) % 8
	a.resize(n + p)
	for k in p:
		a[n + k] = v
	return a.to_int64_array()


# Standard penalty rules N1 (runs), N2 (2x2 blocks), N3 (finder-like), N4 (dark balance).
static func _penalty(mr: PackedByteArray, mc: PackedByteArray, size: int) -> int:
	var w := size + 1
	var result := 0
	var span := size * w - 4
	for arr: PackedByteArray in [mr, mc]:
		# N1: a run of length L >= 5 scores L - 2 = 3 * (5-windows) - 2 * (6-windows).
		var a := _pad8(arr.slice(0, span), 3)
		var b := _pad8(arr.slice(1, span + 1), 4)
		var c := _pad8(arr.slice(2, span + 2), 5)
		var d := _pad8(arr.slice(3, span + 3), 6)
		var e := _pad8(arr.slice(4, span + 4), 7)
		var f := _pad8(arr.slice(5, span + 5), 8)
		for i in a.size():
			var ai := a[i]
			var acc := (ai ^ b[i]) | (ai ^ c[i]) | (ai ^ d[i]) | (ai ^ e[i])
			b[i] = acc
			c[i] = acc | (ai ^ f[i])
		result += 3 * b.to_byte_array().count(0) - 2 * c.to_byte_array().count(0)
		# N3: 1:1:3:1:1 with four light modules on one side (the border counts as light).
		var s := _xor_const(arr.to_int64_array(), _ASCII_WORD).to_byte_array().get_string_from_ascii().replace("2", "0000")
		result += (s.count("000010111010") + s.count("010111010000")) * _PENALTY_N3

	# N2: 2x2 blocks of one color.
	var span2 := (size - 1) * w
	var p := _pad8(mr.slice(0, span2), 3)
	var q := _pad8(mr.slice(1, span2 + 1), 4)
	var r := _pad8(mr.slice(w, w + span2), 5)
	var t := _pad8(mr.slice(w + 1, w + 1 + span2), 6)
	for i in p.size():
		var pi := p[i]
		p[i] = (pi ^ q[i]) | (pi ^ r[i]) | (pi ^ t[i])
	result += p.to_byte_array().count(0) * _PENALTY_N2

	# N4: dark/light balance.
	var dark := mr.count(1)
	var total := size * size
	var k := ceili(absi(dark * 20 - total * 10) / float(total)) - 1
	result += k * _PENALTY_N4
	return result



@warning_ignore("integer_division")
static func _draw_function_patterns(mods: PackedByteArray, func_mask: PackedByteArray, size: int, ver: int) -> void:
	# Timing patterns.
	for i in size:
		_set_func(mods, func_mask, size, 6, i, i % 2 == 0)
		_set_func(mods, func_mask, size, i, 6, i % 2 == 0)
	# Finder patterns with separators.
	for c: Vector2i in [Vector2i(3, 3), Vector2i(size - 4, 3), Vector2i(3, size - 4)]:
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				var xx := c.x + dx
				var yy := c.y + dy
				if xx >= 0 and xx < size and yy >= 0 and yy < size:
					var dist := maxi(absi(dx), absi(dy))
					_set_func(mods, func_mask, size, xx, yy, dist != 2 and dist != 4)
	# Alignment patterns.
	var pos := _alignment_positions(ver, size)
	var n := pos.size()
	for i in n:
		for j in n:
			if (i == 0 and j == 0) or (i == 0 and j == n - 1) or (i == n - 1 and j == 0):
				continue
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					_set_func(mods, func_mask, size, pos[i] + dx, pos[j] + dy, maxi(absi(dx), absi(dy)) != 1)
	# Reserve the format areas (real bits are written per mask) and set the always-dark module.
	for p in _format_positions(size):
		_set_func(mods, func_mask, size, p.x, p.y, false)
	_set_func(mods, func_mask, size, 8, size - 8, true)
	# Version information (versions 7+).
	if ver >= 7:
		var rem := ver
		for i in 12:
			rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
		var bits := (ver << 12) | rem
		for i in 18:
			var bit := ((bits >> i) & 1) != 0
			var a := size - 11 + i % 3
			var b := i / 3
			_set_func(mods, func_mask, size, a, b, bit)
			_set_func(mods, func_mask, size, b, a, bit)


static func _set_func(mods: PackedByteArray, func_mask: PackedByteArray, size: int, x: int, y: int, dark: bool) -> void:
	mods[y * size + x] = 1 if dark else 0
	func_mask[y * size + x] = 1


@warning_ignore("integer_division")
static func _alignment_positions(ver: int, size: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	if ver == 1:
		return result
	var num_align := ver / 7 + 2
	var step := (ver * 8 + num_align * 3 + 5) / (num_align * 4 - 4) * 2
	result.resize(num_align)
	result[0] = 6
	var p := size - 7
	for i in range(num_align - 1, 0, -1):
		result[i] = p
		p -= step
	return result
