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
	# 炮台攻击范围高亮（统一颜色；范围仍按各炮台类型正确计算）
	for cell in game.geometry.all_cells():
		if game.walls.has(cell) or game.turret_positions.has(cell):
			continue
		var owner_type: String = game.turrets.covering_type(cell)
		if owner_type != "":
			draw_hex(game.geometry.hex_center(cell), game.hex_size - 1.2, Color(1.0, 0.35, 0.35, 0.16))
	# 可部署的最外围一圈提示（部署与扩散阶段都可继续部署）
	if game.mode == game.Mode.PLAY and (game.phase == game.Phase.DEPLOY or game.phase == game.Phase.RUNNING):
		for cell in game.geometry.all_cells():
			if game.geometry.is_edge(cell) and not game.walls.has(cell) and not game.turret_positions.has(cell):
				game.draw_arc(game.geometry.hex_center(cell), game.hex_size * 0.55, 0.0, TAU, 24, Color(0.8, 1.0, 1.0, 0.30), 2.0)
	# 墙（内部实心块 + 边框）
	for cell in game.walls:
		var c: Vector2 = game.geometry.hex_center(cell)
		var s: float = game.hex_size * 0.42
		var pts := PackedVector2Array()
		for i in 6:
			var a := deg_to_rad(60.0 * i + 30.0)
			pts.append(c + Vector2(cos(a), sin(a)) * s)
		game.draw_colored_polygon(pts, game.COL_WALL_EDGE)
		var closed := pts.duplicate()
		closed.append(pts[0])
		game.draw_polyline(closed, Color(1.0, 1.0, 1.0, 0.18), 1.0)
	# 定向部署待选方向的高亮
	if game.awaiting_direction:
		var pc: Vector2 = game.geometry.hex_center(game.pending_cell)
		game.draw_arc(pc, game.hex_size * 0.6, 0.0, TAU, 24, game.COL_UNIT_RING, 3.0)
		for d in game.NEIGHBORS:
			var n: Vector2i = game.pending_cell + d
			if game.geometry.in_bounds(n) and not game.walls.has(n) and not game.turret_positions.has(n):
				game.draw_arc(game.geometry.hex_center(n), game.hex_size * 0.3, 0.0, TAU, 16, Color(1.0, 1.0, 1.0, 0.35), 2.0)
	# 敌方炮台（可为多个；按类型着色）
	for p in game.turret_positions:
		var type_name: String = str(game.turret_types.get(p, "basic"))
		var body_col: Color = _turret_body_color(type_name)
		var ring_col: Color = _turret_ring_color(type_name)
		var tc: Vector2 = game.geometry.hex_center(p)
		var t: EnemyTurret = game.turret_map.get(p)
		var alive: bool = game.mode == game.Mode.EDIT or (t != null and t.alive)
		if alive:
			game.draw_circle(tc, game.hex_size * 0.52, body_col)
			game.draw_arc(tc, game.hex_size * 0.52, 0.0, TAU, 24, ring_col, 2.0)
			var dir: Vector2 = Vector2(0.0, -1.0) * game.hex_size * 0.82
			var perp := Vector2(game.hex_size * 0.22, 0.0)
			game.draw_colored_polygon(PackedVector2Array([tc + dir, tc + perp, tc - perp]), body_col)
			if game.phase == game.Phase.RUNNING and game.mode == game.Mode.PLAY and t != null:
				var afrac := t.charge_fraction()
				game.draw_arc(tc, game.hex_size * 0.66, -PI * 0.5, -PI * 0.5 + TAU * afrac, 32, ring_col, 2.5)
		else:
			game.draw_circle(tc, game.hex_size * 0.52, game.COL_TURRET_DEAD)
			game.draw_line(tc + Vector2(-1, -1) * game.hex_size * 0.3, tc + Vector2(1, 1) * game.hex_size * 0.3, ring_col, 3.0)
			game.draw_line(tc + Vector2(-1, 1) * game.hex_size * 0.3, tc + Vector2(1, -1) * game.hex_size * 0.3, ring_col, 3.0)

## 炮台类型 -> 主体颜色
func _turret_body_color(type_name: String) -> Color:
	match type_name:
		"sniper":
			return Color("ffa726")   # 橙色
		"rapid":
			return Color("26c6da")   # 青色
		_:
			return game.COL_TURRET   # 红色（基础）

## 炮台类型 -> 外圈/充能环颜色（主体色提亮）
func _turret_ring_color(type_name: String) -> Color:
	return _turret_body_color(type_name).lightened(0.55)

func tile_color(cell: Vector2i) -> Color:
	if game.walls.has(cell):
		return game.COL_WALL
	if game.polluted.has(cell):
		return game.COL_POLLUTED_HI if cell == game.hover_cell else game.COL_POLLUTED
	if cell == game.hover_cell and not game.turret_positions.has(cell) and not game.units.has(cell):
		if game.mode == game.Mode.EDIT:
			return game.COL_TILE_HOVER
		if (game.phase == game.Phase.DEPLOY or game.phase == game.Phase.RUNNING) and game.geometry.is_edge(cell):
			return game.COL_TILE_HOVER
	return game.COL_TILE

func draw_hex(center: Vector2, size: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i + 30.0)
		pts.append(center + Vector2(cos(a), sin(a)) * size)
	game.draw_colored_polygon(pts, col)
	var closed := pts.duplicate()
	closed.append(pts[0])
	game.draw_polyline(closed, game.COL_LINE, 1.0)
