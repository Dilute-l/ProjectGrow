class_name HexDraw
extends RefCounted

## 绘制 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：把主脚本 _draw() 的整段绘制逻辑搬到这里，作为 draw() 供主脚本的
## _draw() 回调调用。所有 draw_* 命令都通过 game 引用发到主节点（CanvasItem）
## 上——绘制命令必须在主节点自己的 _draw() 回调期间同步执行。

var game

## 游戏背景图（带暗色滤镜，让前景元素更清晰）
const BG_TEXTURE := preload("res://images/background.png")
const BG_DARKEN := Color(0.0, 0.0, 0.0, 0.75)

func _init(g) -> void:
	game = g

func draw() -> void:
	var vs: Vector2 = game.get_viewport_rect().size
	game.draw_texture_rect(BG_TEXTURE, Rect2(Vector2.ZERO, vs), false)
	game.draw_rect(Rect2(Vector2.ZERO, vs), BG_DARKEN)
	for cell in game.geometry.all_cells():
		draw_hex(game.geometry.hex_center(cell), game.hex_size - 1.2, tile_color(cell))
	# 炮台攻击范围高亮（统一颜色；范围仍按各炮台类型正确计算）
	for cell in game.geometry.all_cells():
		if game.walls.has(cell) or game.turret_positions.has(cell):
			continue
		var owner_type: String = game.turrets.covering_type(cell)
		if owner_type != "":
			draw_hex(game.geometry.hex_center(cell), game.hex_size - 1.2, Color(1.0, 0.35, 0.35, 0.16))
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
	# 特殊地块标记（半透明着色 + 彩色描边）
	for cell in game.special_tiles:
		var def: Dictionary = game.special_kind_defs.get(str(game.special_tiles[cell]), {})
		if def.is_empty():
			continue
		var col: Color = Color(str(def.get("color", "#ffffff")))
		var cc: Vector2 = game.geometry.hex_center(cell)
		var s: float = game.hex_size - 1.2
		var pts := PackedVector2Array()
		for i in 6:
			var a := deg_to_rad(60.0 * i + 30.0)
			pts.append(cc + Vector2(cos(a), sin(a)) * s)
		game.draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.38))
		var closed := pts.duplicate()
		closed.append(pts[0])
		game.draw_polyline(closed, col, 2.0)
	# 定向部署待选方向的高亮
	if game.awaiting_direction:
		var pc: Vector2 = game.geometry.hex_center(game.pending_cell)
		game.draw_arc(pc, game.hex_size * 0.6, 0.0, TAU, 24, game.COL_UNIT_RING, 3.0)
		for d in game.NEIGHBORS:
			var n: Vector2i = game.pending_cell + d
			if game.geometry.in_bounds(n) and not game.walls.has(n) and not game.turret_positions.has(n):
				game.draw_arc(game.geometry.hex_center(n), game.hex_size * 0.3, 0.0, TAU, 16, Color(1.0, 1.0, 1.0, 0.35), 2.0)
	# 一次性道具瞄准：提示鼠标所指格子是否合法目标
	if game.items != null and game.items.is_aiming():
		var hc: Vector2 = game.geometry.hex_center(game.hover_cell)
		var ok: bool = game.items.can_target(game.hover_cell)
		var aim_col: Color = Color("6ee7b7") if ok else Color("f87171")
		game.draw_arc(hc, game.hex_size * 0.62, 0.0, TAU, 24, aim_col, 3.0)
	_draw_special_hint()

## 悬停提示：鼠标停留在特殊地块上时，画一个小信息条（名称 + 描述）
func _draw_special_hint() -> void:
	if not game.special_tiles.has(game.hover_cell):
		return
	var def: Dictionary = game.special_kind_defs.get(str(game.special_tiles[game.hover_cell]), {})
	if def.is_empty():
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var fsize := 13
	var title := "【特殊地块】" + str(def.get("name", "?"))
	var desc := str(def.get("desc", ""))
	var col: Color = Color(str(def.get("color", "#ffffff")))
	var pos: Vector2 = game.geometry.hex_center(game.hover_cell) + Vector2(10, 30)
	var lines := [title, desc]
	var w := 60.0
	for t in lines:
		w = maxf(w, font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x)
	var h := fsize * 2 + 24.0
	var bg := Rect2(pos - Vector2(6, 6), Vector2(w + 14.0, h))
	game.draw_rect(bg, Color(0.04, 0.05, 0.10, 0.92))
	game.draw_rect(bg.grow(-1.0), col.darkened(0.2), false, 1.0)
	var y := pos.y
	var idx := 0
	for t in lines:
		var tc := col.lightened(0.25) if idx == 0 else Color("cfe0ff")
		game.draw_string(font, Vector2(pos.x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, tc)
		y += fsize + 5
		idx += 1

func tile_color(cell: Vector2i) -> Color:
	if game.walls.has(cell):
		return game.COL_WALL
	if game.polluted.has(cell):
		return game.COL_POLLUTED_HI if cell == game.hover_cell else game.COL_POLLUTED
	if cell == game.hover_cell and not game.turret_positions.has(cell) and not game.units.has(cell):
		if game.mode == game.Mode.EDIT:
			return game.COL_TILE_HOVER
		if game.phase == game.Phase.DEPLOY or game.phase == game.Phase.RUNNING:
			# 选中可任意部署的核心时，内层也可悬停高亮
			var anywhere := false
			if game.selected_core >= 0 and game.selected_core < game.core_types.size():
				var t: Dictionary = game.core_types[game.selected_core]
				var bm = game.map_data.behavior_for_mode(str(t.get("mode", "")))
				anywhere = bm.deploy_anywhere()
			if anywhere or game.geometry.is_edge(cell):
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
