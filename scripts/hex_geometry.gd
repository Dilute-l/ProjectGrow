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

## 地图六边形尺寸的上下限（像素）。下限防止过小看不清；上限放宽到足够大，
## 使地图能随窗口变大而放大、随窗口变小而缩小。
const MIN_HEX_SIZE := 8.0
const MAX_HEX_SIZE := 200.0

func _init(g) -> void:
	game = g

## 地图整体在屏幕上的偏移（水平居中，略向下让出顶部工具栏）
func recenter() -> void:
	var vs: Vector2 = game.get_viewport_rect().size
	game.map_offset = Vector2(vs.x * 0.5, vs.y * 0.5 + 50.0)

## 依据视口尺寸与地图半径，自适应六边形尺寸，使地图随窗口缩放自动缩放。
## 地图整体始终完整落在视口内（留出边距）：窗口变大则地图放大，窗口变小则缩小。
func fit_hex_size() -> void:
	var vs: Vector2 = game.get_viewport_rect().size
	var margin: float = 60.0
	var avail_w: float = vs.x - margin * 2.0
	var avail_h: float = vs.y - margin * 2.0 - 90.0
	var by_w: float = avail_w / (sqrt(3.0) * (2.0 * game.map_radius + 1.0))
	var by_h: float = avail_h / (3.0 * game.map_radius + 2.0)
	game.hex_size = clampf(minf(by_w, by_h), MIN_HEX_SIZE, MAX_HEX_SIZE)

## 轴向坐标（尖顶朝上 / pointy-top）转像素（相对原点）
static func axial_to_pixel(q: float, r: float, size: float) -> Vector2:
	return Vector2(size * sqrt(3.0) * (q + r * 0.5), size * 1.5 * r)

## 六边形进度环：返回沿正六边形（尖顶朝上）周长按 frac 比例走出的折线点。
## 从顶部顶点开始顺时针绕行；正六边形边长 = radius（circumradius）。
## 用于把圆形计时环（核心剩余时间 / 炮台充能）改画成六边形，贴在格子边缘。
static func hex_progress_points(center: Vector2, radius: float, frac: float) -> PackedVector2Array:
	frac = clampf(frac, 0.0, 1.0)
	var out := PackedVector2Array()
	if frac <= 0.0:
		return out
	var verts: Array[Vector2] = []
	for i in 6:
		var a := deg_to_rad(-90.0 + 60.0 * i)  # 顶部顶点起，顺时针
		verts.append(center + Vector2(cos(a), sin(a)) * radius)
	var target := frac * 6.0 * radius  # 总周长 = 6 * 边长 = 6 * radius
	var walked := 0.0
	out.append(verts[0])
	for i in 6:
		var a: Vector2 = verts[i]
		var b: Vector2 = verts[(i + 1) % 6]
		var seg := a.distance_to(b)
		if walked + seg >= target:
			var t := clampf((target - walked) / seg, 0.0, 1.0)
			out.append(a.lerp(b, t))
			break
		out.append(b)
		walked += seg
	return out

## 把轴向向量 v 映射到 6 邻域方向中最接近的一个（用像素空间点积比方向）。
## v 可以是任意轴向向量（如 (2,0)）；返回最接近的单位邻居方向；零向量返回零向量。
func nearest_dir(v: Vector2i) -> Vector2i:
	if v == Vector2i.ZERO:
		return Vector2i.ZERO
	var px := sqrt(3.0) * (float(v.x) + float(v.y) * 0.5)
	var py := 1.5 * float(v.y)
	var best := Vector2i(1, 0)
	var best_dot := -1e30
	for d: Vector2i in game.NEIGHBORS:
		var dx := sqrt(3.0) * (float(d.x) + float(d.y) * 0.5)
		var dy := 1.5 * float(d.y)
		var dot := px * dx + py * dy
		if dot > best_dot:
			best_dot = dot
			best = d
	return best

## 某地块中心的屏幕坐标
func hex_center(cell: Vector2i) -> Vector2:
	return game.map_offset + axial_to_pixel(cell.x, cell.y, game.hex_size)

## 屏幕坐标反解为轴向坐标（尖顶布局，四舍五入到最近的六边形）
func pixel_to_hex(p: Vector2) -> Vector2i:
	var lp: Vector2 = p - game.map_offset
	var px: float = lp.x / game.hex_size
	var py: float = lp.y / game.hex_size
	var xf: float = sqrt(3.0) / 3.0 * px - 1.0 / 3.0 * py
	var zf: float = 2.0 / 3.0 * py
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
	var w: float = game.hex_size * (sqrt(3.0) * (2.0 * game.map_radius + 1.0))
	var h: float = game.hex_size * (3.0 * game.map_radius + 2.0)
	return Rect2(game.map_offset - Vector2(w, h) * 0.5, Vector2(w, h)).grow(20.0)
