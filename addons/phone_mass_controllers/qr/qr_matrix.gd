@tool
class_name PMCQrMatrix
extends RefCounted
## A finished QR Code symbol: a square grid of dark/light modules.
##
## Produced by [method PMCQr.encode]. The grid does not include the quiet zone.

## Width and height in modules (17 + 4 * version).
var size: int = 0
## QR version, 1..40.
var version: int = 0
## Error correction level used (0 = L, 1 = M, 2 = Q, 3 = H).
var ecc: int = 0
## Mask pattern applied, 0..7.
var mask: int = 0
## Encoding mode used for the payload: "numeric", "alphanumeric" or "byte".
var mode: String = ""

## Row-major module data, 1 = dark. Index is [code]y * size + x[/code].
var modules: PackedByteArray = PackedByteArray()


## Returns true if the module at column [param x], row [param y] is dark.
## Coordinates outside the symbol return false (light, like the quiet zone).
func get_module(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= size or y >= size:
		return false
	return modules[y * size + x] != 0


## Returns the matrix as an array of strings, one per row, "1" for dark and "0" for light.
## Handy for debugging and for cross-checking against other encoders.
func to_rows() -> PackedStringArray:
	var rows := PackedStringArray()
	for y in size:
		var line := ""
		for x in size:
			line += "1" if modules[y * size + x] != 0 else "0"
		rows.append(line)
	return rows
