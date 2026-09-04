class_name HexDraw
extends RefCounted

## 绘制 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：把主脚本 _draw() 的整段绘制逻辑搬到这里，作为 draw() 供主脚本的
## _draw() 回调调用。所有 draw_* 命令都通过 game 引用发到主节点（CanvasItem）
## 上——绘制命令必须在主节点自己的 _draw() 回调期间同步执行。

var game

func _init(g) -> void:
	game = g

func draw() -> void:
	game.draw_rect(Rect2(Vector2.ZERO, game.get_viewport_rect().size), game.COL_BG)
	for cell in game.geometry.all_cells():
		draw_hex(game.geometry.hex_center(cell), game.hex_size - 1.2, tile_color(cell))
	# 炮台攻击范围高亮
	for cell in game.geometry.all_cells():
		if not game.walls.has(cell) and not game.turret_positions.has(cell) and game.turrets.in_any_range(cell):
			draw_hex(game.geometry.hex_center(cell), game.hex_size - 1.2, Color(1.0, 0.35, 0.35, 0.16))
	# 可部署的最外围一圈提示（部署阶段）
	if game.mode == game.Mode.PLAY and game.phase == game.Phase.DEPLOY:
		for cell in game.geometry.all_cells():
			if game.geometry.is_edge(cell) and not game.walls.has(cell) and not game.turret_positions.has(cell):
				game.draw_arc(game.geometry.hex_center(cell), game.hex_size * 0.55, 0.0, TAU, 24, Color(0.8, 1.0, 1.0, 0.30), 2.0)
	# 墙（内部实心块 + 边框）
	for cell in game.walls:
		var c: Vector2 = game.geometry.hex_center(cell)
		var s: float = game.hex_size * 0.42
		var pts := PackedVector2Array()
		for i in 6:
			var a := deg_to_rad(60.0 * i)
			pts.append(c + Vector2(cos(a), sin(a)) * s)
		game.draw_colored_polygon(pts, game.COL_WALL_EDGE)
		var closed := pts.duplicate()
		closed.append(pts[0])
		game.draw_polyline(closed, Color(1.0, 1.0, 1.0, 0.18), 1.0)
	# 我方单位（核心，PlayerCore 场景实例）
	for cell in game.units:
		var n: PlayerCore = game.units[cell]
		var t: Dictionary = n.config
		var col: Color = game.map_data.core_color(t)
		var c: Vector2 = game.geometry.hex_center(cell)
		game.draw_circle(c, game.hex_size * 0.40, col)
		game.draw_arc(c, game.hex_size * 0.40, 0.0, TAU, 24, col.lightened(0.5), 2.0)
		# 持续时间环
		var frac := clampf(n.remaining / float(t["duration"]), 0.0, 1.0)
		game.draw_arc(c, game.hex_size * 0.52, -PI * 0.5, -PI * 0.5 + TAU * frac, 24, col.lightened(0.5), 3.0)
		# 定向模式核心：绘制方向箭头
		if n.mode() == "directional":
			var dirv: Vector2i = n.direction
			var dirpx: Vector2 = (game.geometry.hex_center(cell + dirv) - c).normalized()
			game.draw_line(c, c + dirpx * game.hex_size * 0.62, col.lightened(0.25), 3.0)
			game.draw_circle(c + dirpx * game.hex_size * 0.62, 3.0, col.lightened(0.25))
	# 定向部署待选方向的高亮
	if game.awaiting_direction:
		var pc: Vector2 = game.geometry.hex_center(game.pending_cell)
		game.draw_arc(pc, game.hex_size * 0.6, 0.0, TAU, 24, game.COL_UNIT_RING, 3.0)
		for d in game.NEIGHBORS:
			var n: Vector2i = game.pending_cell + d
			if game.geometry.in_bounds(n) and not game.walls.has(n) and not game.turret_positions.has(n):
				game.draw_arc(game.geometry.hex_center(n), game.hex_size * 0.3, 0.0, TAU, 16, Color(1.0, 1.0, 1.0, 0.35), 2.0)
	# 敌方炮台（可为多个）
	for p in game.turret_positions:
		var tc: Vector2 = game.geometry.hex_center(p)
		var t: EnemyTurret = game.turret_map.get(p)
		var alive: bool = game.mode == game.Mode.EDIT or (t != null and t.alive)
		if alive:
			game.draw_circle(tc, game.hex_size * 0.52, game.COL_TURRET)
			game.draw_arc(tc, game.hex_size * 0.52, 0.0, TAU, 24, game.COL_TURRET_RING, 2.0)
			var dir: Vector2 = Vector2(0.0, -1.0) * game.hex_size * 0.82
			var perp := Vector2(game.hex_size * 0.22, 0.0)
			game.draw_colored_polygon(PackedVector2Array([tc + dir, tc + perp, tc - perp]), game.COL_TURRET)
			if game.phase == game.Phase.RUNNING and game.mode == game.Mode.PLAY and t != null:
				var afrac := t.charge_fraction()
				game.draw_arc(tc, game.hex_size * 0.66, -PI * 0.5, -PI * 0.5 + TAU * afrac, 32, game.COL_TURRET_RING, 2.5)
		else:
			game.draw_circle(tc, game.hex_size * 0.52, game.COL_TURRET_DEAD)
			game.draw_line(tc + Vector2(-1, -1) * game.hex_size * 0.3, tc + Vector2(1, 1) * game.hex_size * 0.3, game.COL_TURRET_RING, 3.0)
			game.draw_line(tc + Vector2(-1, 1) * game.hex_size * 0.3, tc + Vector2(1, -1) * game.hex_size * 0.3, game.COL_TURRET_RING, 3.0)

func tile_color(cell: Vector2i) -> Color:
	if game.walls.has(cell):
		return game.COL_WALL
	if game.polluted.has(cell):
		return game.COL_POLLUTED_HI if cell == game.hover_cell else game.COL_POLLUTED
	if cell == game.hover_cell and not game.turret_positions.has(cell) and not game.units.has(cell):
		if game.mode == game.Mode.EDIT:
			return game.COL_TILE_HOVER
		if game.phase == game.Phase.DEPLOY and game.geometry.is_edge(cell):
			return game.COL_TILE_HOVER
	return game.COL_TILE

func draw_hex(center: Vector2, size: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		pts.append(center + Vector2(cos(a), sin(a)) * size)
	game.draw_colored_polygon(pts, col)
	var closed := pts.duplicate()
	closed.append(pts[0])
	game.draw_polyline(closed, game.COL_LINE, 1.0)
