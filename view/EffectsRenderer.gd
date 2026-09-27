extends RefCounted
const UpConfigRef = preload("res://sim/UpConfig.gd")

## Transient battlefield effects: projectiles and click-gain text.

const C_ARROW_OUT := Color("f0e6cf")
const C_ARROW_IN := Color("e8b24a")




static func draw_stylized_arrow(v: BoardView, a: Vector2, b: Vector2, t: float, hostile: bool) -> void:
	var base_dir := b - a
	var len_px := base_dir.length()
	if len_px < 1.0:
		return
	base_dir /= len_px
	var side := 1.0 if hostile else -1.0
	var perp := Vector2(-base_dir.y, base_dir.x)
	var arc_h := minf(len_px * 0.12, 20.0)
	var ctrl := (a + b) * 0.5 + perp * arc_h * side
	var omt := 1.0 - t
	var pos := omt * omt * a + 2.0 * omt * t * ctrl + t * t * b
	var tangent := 2.0 * omt * (ctrl - a) + 2.0 * t * (b - ctrl)
	if tangent.length_squared() < 0.0001:
		tangent = base_dir
	else:
		tangent = tangent.normalized()
	var n := Vector2(-tangent.y, tangent.x)
	var col := C_ARROW_IN if hostile else C_ARROW_OUT
	var fade := 1.0 - t * 0.22
	col.a = fade
	var shaft := minf(14.0, maxf(8.0, len_px * 0.28))
	var tail := pos - tangent * shaft
	if not v.battle_visual_visible(pos, shaft + 7.0):
		return
	# More illustrative arrow: wooden shaft, pale feather fletching, and steel head.
	v.draw_line(tail, pos, Color(0.10, 0.07, 0.04, 0.48 * fade), 2.8)
	v.draw_line(tail, pos, Color(0.47, 0.31, 0.16, 0.98 * fade), 1.55)
	v.draw_line(tail + n * 0.22, pos + n * 0.22, Color(0.84, 0.71, 0.45, 0.26 * fade), 0.75)
	var tip := pos + tangent * 1.6
	var head_len := 5.4
	var head_w := 2.55
	v.draw_colored_polygon(PackedVector2Array([
		tip,
		tip - tangent * head_len + n * (head_w + 1.0),
		tip - tangent * head_len - n * (head_w + 1.0)
	]), Color(0.07, 0.07, 0.08, 0.50 * fade))
	v.draw_colored_polygon(PackedVector2Array([
		tip,
		tip - tangent * (head_len - 0.8) + n * head_w,
		tip - tangent * (head_len - 0.8) - n * head_w
	]), Color(0.80, 0.82, 0.84, 0.98 * fade))
	var f0 := tail + tangent * 2.2
	var fletch_col := Color(0.92, 0.90, 0.82, 0.95 * fade)
	v.draw_line(tail, f0 + n * 2.4, fletch_col, 1.15)
	v.draw_line(tail, f0 - n * 2.4, fletch_col, 1.15)
	v.draw_line(tail + tangent * 0.6, f0 + n * 1.2, Color(0.35, 0.22, 0.12, 0.70 * fade), 0.55)
	v.draw_line(tail + tangent * 0.6, f0 - n * 1.2, Color(0.35, 0.22, 0.12, 0.70 * fade), 0.55)
	if int(floor(t * float(UpConfigRef.ARROW_FLIGHT))) >= UpConfigRef.ARROW_FLIGHT - 1:
		v.draw_circle(b, 2.4, Color(1.0, 0.94, 0.76, 0.65))
		v.draw_circle(b, 1.1, Color(1.0, 1.0, 0.95, 0.86))

static func draw_arrows(v: BoardView) -> void:
	var m = v.match_ref
	var shot_i := 0
	for sh in m.shots:
		shot_i += 1
		if (shot_i - 1) % v.projectile_stride() != 0:
			continue
		var age: int = m.tick - sh.fired
		if age < 0 or age > UpConfigRef.ARROW_FLIGHT:
			continue
		var t: float = clampf((float(age) + v.interpolation_alpha()) / float(UpConfigRef.ARROW_FLIGHT), 0.0, 1.0)

		var a := Vector2(v.mm_to_px(sh.fx), v.mm_to_px(sh.fy))
		if not sh.hostile:
			# Loose from the archer figure standing nearest the TARGET. Everyone
			# at a wall sits on the same line, so picking by origin drew arrows
			# skimming lengthwise along the parapet instead of crossing to the
			# invader opposite.
			var tgt := Vector2(v.mm_to_px(sh.tx), v.mm_to_px(sh.ty))
			var best_d := 1.0e20
			var best_p := a
			for wd in v._wall_archer_pts:
				for fp: Vector2 in v._wall_archer_pts[wd]:
					var dd: float = fp.distance_squared_to(tgt)
					if dd < best_d:
						best_d = dd
						best_p = fp
			if best_d < 1.0e20:
				a = best_p + Vector2(0, -5.0)
		var b := Vector2(v.mm_to_px(sh.tx), v.mm_to_px(sh.ty))
		draw_stylized_arrow(v, a, b, t, sh.hostile)


static func draw_melee_impacts(v: BoardView) -> void:
	var m = v.match_ref
	var hit_i := 0
	for hit in m.melee_impacts:
		hit_i += 1
		if (hit_i - 1) % v.impact_stride() != 0:
			continue
		var age := float(m.tick - hit.fired) + v.interpolation_alpha()
		if age < 0.0 or age > float(UpConfigRef.MELEE_IMPACT_TICKS):
			continue
		var t := clampf(age / float(UpConfigRef.MELEE_IMPACT_TICKS), 0.0, 1.0)
		var p := Vector2(v.mm_to_px(hit.x), v.mm_to_px(hit.y))
		if not v.battle_visual_visible(p, 14.0):
			continue
		var alpha := 1.0 - t
		var radius := 2.2 + 5.0 * t

		# Small but unmistakable melee contact burst. Keep it compact enough for
		# large battles while remaining readable on stone walls, turrets and roofs.
		v.draw_circle(p, radius, Color(1.0, 0.52, 0.10, 0.52 * alpha))
		v.draw_circle(p, maxf(1.2, radius * 0.48), Color(1.0, 0.92, 0.52, 0.92 * alpha))
		v.draw_circle(p, maxf(0.8, radius * 0.22), Color(1.0, 1.0, 0.88, 0.98 * alpha))
		var spark_len := 4.0 + 5.0 * t
		var dirs := [
			Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP,
			Vector2(0.707, 0.707), Vector2(-0.707, 0.707),
			Vector2(-0.707, -0.707), Vector2(0.707, -0.707)
		]
		var ray_count := mini(v.effect_spark_rays(), dirs.size())
		for ri in ray_count:
			var d: Vector2 = dirs[ri]
			v.draw_line(p + d * 1.5, p + d * spark_len,
				Color(1.0, 0.60, 0.12, 0.80 * alpha), 1.2)

		# Lightweight particle-like debris. Higher local quality tiers add more
		# battlefield richness without affecting any authoritative combat state.
		for pi in v.effect_particle_count():
			var ang := float(pi) * 2.399963 + t * 1.7
			var dist := (3.0 + float(pi) * 1.35) * (0.55 + t)
			var dp := p + Vector2(cos(ang), sin(ang)) * dist
			if not v.battle_visual_visible(dp, 3.0):
				continue
			v.draw_circle(dp, 0.9 + float(pi % 2) * 0.35, Color(0.82, 0.66, 0.36, 0.55 * alpha))


static func draw_death_floats(v: BoardView) -> void:
	var m = v.match_ref
	for d in m.death_floats:
		var age := float(m.tick - d.fired) + v.interpolation_alpha()
		if age < 0.0 or age > float(UpConfigRef.DEATH_FLOAT_TICKS):
			continue

		var t := clampf(age / float(UpConfigRef.DEATH_FLOAT_TICKS), 0.0, 1.0)
		var base := Vector2(v.mm_to_px(d.x), v.mm_to_px(d.y))
		var alpha := 1.0
		if t > 0.48:
			alpha = clampf(1.0 - (t - 0.48) / 0.52, 0.0, 1.0)

		var casualty_count := maxi(1, d.count)
		# Spread scales slowly with a large casualty count: 30 deaths read as a
		# compact burst, while 500 still produce 500 distinct floating skulls
		# without covering the entire battlefield.
		var spread := minf(42.0, 7.0 + sqrt(float(casualty_count)) * 1.55)

		var visible_deaths := mini(casualty_count, v.death_visual_cap_per_event())
		var death_stride := maxi(1, int(ceil(float(casualty_count) / float(maxi(1, visible_deaths)))))
		for vi in visible_deaths:
			var n := mini(casualty_count - 1, vi * death_stride)
			var seed := absi(d.seed * 1103515245 + n * 977 + 12345)
			var rx := float((seed % 2001) - 1000) / 1000.0
			var ry_seed := absi(seed * 1664525 + 1013904223)
			var ry := float((ry_seed % 2001) - 1000) / 1000.0
			var drift_seed := absi(ry_seed * 1103515245 + 12345)
			var drift_sign := -1.0 if (drift_seed & 1) == 0 else 1.0

			var start_offset := Vector2(rx * spread, ry * spread * 0.42)
			var rise := 9.0 + 31.0 * t + float(seed % 7) * 0.35 * t
			var drift := drift_sign * (1.0 + float(seed % 9) * 0.22) * t
			var p := base + start_offset + Vector2(drift, -rise)
			if not v.battle_visual_visible(p, 8.0):
				continue

			# Tiny hand-drawn skull-and-crossbones. It uses the same upward float
			# and late fade as click-gain feedback but does not depend on emoji
			# glyph availability.
			var shadow := Color(0.02, 0.02, 0.02, 0.42 * alpha)
			var bone := Color(0.95, 0.91, 0.78, alpha)
			var dark := Color(0.12, 0.10, 0.08, 0.85 * alpha)

			if v.quality_shadows_enabled():
				var ps := p + Vector2(0.8, 0.9)
				v.draw_line(ps + Vector2(-3.6, 3.2), ps + Vector2(3.6, -3.2), shadow, 1.4)
				v.draw_line(ps + Vector2(-3.6, -3.2), ps + Vector2(3.6, 3.2), shadow, 1.4)
				v.draw_circle(ps, 3.5, shadow)

			v.draw_line(p + Vector2(-3.5, 3.0), p + Vector2(3.5, -3.0), bone, 1.2)
			v.draw_line(p + Vector2(-3.5, -3.0), p + Vector2(3.5, 3.0), bone, 1.2)
			v.draw_circle(p, 3.35, bone)
			v.draw_rect(Rect2(p.x - 2.2, p.y + 1.6, 4.4, 2.0), bone)
			v.draw_circle(p + Vector2(-1.15, -0.35), 0.7, dark)
			v.draw_circle(p + Vector2(1.15, -0.35), 0.7, dark)
			v.draw_line(p + Vector2(-1.3, 2.65), p + Vector2(1.3, 2.65), dark, 0.65)


static func draw_gain_popups(v: BoardView) -> void:
	var now := Time.get_ticks_msec()
	for i in range(v.gain_popups.size() - 1, -1, -1):
		var g: Dictionary = v.gain_popups[i]
		var born := int(g["born"])
		var expires := int(g["expires"])
		if now >= expires:
			v.gain_popups.remove_at(i)
			continue

		var duration: int = maxi(1, expires - born)
		var t := clampf(float(now - born) / float(duration), 0.0, 1.0)
		var text: String = g["text"]
		var base := Vector2(v.mm_to_px(int(g["x"])), v.mm_to_px(int(g["y"])))
		var jitter := Vector2(float(g.get("jitter_x", 0.0)), float(g.get("jitter_y", 0.0)))
		var rise := 20.0 + 62.0 * t
		var drift := float(g.get("jitter_x", 0.0)) * 0.18 * t
		var p := base + jitter + Vector2(drift, -rise)
		if not v.battle_visual_visible(p, 18.0):
			continue

		var alpha := 1.0
		if t > 0.48:
			alpha = clampf(1.0 - (t - 0.48) / 0.52, 0.0, 1.0)

		var font_size := 18
		if t < 0.12:
			font_size = 20

		var text_w := v.font_disp.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var origin := p - Vector2(text_w * 0.5, 0)

		v.draw_string(v.font_disp, origin + Vector2(1.5, 1.5), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.02, 0.02, 0.02, 0.62 * alpha))
		v.draw_string(v.font_disp, origin, text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 0.93, 0.54, alpha))
