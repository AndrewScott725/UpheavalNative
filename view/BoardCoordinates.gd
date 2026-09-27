extends RefCounted

## Camera, board/grid projection and click-space conversion. BoardView owns the
## state; this module owns the math so render code does not also own input math.

static func board_px(b) -> int:
	return b.GRID * b.px_cell + 2 * (b.wall_thick + b.gap)

static func origin(b) -> Vector2:
	var side: float = float(board_px(b))
	var free_x: float = float(b.size.x - b.inset_left - b.inset_right)
	var free_y: float = float(b.size.y - b.inset_top - b.inset_bottom)
	return Vector2(round(b.inset_left + (free_x - side) * 0.5), round(b.inset_top + (free_y - side) * 0.5))

static func world_rect(b) -> Rect2:
	return b._landscape_dest_rect()

static func clamp_view_pan(b) -> void:
	var wr: Rect2 = world_rect(b)
	var base: Vector2 = origin(b)
	var min_pan_x: float = float(b.size.x - base.x - (wr.position.x + wr.size.x) * b.view_zoom)
	var max_pan_x: float = float(-base.x - wr.position.x * b.view_zoom)
	var min_pan_y: float = float(b.size.y - base.y - (wr.position.y + wr.size.y) * b.view_zoom)
	var max_pan_y: float = float(-base.y - wr.position.y * b.view_zoom)
	b.view_pan.x = clampf(b.view_pan.x, min_pan_x, max_pan_x) if min_pan_x <= max_pan_x else (min_pan_x + max_pan_x) * 0.5
	b.view_pan.y = clampf(b.view_pan.y, min_pan_y, max_pan_y) if min_pan_y <= max_pan_y else (min_pan_y + max_pan_y) * 0.5

static func view_origin(b) -> Vector2:
	return origin(b) + b.view_pan

static func screen_to_board(b, screen_pos: Vector2) -> Vector2:
	return (screen_pos - view_origin(b)) / b.view_zoom

static func board_to_screen(b, board_pos: Vector2) -> Vector2:
	return view_origin(b) + board_pos * b.view_zoom

static func battle_visual_visible(b, board_pos: Vector2, margin_px: float = 8.0) -> bool:
	var screen_pos: Vector2 = board_to_screen(b, board_pos)
	var margin: float = float(margin_px * b.view_zoom)
	return screen_pos.x - margin > b.inset_left and screen_pos.x + margin < b.size.x - b.inset_right and screen_pos.y + margin < b.size.y - b.inset_bottom

static func zoom_at(b, screen_pos: Vector2, factor: float) -> void:
	var before: Vector2 = screen_to_board(b, screen_pos)
	var min_zoom: float = b._minimum_view_zoom()
	var new_zoom: float = clampf(float(b.view_zoom) * factor, min_zoom, float(b.VIEW_ZOOM_MAX))
	if is_equal_approx(new_zoom, b.view_zoom): return
	b.view_zoom = new_zoom
	b.view_pan = screen_pos - origin(b) - before * b.view_zoom
	if is_equal_approx(b.view_zoom, min_zoom):
		var wr: Rect2 = world_rect(b)
		var free_w: float = b.size.x - b.inset_left - b.inset_right
		var free_h: float = b.size.y - b.inset_top - b.inset_bottom
		var target: Vector2 = Vector2(b.inset_left + (free_w - wr.size.x * b.view_zoom) * 0.5, b.inset_top + (free_h - wr.size.y * b.view_zoom) * 0.5)
		b.view_pan = target - origin(b) - wr.position * b.view_zoom
	clamp_view_pan(b)
	b.queue_redraw()

static func reset_view(b) -> void:
	var min_zoom: float = b._minimum_view_zoom()
	b.view_zoom = minf(b.VIEW_ZOOM_MAX, min_zoom * 1.15)
	b._panning = false
	var wr: Rect2 = world_rect(b)
	var free_w: float = b.size.x - b.inset_left - b.inset_right
	var free_h: float = b.size.y - b.inset_top - b.inset_bottom
	var target: Vector2 = Vector2(b.inset_left + (free_w - wr.size.x * b.view_zoom) * 0.5, b.inset_top + (free_h - wr.size.y * b.view_zoom) * 0.5)
	b.view_pan = target - origin(b) - wr.position * b.view_zoom
	clamp_view_pan(b)
	b.queue_redraw()

static func castle_point_from_src(b, src: Vector2) -> Vector2:
	var dest: Rect2 = b._castle_art_dest_rect()
	var sx: float = dest.size.x / float(b.FIEFDOM_CASTLE_ART.get_width())
	var sy: float = dest.size.y / float(b.FIEFDOM_CASTLE_ART.get_height())
	return Vector2(dest.position.x + src.x * sx, dest.position.y + src.y * sy)

static func field_src_x_at(b, col: int, y_src: float) -> float:
	var idx: int = clampi(col, 0, int(b.GRID))
	var top_x: float = float(b.FIEFDOM_CASTLE_ART_COL_TOP_SRC[idx])
	var bottom_x: float = float(b.FIEFDOM_CASTLE_ART_COL_BOTTOM_SRC[idx])
	var denom: float = maxf(1.0, float(b.FIEFDOM_CASTLE_ART_ROW_SRC[b.GRID]) - float(b.FIEFDOM_CASTLE_ART_ROW_SRC[0]))
	return lerpf(top_x, bottom_x, clampf((y_src - float(b.FIEFDOM_CASTLE_ART_ROW_SRC[0])) / denom, 0.0, 1.0))

static func field_src_y(b, row: int) -> float:
	return float(b.FIEFDOM_CASTLE_ART_ROW_SRC[clampi(row, 0, b.GRID)])

static func cell_polygon(b, x: int, y: int) -> PackedVector2Array:
	var y0: float = field_src_y(b, y); var y1: float = field_src_y(b, y + 1)
	return PackedVector2Array([
		castle_point_from_src(b, Vector2(field_src_x_at(b, x, y0), y0)),
		castle_point_from_src(b, Vector2(field_src_x_at(b, x + 1, y0), y0)),
		castle_point_from_src(b, Vector2(field_src_x_at(b, x + 1, y1), y1)),
		castle_point_from_src(b, Vector2(field_src_x_at(b, x, y1), y1))])

static func cell_rect(b, x: int, y: int) -> Rect2:
	if b._use_exact_castle_art():
		var p: PackedVector2Array = cell_polygon(b, x, y)
		var min_x: float = minf(minf(p[0].x,p[1].x),minf(p[2].x,p[3].x)); var max_x: float = maxf(maxf(p[0].x,p[1].x),maxf(p[2].x,p[3].x))
		var min_y: float = minf(p[0].y,p[3].y); var max_y: float = maxf(p[1].y,p[2].y)
		return Rect2(min_x,min_y,max_x-min_x,max_y-min_y)
	return Rect2(float(b.wall_thick+b.gap+x*b.px_cell), float(b.wall_thick+b.gap+y*b.px_cell), float(b.px_cell), float(b.px_cell))

static func cell_point(b, x:int, y:int, u:float, v:float) -> Vector2:
	var p: PackedVector2Array = cell_polygon(b,x,y)
	return p[0].lerp(p[1],u).lerp(p[3].lerp(p[2],u),v)

static func cell_center(b,x:int,y:int)->Vector2:
	return cell_point(b,x,y,0.5,0.5)

static func to_px(b,c:int)->float:
	return cell_rect(b,c,0).position.x if b._use_exact_castle_art() else float(b.wall_thick+b.gap+c*b.px_cell)

static func to_py(b,r:int)->float:
	return cell_rect(b,0,r).position.y if b._use_exact_castle_art() else float(b.wall_thick+b.gap+r*b.px_cell)

static func mmf_to_px(b,mm:float)->float:
	return float(b.wall_thick+b.gap)+mm*float(b.px_cell)/float(b.CELL)

static func mmf_to_py(b,mm:float)->float:
	if not b._use_exact_castle_art(): return float(b.wall_thick+b.gap)+mm*float(b.px_cell)/float(b.CELL)
	var cellf: float = mm / float(b.CELL); var row: int = clampi(int(floor(cellf)), 0, int(b.GRID) - 1); var frac: float = clampf(cellf - float(row), 0.0, 1.0)
	var y0: float = to_py(b, row); var y1: float = to_py(b, row + 1) if row + 1 < int(b.GRID) else cell_rect(b, 0, int(b.GRID) - 1).end.y
	return lerpf(y0,y1,frac)

static func cell_at(b, mouse: Vector2) -> Vector2i:
	var local: Vector2 = screen_to_board(b, mouse)
	if b._use_exact_castle_art():
		for y in range(b.GRID):
			for x in range(b.GRID):
				if Geometry2D.is_point_in_polygon(local, cell_polygon(b,x,y)): return Vector2i(x,y)
		return Vector2i(-1,-1)
	local -= Vector2(b.wall_thick+b.gap,b.wall_thick+b.gap)
	var x: int = int(floor(local.x / float(b.px_cell))); var y: int = int(floor(local.y / float(b.px_cell)))
	return Vector2i(-1,-1) if x<0 or y<0 or x>=b.GRID or y>=b.GRID else Vector2i(x,y)
