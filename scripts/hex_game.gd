extends Node2D

## 六边形污染扩散 —— 玩法示例
## 部署我方单位（不会移动），每个单位是一个“核心”，拥有持续时间，会污染身下地块；
## 只要还有存活的核心，每个污染地块每隔一段时间就会向周围所有相邻地块扩散；
## 核心结束后，已蔓延出的污染地块保留但不再继续蔓延。敌方炮台每隔一段时间攻击，
## 清除离自己最近的污染地块（若为核心所在地块则摧毁核心）。
## 污染到达中央炮台所在地块 => 炮台损毁、我方获胜；
## 所有核心持续时间结束而敌方仍存活 => 我方失败。

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
const HEX_SIZE := 26.0            # 六边形中心到顶点的距离（像素）
const GRID_RADIUS := 4            # 六边形地图半径（中心向外层数）
const MAX_UNITS := 4              # 可部署的我方单位数量
const SPREAD_INTERVAL := 0.9      # 每次扩散的时间间隔（秒）
const CORE_DURATION := 15.0       # 每个单位“核心”的持续时间（秒）
const ENEMY_ATTACK_INTERVAL := 0.5  # 敌方每次攻击的间隔（秒）

const COL_BG           := Color("0d1321")
const COL_TILE         := Color("243045")
const COL_TILE_HOVER   := Color("35476b")
const COL_POLLUTED     := Color("5f2fd6")
const COL_POLLUTED_HI  := Color("8a5cff")
const COL_UNIT         := Color("3fc1ff")
const COL_UNIT_RING    := Color("d7f3ff")
const COL_TURRET       := Color("ff5252")
const COL_TURRET_RING  := Color("ffd6d6")
const COL_TURRET_DEAD  := Color("4a2525")
const COL_LINE         := Color(1.0, 1.0, 1.0, 0.10)

enum Phase { DEPLOY, RUNNING, WON, LOST }

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(-1, 1),
	Vector2i(0, 1), Vector2i(0, -1),
]

var phase := Phase.DEPLOY
var units: Dictionary = {}      # Vector2i -> 剩余持续时间（秒）
var polluted: Dictionary = {}   # Vector2i -> true
var turret_coord := Vector2i.ZERO
var turret_alive := true
var spread_timer := 0.0
var enemy_attack_timer := 0.0
var hover_cell := Vector2i(999999, 999999)
var map_offset := Vector2.ZERO
var total_hexes := 0

var status_label: Label
var info_label: Label
var start_button: Button

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------
func _ready() -> void:
	_recenter()
	total_hexes = all_cells().size()
	_build_hud()
	_update_status()
	queue_redraw()

func _process(delta: float) -> void:
	if phase != Phase.RUNNING:
		return
	# 1) 核心倒计时（到期后核心消失，但其污染地块保留）
	var expired: Array = []
	for cell in units.keys():
		units[cell] = units[cell] - delta
		if units[cell] <= 0.0:
			expired.append(cell)
	for cell in expired:
		units.erase(cell)
	# 2) 所有核心已结束：停止蔓延；若敌方仍存活则失败
	if units.is_empty():
		if turret_alive:
			phase = Phase.LOST
		_update_status()
		queue_redraw()
		return
	# 3) 污染蔓延（只要还有存活核心）
	spread_timer += delta
	if spread_timer >= SPREAD_INTERVAL:
		spread_timer = 0.0
		_spread_tick()
	if phase != Phase.RUNNING:  # 蔓延导致胜利
		_update_status()
		queue_redraw()
		return
	# 4) 敌方攻击
	enemy_attack_timer += delta
	if enemy_attack_timer >= ENEMY_ATTACK_INTERVAL:
		enemy_attack_timer = 0.0
		_enemy_attack()
	# 敌方攻击可能摧毁最后一个核心
	if units.is_empty() and turret_alive:
		phase = Phase.LOST
	_update_status()
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_recenter()
		queue_redraw()

func _recenter() -> void:
	var vs := get_viewport_rect().size
	map_offset = Vector2(vs.x * 0.5, vs.y * 0.5 + 50.0)

# ---------------------------------------------------------------------------
# 六边形数学（轴向坐标，平顶六边形）
# ---------------------------------------------------------------------------
static func axial_to_pixel(q: int, r: int, size: float) -> Vector2:
	return Vector2(size * 1.5 * q, size * sqrt(3.0) * (r + q * 0.5))

func hex_center(cell: Vector2i) -> Vector2:
	return map_offset + axial_to_pixel(cell.x, cell.y, HEX_SIZE)

func pixel_to_hex(p: Vector2) -> Vector2i:
	var lp := p - map_offset
	var qf := (2.0 / 3.0 * lp.x) / HEX_SIZE
	var rf := (-1.0 / 3.0 * lp.x + sqrt(3.0) / 3.0 * lp.y) / HEX_SIZE
	var xf := qf
	var zf := rf
	var yf := -xf - zf
	var rx := roundi(xf)
	var ry := roundi(yf)
	var rz := roundi(zf)
	var dx := absf(rx - xf)
	var dy := absf(ry - yf)
	var dz := absf(rz - zf)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(rx, rz)

func cube_dist(a: Vector2i, b: Vector2i) -> int:
	var dx := a.x - b.x
	var dz := a.y - b.y
	var dy := -dx - dz
	return maxi(absi(dx), maxi(absi(dy), absi(dz)))

func in_bounds(cell: Vector2i) -> bool:
	return cube_dist(cell, Vector2i.ZERO) <= GRID_RADIUS

func all_cells() -> Array[Vector2i]:
	var arr: Array[Vector2i] = []
	for q in range(-GRID_RADIUS, GRID_RADIUS + 1):
		for r in range(-GRID_RADIUS, GRID_RADIUS + 1):
			var c := Vector2i(q, r)
			if in_bounds(c):
				arr.append(c)
	return arr

# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), COL_BG)
	for cell in all_cells():
		draw_hex(hex_center(cell), HEX_SIZE - 1.2, _tile_color(cell))
	# 我方单位（核心）
	for cell in units:
		var c := hex_center(cell)
		draw_circle(c, HEX_SIZE * 0.40, COL_UNIT)
		draw_arc(c, HEX_SIZE * 0.40, 0.0, TAU, 24, COL_UNIT_RING, 2.0)
		# 持续时间环（随剩余时间缩短）
		var frac := clampf(units[cell] / CORE_DURATION, 0.0, 1.0)
		draw_arc(c, HEX_SIZE * 0.52, -PI * 0.5, -PI * 0.5 + TAU * frac, 24, COL_UNIT_RING, 3.0)
	# 敌方炮台
	var tc := hex_center(turret_coord)
	if turret_alive:
		draw_circle(tc, HEX_SIZE * 0.52, COL_TURRET)
		draw_arc(tc, HEX_SIZE * 0.52, 0.0, TAU, 24, COL_TURRET_RING, 2.0)
		var dir := Vector2(0.0, -1.0) * HEX_SIZE * 0.82
		var perp := Vector2(HEX_SIZE * 0.22, 0.0)
		draw_colored_polygon(PackedVector2Array([tc + dir, tc + perp, tc - perp]), COL_TURRET)
		if phase == Phase.RUNNING:
			# 敌方攻击充能环
			var afrac := clampf(enemy_attack_timer / ENEMY_ATTACK_INTERVAL, 0.0, 1.0)
			draw_arc(tc, HEX_SIZE * 0.66, -PI * 0.5, -PI * 0.5 + TAU * afrac, 32, COL_TURRET_RING, 2.5)
	else:
		draw_circle(tc, HEX_SIZE * 0.52, COL_TURRET_DEAD)
		draw_line(tc + Vector2(-1, -1) * HEX_SIZE * 0.3, tc + Vector2(1, 1) * HEX_SIZE * 0.3, COL_TURRET_RING, 3.0)
		draw_line(tc + Vector2(-1, 1) * HEX_SIZE * 0.3, tc + Vector2(1, -1) * HEX_SIZE * 0.3, COL_TURRET_RING, 3.0)

func _tile_color(cell: Vector2i) -> Color:
	var polluted_here := polluted.has(cell)
	var hovered := cell == hover_cell
	if polluted_here:
		return COL_POLLUTED_HI if hovered else COL_POLLUTED
	if hovered and phase == Phase.DEPLOY and cell != turret_coord and not units.has(cell):
		return COL_TILE_HOVER
	return COL_TILE

func draw_hex(center: Vector2, size: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		pts.append(center + Vector2(cos(a), sin(a)) * size)
	draw_colored_polygon(pts, col)
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, COL_LINE, 1.0)

# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hover_cell = pixel_to_hex(event.position)
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		var cell := pixel_to_hex(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT and phase == Phase.DEPLOY:
			_try_place(cell)
		elif event.button_index == MOUSE_BUTTON_RIGHT and phase == Phase.DEPLOY:
			_try_remove(cell)
	elif event is InputEventKey and event.pressed:
		if (event.keycode == KEY_SPACE or event.keycode == KEY_ENTER) and phase == Phase.DEPLOY:
			_start()
		elif event.keycode == KEY_R:
			_reset()

func _try_place(cell: Vector2i) -> void:
	if not in_bounds(cell):
		return
	if cell == turret_coord:
		return
	if units.has(cell):
		return
	if units.size() >= MAX_UNITS:
		_set_status("已达到最大部署数量（%d 个）" % MAX_UNITS)
		return
	units[cell] = CORE_DURATION
	_pollute(cell)
	_update_status()
	queue_redraw()

func _try_remove(cell: Vector2i) -> void:
	if units.has(cell):
		units.erase(cell)
		polluted.erase(cell)  # 部署阶段尚未开始扩散，可撤销污染
		_update_status()
		queue_redraw()

func _start() -> void:
	if phase != Phase.DEPLOY:
		return
	if units.is_empty():
		_set_status("请至少部署一个单位")
		return
	phase = Phase.RUNNING
	spread_timer = 0.0
	enemy_attack_timer = 0.0
	start_button.disabled = true
	_update_status()
	queue_redraw()

func _reset() -> void:
	phase = Phase.DEPLOY
	units.clear()
	polluted.clear()
	turret_alive = true
	spread_timer = 0.0
	enemy_attack_timer = 0.0
	start_button.disabled = false
	_update_status()
	queue_redraw()

# ---------------------------------------------------------------------------
# 污染扩散
# ---------------------------------------------------------------------------
func _pollute(cell: Vector2i) -> void:
	polluted[cell] = true

func _spread_tick() -> void:
	var snapshot: Array = polluted.keys()
	var newly: Dictionary = {}
	for cell in snapshot:
		for d in NEIGHBORS:
			var n: Vector2i = cell + d
			if in_bounds(n) and not polluted.has(n):
				newly[n] = true
	for c in newly:
		_pollute(c)
	if turret_alive and polluted.has(turret_coord):
		turret_alive = false
		phase = Phase.WON
	queue_redraw()

# ---------------------------------------------------------------------------
# 敌方攻击
# ---------------------------------------------------------------------------
func _enemy_attack() -> void:
	var target = _nearest_polluted(turret_coord)
	if target == null:
		return
	polluted.erase(target)
	if units.has(target):
		units.erase(target)  # 摧毁我方单位核心
	queue_redraw()

func _nearest_polluted(from: Vector2i) -> Variant:
	var best = null
	var best_d := 1 << 30
	for cell in polluted.keys():
		var d := cube_dist(cell, from)
		if d < best_d:
			best_d = d
			best = cell
	return best

# ---------------------------------------------------------------------------
# HUD
# ---------------------------------------------------------------------------
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16, 12)
	layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "六边形污染扩散"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	info_label = Label.new()
	info_label.text = "点击地块部署我方单位（核心），每个核心有持续时间，会污染身下地块并每隔一段时间向周围所有相邻地块扩散；核心结束后污染地块保留但不再蔓延。\n敌方炮台每隔一段时间攻击，清除离自己最近的污染地块（核心所在地块会被摧毁）。\n污染到达中央炮台所在地块则我方获胜；所有核心持续时间结束而敌方仍存活则我方失败。"
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.custom_minimum_size = Vector2(460, 0)
	vbox.add_child(info_label)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", Color("ffd166"))
	vbox.add_child(status_label)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(hbox)

	start_button = Button.new()
	start_button.text = "开始扩散"
	start_button.pressed.connect(_start)
	hbox.add_child(start_button)

	var reset_button := Button.new()
	reset_button.text = "重置"
	reset_button.pressed.connect(_reset)
	hbox.add_child(reset_button)

func _set_status(text: String) -> void:
	if status_label:
		status_label.text = text

func _update_status() -> void:
	match phase:
		Phase.DEPLOY:
			_set_status("部署阶段：剩余可部署单位 %d 个（每个核心持续 %.0f 秒）" % [MAX_UNITS - units.size(), CORE_DURATION])
		Phase.RUNNING:
			var next_attack := maxf(ENEMY_ATTACK_INTERVAL - enemy_attack_timer, 0.0)
			_set_status("扩散中…… 已污染 %d/%d 地块 | 存活核心 %d | 敌方 %.1f 秒后攻击" % [polluted.size(), total_hexes, units.size(), next_attack])
		Phase.WON:
			_set_status("胜利！敌方炮台所在地块已被污染，炮台损毁")
		Phase.LOST:
			_set_status("失败！所有单位核心已结束，而敌方炮台仍存活")
