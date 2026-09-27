extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Building-only battlefield rendering. BoardView still owns camera/input and
## delegates the actual building visuals here.

static func health_color(frac: float) -> Color:
	var f := clampf(frac, 0.0, 1.0)
	var red := Color("d83a2f")
	var yellow := Color("e0b43c")
	var green := Color("55b85a")
	if f >= 0.5:
		return yellow.lerp(green, (f - 0.5) * 2.0)
	return red.lerp(yellow, f * 2.0)


static func draw(v: BoardView) -> void:
	var m = v.match_ref
	var px_cell: int = v.px_cell
	for r in m.rubble:
		if m.occupancy[r.y * UpConfigRef.GRID + r.x] != 0:
			continue
		var poly: PackedVector2Array = v.cell_polygon(r.x, r.y)
		v.draw_colored_polygon(poly, Color("6a6355"))
		var rr: Rect2 = v.cell_rect(r.x, r.y)
		v.draw_circle(v.cell_center(r.x, r.y), minf(rr.size.x, rr.size.y) * 0.14, Color("534d42"))

	for b: UpMatch.Building in m.buildings:
		draw_building(v, b.def, b.cells, b.hp, b.flash)


static func draw_building(v: BoardView, def: Dictionary, cells: Array, hp: int, flash: int = 0) -> void:
	# Shared player/reconnaissance renderer. Rival records use the exact same
	# footprint, roof, ridge, fixture and health-bar treatment as player buildings.
	if cells.is_empty():
		return

	var px_cell: int = v.px_cell
	var roof := Color(def["colour"])
	if flash > 0:
		roof = roof.lightened(0.5)

	var minx := 99
	var maxx := -1
	var miny := 99
	var maxy := -1
	var footprint := {}
	for c: Vector2i in cells:
		minx = min(minx, c.x)
		maxx = max(maxx, c.x)
		miny = min(miny, c.y)
		maxy = max(maxy, c.y)
		footprint[c] = true

	var roof_light := roof.lightened(0.15)
	var roof_dark := roof.darkened(0.24)
	var roof_edge := roof.darkened(0.40)
	var shadow := Color(0.08, 0.07, 0.06, 0.30)

	for c: Vector2i in cells:
		var poly: PackedVector2Array = v.cell_polygon(c.x, c.y)
		var shadow_poly: PackedVector2Array = PackedVector2Array()
		for pnt in poly:
			shadow_poly.append(pnt + Vector2(3.0, 4.0))
		v.draw_colored_polygon(shadow_poly, shadow)

	for c: Vector2i in cells:
		v.draw_colored_polygon(v.cell_polygon(c.x, c.y), roof)

	for c: Vector2i in cells:
		var poly: PackedVector2Array = v.cell_polygon(c.x, c.y)
		# TL, TR, BR, BL: every visible edge follows the courtyard perspective.
		if not footprint.has(Vector2i(c.x, c.y - 1)):
			v.draw_line(poly[0], poly[1], roof_light, 2.0)
		if not footprint.has(Vector2i(c.x - 1, c.y)):
			v.draw_line(poly[0], poly[3], roof_light, 2.0)
		if not footprint.has(Vector2i(c.x, c.y + 1)):
			v.draw_line(poly[3], poly[2], roof_dark, 2.0)
		if not footprint.has(Vector2i(c.x + 1, c.y)):
			v.draw_line(poly[1], poly[2], roof_dark, 2.0)

	var best_horizontal := 0
	var best_h_y := 0
	var best_h_x0 := 0
	var best_h_x1 := 0
	for yy in range(miny, maxy + 1):
		var run_start := -1
		for xx in range(minx, maxx + 2):
			var occupied := xx <= maxx and footprint.has(Vector2i(xx, yy))
			if occupied and run_start < 0:
				run_start = xx
			elif not occupied and run_start >= 0:
				var run_len := xx - run_start
				if run_len > best_horizontal:
					best_horizontal = run_len
					best_h_y = yy
					best_h_x0 = run_start
					best_h_x1 = xx - 1
				run_start = -1

	var best_vertical := 0
	var best_v_x := 0
	var best_v_y0 := 0
	var best_v_y1 := 0
	for xx in range(minx, maxx + 1):
		var run_start := -1
		for yy in range(miny, maxy + 2):
			var occupied := yy <= maxy and footprint.has(Vector2i(xx, yy))
			if occupied and run_start < 0:
				run_start = yy
			elif not occupied and run_start >= 0:
				var run_len := yy - run_start
				if run_len > best_vertical:
					best_vertical = run_len
					best_v_x = xx
					best_v_y0 = run_start
					best_v_y1 = yy - 1
				run_start = -1

	var ridge_col := roof_light.lightened(0.10)
	if best_horizontal >= best_vertical:
		var p0: Vector2 = v.cell_point(best_h_x0, best_h_y, 0.16, 0.48)
		var p1: Vector2 = v.cell_point(best_h_x1, best_h_y, 0.84, 0.48)
		v.draw_line(p0, p1, ridge_col, 2.0)
	else:
		var p0: Vector2 = v.cell_point(best_v_x, best_v_y0, 0.48, 0.16)
		var p1: Vector2 = v.cell_point(best_v_x, best_v_y1, 0.48, 0.84)
		v.draw_line(p0, p1, ridge_col, 2.0)

	var fixture_cell: Vector2i = cells[0]
	var best_center_dist := 1 << 30
	var cx := (minx + maxx) * UpConfigRef.CELL / 2
	var cy := (miny + maxy) * UpConfigRef.CELL / 2
	for c: Vector2i in cells:
		var ccx := c.x * UpConfigRef.CELL + UpConfigRef.CELL / 2
		var ccy := c.y * UpConfigRef.CELL + UpConfigRef.CELL / 2
		var dd := absi(ccx - cx) + absi(ccy - cy)
		if dd < best_center_dist:
			best_center_dist = dd
			fixture_cell = c
	var frc: Rect2 = v.cell_rect(fixture_cell.x, fixture_cell.y)
	var fp: Vector2 = v.cell_point(fixture_cell.x, fixture_cell.y, 0.66, 0.30)
	var fw := minf(frc.size.x, frc.size.y) * 0.16
	v.draw_rect(Rect2(fp.x - fw * 0.5, fp.y - fw * 0.5, fw, fw), roof_edge)
	v.draw_rect(Rect2(fp.x - fw * 0.5 + 1, fp.y - fw * 0.5 + 1, fw - 2, fw - 2), roof_light)

	var frac := clampf(float(hp) / float(def["hp"]), 0.0, 1.0)
	var south_minx := 99
	var south_maxx := -1
	for c in cells:
		if c.y == maxy:
			south_minx = min(south_minx, c.x)
			south_maxx = max(south_maxx, c.x)
	var hp_left: Vector2 = v.cell_point(south_minx, maxy, 0.08, 0.88)
	var hp_right: Vector2 = v.cell_point(south_maxx, maxy, 0.92, 0.88)
	var bw := hp_right.x - hp_left.x
	var bx := hp_left.x
	var by := lerpf(hp_left.y, hp_right.y, 0.5)
	var bar_h := 4.0
	v.draw_rect(Rect2(bx, by, bw, bar_h), Color(0.04, 0.04, 0.04, 0.82))
	var bc := health_color(frac)
	if frac > 0.0:
		v.draw_rect(Rect2(bx + 1, by + 1, maxf(1.0, (bw - 2.0) * frac), bar_h - 2.0), bc)
