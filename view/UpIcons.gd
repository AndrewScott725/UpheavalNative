class_name UpIcons
extends RefCounted


static func _load_png_texture(path: String) -> Texture2D:
	var resource = load(path)
	if resource is Texture2D:
		return resource as Texture2D
	var image := Image.new()
	var error: Error = image.load(ProjectSettings.globalize_path(path))
	if error != OK:
		push_error("UpIcons could not load image: %s (error %s)" % [path, error])
		return null
	return ImageTexture.create_from_image(image)

## Vector stand-in artwork, drawn procedurally.
##
## These exist so the layout can be built and judged without waiting on painted
## assets. Every class here is a drop-in replacement point: when real sprites
## arrive, swap the _draw() body for a TextureRect and nothing else changes.


## Heraldic shield with a simple charge. Used for the player crest, rival
## banners in Surrounding Fiefdoms, and wall pennants (§14 Heraldry).
class Herald extends Control:
	var base: Color = Color("2f4f8f")
	var device_colour: Color = Color("d9b451")
	var device: int = 0
	var banner: bool = false          ## draw as a hanging pennant instead of a shield

	func _init(p_base: Color = Color("2f4f8f"), p_device: int = 0, p_banner: bool = false) -> void:
		base = p_base
		device = p_device
		banner = p_banner
		custom_minimum_size = Vector2(26, 30)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if banner:
			var pts := PackedVector2Array([
				Vector2(0, 0), Vector2(w, 0), Vector2(w, h * 0.82),
				Vector2(w * 0.5, h), Vector2(0, h * 0.82)])
			draw_colored_polygon(pts, base)
			draw_polyline(pts + PackedVector2Array([Vector2(0, 0)]), Color(0, 0, 0, 0.45), 1.0)
		else:
			var pts := PackedVector2Array([
				Vector2(w * 0.06, h * 0.04), Vector2(w * 0.94, h * 0.04),
				Vector2(w * 0.94, h * 0.58), Vector2(w * 0.5, h * 0.97),
				Vector2(w * 0.06, h * 0.58)])
			draw_colored_polygon(pts, base)
			draw_polyline(pts + PackedVector2Array([Vector2(w * 0.06, h * 0.04)]),
				Color("6b5a2a"), 1.5)
		_charge(Vector2(w * 0.5, h * 0.44), min(w, h) * 0.30)

	func _charge(c: Vector2, r: float) -> void:
		var col := device_colour
		match device % 6:
			0:  # rampant beast — abstracted
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(-r * 0.7, r), c + Vector2(-r * 0.2, -r * 0.2),
					c + Vector2(0.1 * r, -r), c + Vector2(r * 0.5, -r * 0.1),
					c + Vector2(r * 0.7, r)]), col)
			1:  # sun in splendour
				draw_circle(c, r * 0.55, col)
				for i in 8:
					var a := TAU * i / 8.0
					draw_line(c + Vector2(cos(a), sin(a)) * r * 0.65,
						c + Vector2(cos(a), sin(a)) * r * 1.05, col, 1.5)
			2:  # tree / antler
				draw_line(c + Vector2(0, r), c + Vector2(0, -r), col, 2.0)
				draw_line(c, c + Vector2(-r * 0.7, -r * 0.7), col, 1.5)
				draw_line(c, c + Vector2(r * 0.7, -r * 0.7), col, 1.5)
				draw_line(c + Vector2(0, r * 0.3), c + Vector2(-r * 0.5, -r * 0.1), col, 1.2)
				draw_line(c + Vector2(0, r * 0.3), c + Vector2(r * 0.5, -r * 0.1), col, 1.2)
			3:  # tentacle / spiral
				var prev := c
				for i in range(1, 14):
					var t := float(i) / 13.0
					var a2 := t * TAU * 1.4
					var p := c + Vector2(cos(a2), sin(a2)) * r * t
					draw_line(prev, p, col, 1.6)
					prev = p
			4:  # tower
				draw_rect(Rect2(c.x - r * 0.45, c.y - r * 0.4, r * 0.9, r * 1.3), col)
				for i in 3:
					draw_rect(Rect2(c.x - r * 0.45 + i * r * 0.36, c.y - r * 0.7, r * 0.24, r * 0.32), col)
			_:  # cross moline
				draw_rect(Rect2(c.x - r * 0.18, c.y - r, r * 0.36, r * 2), col)
				draw_rect(Rect2(c.x - r, c.y - r * 0.18, r * 2, r * 0.36), col)


## Small isometric-leaning building thumbnail for the Buildings list.
class BuildingIcon extends Control:
	var body: Color = Color("cfc3a8")
	var roof: Color = Color("b8342c")
	var locked: bool = false

	func _init(p_roof: Color = Color("b8342c"), p_locked: bool = false) -> void:
		roof = p_roof
		locked = p_locked
		custom_minimum_size = Vector2(44, 38)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var b := body
		var r := roof
		if locked:
			var g := (b.r + b.g + b.b) / 3.0
			b = Color(g, g, g)
			var g2 := (r.r + r.g + r.b) / 3.0
			r = Color(g2, g2, g2)
		# ground plate
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.5, h * 0.62), Vector2(w * 0.96, h * 0.82),
			Vector2(w * 0.5, h * 0.99), Vector2(w * 0.04, h * 0.82)]),
			Color("6f8a4a") if not locked else Color(0.45, 0.45, 0.45))
		# walls
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.18, h * 0.46), Vector2(w * 0.5, h * 0.62),
			Vector2(w * 0.5, h * 0.88), Vector2(w * 0.18, h * 0.72)]), b.darkened(0.18))
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.82, h * 0.46), Vector2(w * 0.5, h * 0.62),
			Vector2(w * 0.5, h * 0.88), Vector2(w * 0.82, h * 0.72)]), b)
		# roof
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.5, h * 0.12), Vector2(w * 0.86, h * 0.44),
			Vector2(w * 0.5, h * 0.60), Vector2(w * 0.14, h * 0.44)]), r)
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.5, h * 0.12), Vector2(w * 0.5, h * 0.60),
			Vector2(w * 0.14, h * 0.44)]), r.darkened(0.22))


## The polyomino footprint silhouette shown beside each building card (§14).
class PolyIcon extends Control:
	var cells: Array = []
	var colour: Color = Color("3b6fb5")
	var locked: bool = false

	func _init(p_cells: Array = [], p_col: Color = Color("3b6fb5"), p_locked: bool = false) -> void:
		cells = p_cells
		colour = p_col
		locked = p_locked
		custom_minimum_size = Vector2(46, 40)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if cells.is_empty(): return

		# Footprint definitions are allowed to use translated coordinates. Always
		# normalize to their actual bounding box before centering; otherwise shapes
		# whose minimum x/y is not zero are pushed toward the right/bottom edge.
		var minx := int(cells[0][0])
		var miny := int(cells[0][1])
		var maxx := minx
		var maxy := miny
		for c in cells:
			minx = min(minx, int(c[0]))
			miny = min(miny, int(c[1]))
			maxx = max(maxx, int(c[0]))
			maxy = max(maxy, int(c[1]))

		var cols := maxx - minx + 1
		var rows := maxy - miny + 1
		# Leave a small safety inset so no outline is clipped by the row/container.
		var inset := 2.0
		var avail_w := maxf(1.0, size.x - inset * 2.0)
		var avail_h := maxf(1.0, size.y - inset * 2.0)
		var s: float = min(avail_w / float(cols), avail_h / float(rows))
		s = min(s, 15.0)
		var ox := (size.x - s * cols) * 0.5
		var oy := (size.y - s * rows) * 0.5
		var col := colour
		if locked:
			var g := (col.r + col.g + col.b) / 3.0
			col = Color(g, g, g, 0.75)
		for c in cells:
			var cx := int(c[0]) - minx
			var cy := int(c[1]) - miny
			var r := Rect2(ox + cx * s, oy + cy * s, s - 1.5, s - 1.5)
			draw_rect(r, col)
			draw_rect(r, col.darkened(0.4), false, 1.0)


## Soldier artwork for the Barracks cards uses the same character sprites and
## faction-tint masks as the battlefield renderer.
class SoldierIcon extends Control:
	const ICON_FRAME := Rect2(0.0, 0.0, 181.0, 362.0)
	var tunic: Color = Color("2f4f8f")
	var ranged: bool = false
	var knight_icon: Texture2D = null
	var archer_icon: Texture2D = null
	var knight_mask: Texture2D = null
	var archer_mask: Texture2D = null

	func _init(p_col: Color = Color("2f4f8f"), p_ranged: bool = false) -> void:
		tunic = p_col
		ranged = p_ranged
		knight_icon = UpIcons._load_png_texture("res://view/assets/knight_sheet_transparent.png")
		archer_icon = UpIcons._load_png_texture("res://view/assets/archer_sheet_transparent.png")
		knight_mask = UpIcons._load_png_texture("res://view/assets/knight_cloth_mask.png")
		archer_mask = UpIcons._load_png_texture("res://view/assets/archer_cloth_mask.png")
		custom_minimum_size = Vector2(92, 112)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var tex: Texture2D = archer_icon if ranged else knight_icon
		var mask: Texture2D = archer_mask if ranged else knight_mask
		var aspect: float = ICON_FRAME.size.x / ICON_FRAME.size.y
		var draw_h: float = minf(size.y - 2.0, 108.0)
		var draw_w: float = draw_h * aspect
		var dest := Rect2((size.x - draw_w) * 0.5, -2.0, draw_w, draw_h)
		draw_texture_rect_region(tex, dest, ICON_FRAME)
		var tint: Color = tunic.lightened(0.08)
		tint.a = 0.92
		draw_texture_rect_region(mask, dest, ICON_FRAME, tint)


## Stack of coins beside the Treasury readout.
class CoinIcon extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(40, 34)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		for i in 3:
			var y := h * (0.72 - i * 0.16)
			draw_circle(Vector2(w * 0.5, y), w * 0.26, Color("b8912e"))
			draw_circle(Vector2(w * 0.5, y - 2), w * 0.26, Color("e8c451"))
		draw_circle(Vector2(w * 0.28, h * 0.74), w * 0.2, Color("b8912e"))
		draw_circle(Vector2(w * 0.28, h * 0.74 - 2), w * 0.2, Color("e8c451"))


## Tent glyph for the War Camp panels.
class CampIcon extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(40, 34)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.5, h * 0.12), Vector2(w * 0.92, h * 0.86), Vector2(w * 0.08, h * 0.86)]),
			Color("3a63b8"))
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.5, h * 0.12), Vector2(w * 0.5, h * 0.86), Vector2(w * 0.08, h * 0.86)]),
			Color("2d4e94"))
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.5, h * 0.5), Vector2(w * 0.63, h * 0.86), Vector2(w * 0.37, h * 0.86)]),
			Color("1b3062"))
		draw_line(Vector2(w * 0.5, h * 0.12), Vector2(w * 0.5, h * 0.02), Color("d9b451"), 1.5)


## Padlock for unavailable buildings.
class LockIcon extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(26, 28)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_arc(Vector2(w * 0.5, h * 0.42), w * 0.22, PI, TAU, 14, Color("8a6f36"), 3.5)
		draw_rect(Rect2(w * 0.22, h * 0.42, w * 0.56, h * 0.46), Color("c19a3e"))
		draw_rect(Rect2(w * 0.22, h * 0.42, w * 0.56, h * 0.46), Color("6b5424"), false, 1.0)
		draw_circle(Vector2(w * 0.5, h * 0.63), w * 0.07, Color("6b5424"))


## Reconnaissance spyglass icon shown after Ironcrest has sent a War Camp.
class SpyglassIcon extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(22, 18)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var gold := Color("8a6422")
		var dark := Color("3d2e1b")
		# Two nested tubes angled upward-right.
		draw_line(Vector2(4, 14), Vector2(15, 5), dark, 5.0)
		draw_line(Vector2(4, 14), Vector2(15, 5), gold, 3.0)
		draw_line(Vector2(11, 8), Vector2(18, 3), dark, 6.0)
		draw_line(Vector2(11, 8), Vector2(18, 3), Color("c69a3b"), 3.5)
		draw_circle(Vector2(18, 3), 3.2, dark)
		draw_circle(Vector2(18, 3), 2.0, Color("9dc7d8"))
		draw_circle(Vector2(4, 14), 2.8, dark)
