class_name TurretOverlay
extends Node2D

## 敌方炮台覆盖层 —— 独立于主节点 _draw，用更高 z_index 让炮台渲染在最上层。
## 只读取父节点 Main（hex_game.gd）公开的 turret_positions / turret_types /
## turret_map / geometry / hex_size / mode / phase / COL_TURRET / COL_TURRET_DEAD。

# 敌方炮台贴图（basic/sniper 有贴图；rapid/beam 保持矢量本体）
const TEX_TURRET_BASIC := preload("res://images/magica/enemy_basic.png")
const TEX_TURRET_SNIPER := preload("res://images/magica/enemy_sniper.png")
# 贴图实测几何（原图 6554×6554）：六边形边长 = 5000/√3 ≈ 2886.75，中心 (3135.5, 3364.25)
const TURRET_ART_EDGE := 2886.75
const TURRET_ART_CENTER := Vector2(3135.5, 3364.25)
# 贴图主导色（实测 alpha>128 平均），用于充能环着色
const TURRET_BASIC_COLOR := Color("#9EA07C")
const TURRET_SNIPER_COLOR := Color("#956E97")

func _process(_delta: float) -> void:
	queue_redraw()  # 充能环进度与存活状态每帧变化，直接每帧重绘（炮台数量少，开销可忽略）

func _draw() -> void:
	var main = get_parent()
	if main == null:
		return
	for p in main.turret_positions:
		var type_name: String = str(main.turret_types.get(p, "basic"))
		var body_col: Color = _turret_body_color(type_name, main)
		var ring_col: Color = _turret_ring_color(type_name, main)
		var tc: Vector2 = main.geometry.hex_center(p)
		var t: EnemyTurret = main.turret_map.get(p)
		var alive: bool = main.mode == main.Mode.EDIT or (t != null and t.alive)
		if alive:
			var tex: Texture2D = _turret_texture(type_name)
			if tex != null:
				_draw_turret_texture(tc, tex, main.hex_size)
			else:
				# 无贴图的类型（rapid/beam）：沿用原矢量本体
				draw_circle(tc, main.hex_size * 0.52, body_col)
				draw_arc(tc, main.hex_size * 0.52, 0.0, TAU, 24, ring_col, 2.0)
				var dir: Vector2 = Vector2(0.0, -1.0) * main.hex_size * 0.82
				var perp := Vector2(main.hex_size * 0.22, 0.0)
				draw_colored_polygon(PackedVector2Array([tc + dir, tc + perp, tc - perp]), body_col)
			if main.phase == main.Phase.RUNNING and main.mode == main.Mode.PLAY and t != null:
				var afrac: float = t.charge_fraction()
				var charge_pts := HexGeometry.hex_progress_points(tc, main.hex_size, afrac)
				if charge_pts.size() >= 2:
					draw_polyline(charge_pts, ring_col, 2.5)
		else:
			draw_circle(tc, main.hex_size * 0.52, main.COL_TURRET_DEAD)
			draw_line(tc + Vector2(-1, -1) * main.hex_size * 0.3, tc + Vector2(1, 1) * main.hex_size * 0.3, ring_col, 3.0)
			draw_line(tc + Vector2(-1, 1) * main.hex_size * 0.3, tc + Vector2(1, -1) * main.hex_size * 0.3, ring_col, 3.0)

## 炮台类型 -> 主体颜色
func _turret_body_color(type_name: String, main) -> Color:
	match type_name:
		"sniper":
			return Color("ffa726")   # 橙色
		"rapid":
			return Color("26c6da")   # 青色
		"beam":
			return Color("ab47bc")   # 紫色
		_:
			return main.COL_TURRET   # 红色（基础）

## 炮台类型 -> 外圈/充能环颜色；有贴图的类型用贴图主导色提亮，其余用矢量主体色提亮
func _turret_ring_color(type_name: String, main) -> Color:
	match type_name:
		"basic":
			return TURRET_BASIC_COLOR.lightened(0.4)
		"sniper":
			return TURRET_SNIPER_COLOR.lightened(0.4)
	return _turret_body_color(type_name, main).lightened(0.55)

## 炮台类型 -> 本体贴图；无贴图的类型（rapid/beam）返回 null
func _turret_texture(type_name: String) -> Texture2D:
	match type_name:
		"basic":
			return TEX_TURRET_BASIC
		"sniper":
			return TEX_TURRET_SNIPER
	return null

## 在 center 绘制一张炮台贴图：以贴图内六边形中心为锚点对齐格子中心
func _draw_turret_texture(center: Vector2, tex: Texture2D, hex_size: float) -> void:
	var scale: float = hex_size / TURRET_ART_EDGE
	var span: float = float(tex.get_width()) * scale
	var top_left: Vector2 = center - TURRET_ART_CENTER * scale
	draw_texture_rect(tex, Rect2(top_left, Vector2(span, span)), false)
