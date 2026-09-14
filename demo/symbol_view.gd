extends Control
## Draws one Buzzer Party symbol (procedural shapes, no textures) with a small pop when it changes.

var shape := ""
var color := Color.WHITE
var _pop := 1.0


func show_symbol(p_shape: String, p_color: Color, animate := true) -> void:
	if p_shape == shape and p_color == color:
		return
	shape = p_shape
	color = p_color
	_pop = 0.6 if animate else 1.0
	queue_redraw()


func clear() -> void:
	shape = ""
	queue_redraw()


func _process(delta: float) -> void:
	if _pop < 1.0:
		_pop = minf(1.0, _pop + delta * 5.0)
		queue_redraw()


func _draw() -> void:
	if shape == "":
		return
	var c := size / 2.0
	var ease_pop := 1.0 + sin(clampf((_pop - 0.6) / 0.4, 0.0, 1.0) * PI) * 0.12
	var r := minf(size.x, size.y) * 0.42 * ease_pop * clampf(_pop + 0.2, 0.0, 1.0)
	if r <= 1.0:
		return
	# Soft shadow first, then the shape.
	_draw_shape(c + Vector2(0, r * 0.08), r, Color(0, 0, 0, 0.28))
	_draw_shape(c, r, color)


func _draw_shape(c: Vector2, r: float, col: Color) -> void:
	match shape:
		"circle":
			draw_circle(c, r, col, true, -1.0, true)
		"ring":
			draw_arc(c, r * 0.78, 0, TAU, 96, col, r * 0.36, true)
		"square":
			_poly(_rounded_rect(Rect2(c - Vector2(r, r) * 0.88, Vector2(r, r) * 1.76), r * 0.2), col)
		"triangle":
			_poly(_regular(c + Vector2(0, r * 0.15), r * 1.05, 3, -PI / 2), col)
		"diamond":
			_poly(PackedVector2Array([c + Vector2(0, -r), c + Vector2(r * 0.82, 0), c + Vector2(0, r), c + Vector2(-r * 0.82, 0)]), col)
		"hexagon":
			_poly(_regular(c, r, 6, 0.0), col)
		"star":
			var pts := PackedVector2Array()
			for i in 10:
				var a := -PI / 2 + i * PI / 5
				pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
			_poly(pts, col)
		"heart":
			var pts := PackedVector2Array()
			for i in 64:
				var t := TAU * i / 64.0
				var x := 16.0 * pow(sin(t), 3)
				var y := 13.0 * cos(t) - 5.0 * cos(2 * t) - 2.0 * cos(3 * t) - cos(4 * t)
				pts.append(c + Vector2(x, -y) * (r / 16.0) + Vector2(0, -r * 0.05))
			_poly(pts, col)


func _poly(pts: PackedVector2Array, col: Color) -> void:
	draw_colored_polygon(pts, col)
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, col, 2.0, true) # anti-aliased edge


func _regular(c: Vector2, r: float, n: int, start: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := start + TAU * i / n
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts


func _rounded_rect(rect: Rect2, rad: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var corners := [
		[rect.position + Vector2(rect.size.x - rad, rad), -PI / 2],
		[rect.position + rect.size - Vector2(rad, rad), 0.0],
		[rect.position + Vector2(rad, rect.size.y - rad), PI / 2],
		[rect.position + Vector2(rad, rad), PI],
	]
	for corner in corners:
		for i in 7:
			var a: float = corner[1] + (PI / 2) * i / 6.0
			pts.append(corner[0] + Vector2(cos(a), sin(a)) * rad)
	return pts
