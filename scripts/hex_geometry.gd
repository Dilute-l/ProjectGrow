class_name HexGeometry
extends RefCounted

## 布局与几何 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：地图居中（recenter）、六边形尺寸适配（fit_hex_size）、
## 轴向坐标 ↔ 屏幕像素换算（axial_to_pixel / hex_center / pixel_to_hex）、
## 立方体距离（cube_dist）、边界与邻接判断（in_bounds / is_edge / is_neighbor）、
## 以及教程聚光灯所覆盖的地图外接矩形（map_spotlight_rect）。
##
## 所有运行时数值（map_radius / hex_size / map_offset）仍由主脚本持有，
## 本模块通过 game 引用读写，不复制任何状态。

var game  # 主脚本（hex_game.gd 的 Node2D 实例）；无类型以保持松耦合

func _init(g) -> void:
	game = g

## 地图整体在屏幕上的偏移（水平居中，略向下让出顶部工具栏）
func recenter() -> void:
	var vs: Vector2 = game.get_viewport_rect().size
	game.map_offset = Vector2(vs.x * 0.5, vs.y * 0.5 + 50.0)

## 依据视口尺寸与地图半径，自适应六边形尺寸（不超过默认值）
func fit_hex_size() -> void:
	var vs: Vector2 = game.get_viewport_rect().size
	var margin: float = 60.0
	var avail_w: float = vs.x - margin * 2.0
	var avail_h: float = vs.y - margin * 2.0 - 90.0
	var by_w: float = avail_w / (3.0 * game.map_radius + 2.0)
	var by_h: float = avail_h / (sqrt(3.0) * (2.0 * game.map_radius + 1.0))
	game.hex_size = clampf(minf(game.HEX_SIZE_DEFAULT, minf(by_w, by_h)), 8.0, game.HEX_SIZE_DEFAULT)

## 轴向坐标（点尖顶）转像素（相对原点）
static func axial_to_pixel(q: float, r: float, size: float) -> Vector2:
	return Vector2(size * 1.5 * q, size * sqrt(3.0) * (r + q * 0.5))

## 某地块中心的屏幕坐标
func hex_center(cell: Vector2i) -> Vector2:
	return game.map_offset + axial_to_pixel(cell.x, cell.y, game.hex_size)

## 屏幕坐标反解为轴向坐标（四舍五入到最近的六边形）
func pixel_to_hex(p: Vector2) -> Vector2i:
	var lp: Vector2 = p - game.map_offset
	var qf: float = (2.0 / 3.0 * lp.x) / game.hex_size
	var rf: float = (-1.0 / 3.0 * lp.x + sqrt(3.0) / 3.0 * lp.y) / game.hex_size
	var xf: float = qf
	var zf: float = rf
	var yf: float = -xf - zf
	var rx: int = roundi(xf)
	var ry: int = roundi(yf)
	var rz: int = roundi(zf)
	var dx: float = absf(rx - xf)
	var dy: float = absf(ry - yf)
	var dz: float = absf(rz - zf)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(rx, rz)

## 六边形轴向坐标的立方体距离
func cube_dist(a: Vector2i, b: Vector2i) -> int:
	var dx := a.x - b.x
	var dz := a.y - b.y
	var dy := -dx - dz
	return maxi(absi(dx), maxi(absi(dy), absi(dz)))

## 是否在地图半径范围内
func in_bounds(cell: Vector2i) -> bool:
	return cube_dist(cell, Vector2i.ZERO) <= game.map_radius

## 地图范围内所有地块
func all_cells() -> Array[Vector2i]:
	var arr: Array[Vector2i] = []
	for q in range(-game.map_radius, game.map_radius + 1):
		for r in range(-game.map_radius, game.map_radius + 1):
			var c := Vector2i(q, r)
			if in_bounds(c):
				arr.append(c)
	return arr

## 两个地块是否相邻
func is_neighbor(a: Vector2i, b: Vector2i) -> bool:
	return game.NEIGHBORS.has(a - b)

## 是否在最外围一圈
func is_edge(cell: Vector2i) -> bool:
	return cube_dist(cell, Vector2i.ZERO) == game.map_radius

## 教程聚光灯覆盖的地图外接矩形
func map_spotlight_rect() -> Rect2:
	var w: float = game.hex_size * (3.0 * game.map_radius + 2.0)
	var h: float = game.hex_size * (sqrt(3.0) * (2.0 * game.map_radius + 1.0))
	return Rect2(game.map_offset - Vector2(w, h) * 0.5, Vector2(w, h)).grow(20.0)
