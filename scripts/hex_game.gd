extends Node2D

## 六边形污染扩散 —— 玩法示例
## 地图从一个 JSON 文件读取：包含地图尺寸（width/height）、敌方炮台位置（turrets，可为多个）、墙的位置（walls）。
## 部署我方单位（不会移动），每个单位是一个“核心”，拥有持续时间，会污染身下地块；
## 只要还有存活的核心，每个污染地块每隔一段时间就会向周围所有相邻地块扩散；
## 墙会阻挡污染扩散，且不可部署单位。核心结束后，已蔓延出的污染地块保留但不再继续蔓延。
## 每个敌方炮台每隔一段时间攻击，清除离自己最近的污染地块（若为核心所在地块则摧毁核心）。
## 污染到达所有敌方炮台所在地块 => 炮台全部损毁、我方获胜；
## 所有核心持续时间结束而仍有存活炮台 => 我方失败。
## 按 R 打开/关闭控制台，可调整我方与敌方的数值。

# ---------------------------------------------------------------------------
# 配置（运行时可在控制台中调整）
# ---------------------------------------------------------------------------
const MAP_PATH := "res://maps/level1.json"  # 地图数据文件

const HEX_SIZE_DEFAULT := 26.0        # 六边形中心到顶点的距离（像素，默认）
const MAX_UNITS_DEFAULT := 4          # 我方可部署单位数量（默认）
const CORE_DURATION_DEFAULT := 15.0   # 我方单位“核心”持续时间（秒，默认）
const SPREAD_INTERVAL_DEFAULT := 0.9  # 扩散时间间隔（秒，默认）
const ENEMY_ATTACK_INTERVAL_DEFAULT := 0.5  # 敌方攻击间隔（秒，默认）

# 运行时数值（可在控制台修改）
var hex_size := HEX_SIZE_DEFAULT
var max_units := MAX_UNITS_DEFAULT
var core_duration := CORE_DURATION_DEFAULT
var spread_interval := SPREAD_INTERVAL_DEFAULT
var enemy_attack_interval := ENEMY_ATTACK_INTERVAL_DEFAULT

# 地图数据（从文件读取）
var map_width := 0
var map_height := 0
var walls: Dictionary = {}            # Vector2i -> true
var turret_positions: Array[Vector2i] = []  # 所有敌方炮台位置

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
const COL_WALL         := Color("2a303d")
const COL_WALL_EDGE    := Color("6b7688")
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
var turrets: Dictionary = {}    # Vector2i -> 距下次攻击的时间（秒）；存在即存活
var spread_timer := 0.0
var hover_cell := Vector2i(999999, 999999)
var map_offset := Vector2.ZERO
var total_hexes := 0

# 控制台
var console_open := false
var console_layer: CanvasLayer
var sb_units: SpinBox
var sb_core: SpinBox
var sb_spread: SpinBox
var sb_enemy: SpinBox

var status_label: Label
var info_label: Label
var start_button: Button

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------
func _ready() -> void:
	_load_map()
	_fit_hex_size()
	_recenter()
	_build_hud()
	_build_console()
	_reset()
	queue_redraw()

func _process(delta: float) -> void:
	if console_open:
		return
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
	# 2) 所有核心已结束：停止蔓延；若仍有存活炮台则失败
	if units.is_empty():
		if not turrets.is_empty():
			phase = Phase.LOST
		_update_status()
		queue_redraw()
		return
	# 3) 污染蔓延（只要还有存活核心）
	spread_timer += delta
	if spread_timer >= spread_interval:
		spread_timer = 0.0
		_spread_tick()
	if phase != Phase.RUNNING:  # 蔓延导致胜利
		_update_status()
		queue_redraw()
		return
	# 4) 敌方攻击（每个存活炮台独立计时）
	for cell in turrets.keys():
		turrets[cell] = turrets[cell] + delta
		if turrets[cell] >= enemy_attack_interval:
			turrets[cell] = 0.0
			_enemy_attack(cell)
	# 敌方攻击可能摧毁最后一个核心
	if units.is_empty() and not turrets.is_empty():
		phase = Phase.LOST
	_update_status()
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_fit_hex_size()
		_recenter()
		queue_redraw()

# ---------------------------------------------------------------------------
# 地图加载
# ---------------------------------------------------------------------------
func _load_map() -> void:
	map_width = 0
	map_height = 0
	walls.clear()
	turret_positions.clear()
	if FileAccess.file_exists(MAP_PATH):
		var f := FileAccess.open(MAP_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				map_width = int(data.get("width", 0))
				map_height = int(data.get("height", 0))
				# 炮台：支持 "turrets"（数组）与旧的 "turret"（单个）
				var t = data.get("turrets", null)
				if t is Array:
					for entry in t:
						if entry is Dictionary:
							turret_positions.append(Vector2i(int(entry.get("q", 0)), int(entry.get("r", 0))))
				else:
					var single = data.get("turret", null)
					if single is Dictionary:
						turret_positions.append(Vector2i(int(single.get("q", 0)), int(single.get("r", 0))))
				# 墙
				var w = data.get("walls", [])
				if w is Array:
					for entry in w:
						if entry is Dictionary:
							var wc := Vector2i(int(entry.get("q", 0)), int(entry.get("r", 0)))
							walls[wc] = true
	# 回退与校验
	if map_width < 1:
		map_width = 9
	if map_height < 1:
		map_height = 9
	# 清理越界的墙
	for cell in walls.keys():
		if not in_bounds(cell):
			walls.erase(cell)
	# 清理越界或位于墙上的炮台
	var valid: Array[Vector2i] = []
	for p in turret_positions:
		if in_bounds(p) and not walls.has(p):
			valid.append(p)
	turret_positions = valid
	if turret_positions.is_empty():
		turret_positions.append(Vector2i(map_width >> 1, map_height >> 1))
	total_hexes = map_width * map_height

func _recenter() -> void:
	var vs := get_viewport_rect().size
	var target := Vector2(vs.x * 0.5, vs.y * 0.5 + 50.0)
	var cx := (map_width - 1) * 0.5
	var cr := (map_height - 1) * 0.5
	map_offset = target - axial_to_pixel(cx, cr, hex_size)

# 根据地图尺寸自动缩放六边形大小，使地图始终适配窗口
func _fit_hex_size() -> void:
	var vs := get_viewport_rect().size
	var margin := 60.0
	var avail_w := vs.x - margin * 2.0
	var avail_h := vs.y - margin * 2.0 - 90.0  # 顶部 HUD 约 90px
	var by_w := avail_w / (1.5 * (map_width - 1.0) + 2.0)
	var by_h := avail_h / (sqrt(3.0) * ((map_height - 1.0) + (map_width - 1.0) * 0.5 + 1.0))
	hex_size = clampf(minf(HEX_SIZE_DEFAULT, minf(by_w, by_h)), 8.0, HEX_SIZE_DEFAULT)

# ---------------------------------------------------------------------------
# 六边形数学（轴向坐标，平顶六边形）
# ---------------------------------------------------------------------------
static func axial_to_pixel(q: float, r: float, size: float) -> Vector2:
	return Vector2(size * 1.5 * q, size * sqrt(3.0) * (r + q * 0.5))

func hex_center(cell: Vector2i) -> Vector2:
	return map_offset + axial_to_pixel(cell.x, cell.y, hex_size)

func pixel_to_hex(p: Vector2) -> Vector2i:
	var lp := p - map_offset
	var qf := (2.0 / 3.0 * lp.x) / hex_size
	var rf := (-1.0 / 3.0 * lp.x + sqrt(3.0) / 3.0 * lp.y) / hex_size
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
	return cell.x >= 0 and cell.x < map_width and cell.y >= 0 and cell.y < map_height

func all_cells() -> Array[Vector2i]:
	var arr: Array[Vector2i] = []
	for q in range(map_width):
		for r in range(map_height):
			arr.append(Vector2i(q, r))
	return arr

# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), COL_BG)
	for cell in all_cells():
		draw_hex(hex_center(cell), hex_size - 1.2, _tile_color(cell))
	# 墙（内部实心块 + 边框）
	for cell in walls:
		var c := hex_center(cell)
		var s := hex_size * 0.42
		var pts := PackedVector2Array()
		for i in 6:
			var a := deg_to_rad(60.0 * i)
			pts.append(c + Vector2(cos(a), sin(a)) * s)
		draw_colored_polygon(pts, COL_WALL_EDGE)
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, Color(1.0, 1.0, 1.0, 0.18), 1.0)
	# 我方单位（核心）
	for cell in units:
		var c := hex_center(cell)
		draw_circle(c, hex_size * 0.40, COL_UNIT)
		draw_arc(c, hex_size * 0.40, 0.0, TAU, 24, COL_UNIT_RING, 2.0)
		# 持续时间环（随剩余时间缩短）
		var frac := clampf(units[cell] / core_duration, 0.0, 1.0)
		draw_arc(c, hex_size * 0.52, -PI * 0.5, -PI * 0.5 + TAU * frac, 24, COL_UNIT_RING, 3.0)
	# 敌方炮台（可为多个）
	for p in turret_positions:
		var tc := hex_center(p)
		if turrets.has(p):
			draw_circle(tc, hex_size * 0.52, COL_TURRET)
			draw_arc(tc, hex_size * 0.52, 0.0, TAU, 24, COL_TURRET_RING, 2.0)
			var dir := Vector2(0.0, -1.0) * hex_size * 0.82
			var perp := Vector2(hex_size * 0.22, 0.0)
			draw_colored_polygon(PackedVector2Array([tc + dir, tc + perp, tc - perp]), COL_TURRET)
			if phase == Phase.RUNNING:
				# 敌方攻击充能环
				var afrac := clampf(turrets[p] / enemy_attack_interval, 0.0, 1.0)
				draw_arc(tc, hex_size * 0.66, -PI * 0.5, -PI * 0.5 + TAU * afrac, 32, COL_TURRET_RING, 2.5)
		else:
			draw_circle(tc, hex_size * 0.52, COL_TURRET_DEAD)
			draw_line(tc + Vector2(-1, -1) * hex_size * 0.3, tc + Vector2(1, 1) * hex_size * 0.3, COL_TURRET_RING, 3.0)
			draw_line(tc + Vector2(-1, 1) * hex_size * 0.3, tc + Vector2(1, -1) * hex_size * 0.3, COL_TURRET_RING, 3.0)

func _tile_color(cell: Vector2i) -> Color:
	if walls.has(cell):
		return COL_WALL
	if polluted.has(cell):
		return COL_POLLUTED_HI if cell == hover_cell else COL_POLLUTED
	if cell == hover_cell and phase == Phase.DEPLOY and not turret_positions.has(cell) and not units.has(cell):
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
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R:
			if console_open:
				_close_console()
			else:
				_open_console()
			return
		if event.keycode == KEY_ESCAPE:
			if console_open:
				_close_console()
			return
	if console_open:
		return  # 控制台打开时，屏蔽游戏交互
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

func _try_place(cell: Vector2i) -> void:
	if not in_bounds(cell):
		return
	if walls.has(cell):
		return
	if turret_positions.has(cell):
		return
	if units.has(cell):
		return
	if units.size() >= max_units:
		_set_status("已达到最大部署数量（%d 个）" % max_units)
		return
	units[cell] = core_duration
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
	for p in turrets.keys():
		turrets[p] = 0.0
	start_button.disabled = true
	_update_status()
	queue_redraw()

func _reset() -> void:
	phase = Phase.DEPLOY
	units.clear()
	polluted.clear()
	turrets.clear()
	for p in turret_positions:
		turrets[p] = 0.0
	spread_timer = 0.0
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
			if in_bounds(n) and not polluted.has(n) and not walls.has(n):
				newly[n] = true
	for c in newly:
		_pollute(c)
	# 摧毁被污染的炮台
	var destroyed := false
	for cell in turrets.keys():
		if polluted.has(cell):
			turrets.erase(cell)
			destroyed = true
	# 所有炮台都被摧毁 => 胜利
	if destroyed and turrets.is_empty():
		phase = Phase.WON
	queue_redraw()

# ---------------------------------------------------------------------------
# 敌方攻击
# ---------------------------------------------------------------------------
func _enemy_attack(from: Vector2i) -> void:
	var target = _nearest_polluted(from)
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
	info_label.text = "点击地块部署我方单位（核心），每个核心有持续时间，会污染身下地块并每隔一段时间向周围所有相邻地块扩散；核心结束后污染地块保留但不再蔓延。\n地图从文件读取（含地图尺寸、敌方炮台位置、墙）；墙会阻挡污染扩散且不可部署。\n每个敌方炮台每隔一段时间攻击，清除离自己最近的污染地块（核心所在地块会被摧毁）。\n污染到达所有敌方炮台所在地块则我方获胜；所有核心持续时间结束而仍有存活炮台则我方失败。\n按 R 打开控制台调整数值。"
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
			_set_status("部署阶段：剩余可部署单位 %d 个（每个核心持续 %.0f 秒）" % [max_units - units.size(), core_duration])
		Phase.RUNNING:
			_set_status("扩散中…… 已污染 %d/%d 地块 | 存活核心 %d | 存活炮台 %d" % [polluted.size(), total_hexes, units.size(), turrets.size()])
		Phase.WON:
			_set_status("胜利！所有敌方炮台都被污染损毁")
		Phase.LOST:
			_set_status("失败！所有单位核心已结束，而仍有存活的敌方炮台")

# ---------------------------------------------------------------------------
# 控制台
# ---------------------------------------------------------------------------
func _build_console() -> void:
	console_layer = CanvasLayer.new()
	console_layer.layer = 20
	console_layer.visible = false
	add_child(console_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	console_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	console_layer.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "控制台 · 调整数值"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	# 我方
	vbox.add_child(_section_label("—— 我方 ——"))
	sb_units = _add_spin_row(vbox, "最大部署数量", 1.0, 12.0, 1.0, max_units, true)
	sb_core = _add_spin_row(vbox, "核心持续时间（秒）", 1.0, 120.0, 1.0, core_duration, false)
	sb_spread = _add_spin_row(vbox, "扩散间隔（秒）", 0.1, 10.0, 0.1, spread_interval, false)

	# 敌方
	vbox.add_child(_section_label("—— 敌方 ——"))
	sb_enemy = _add_spin_row(vbox, "攻击间隔（秒）", 0.1, 30.0, 0.1, enemy_attack_interval, false)

	var hint := Label.new()
	hint.text = "修改后点击“应用”生效；按 R 或 Esc 关闭（也可点“关闭”按钮）。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(340, 0)
	hint.add_theme_color_override("font_color", Color("9fb0cc"))
	vbox.add_child(hint)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(hbox)

	var apply_btn := Button.new()
	apply_btn.text = "应用"
	apply_btn.pressed.connect(_console_apply)
	hbox.add_child(apply_btn)

	var default_btn := Button.new()
	default_btn.text = "恢复默认"
	default_btn.pressed.connect(_console_defaults)
	hbox.add_child(default_btn)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(_close_console)
	hbox.add_child(close_btn)

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("8a9bb8"))
	return l

func _add_spin_row(parent: Control, label_text: String, mn: float, mx: float, step: float, initial: float, rounded: bool) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(170, 0)
	row.add_child(lbl)

	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.rounded = rounded
	sb.value = initial
	sb.custom_minimum_size = Vector2(120, 0)
	row.add_child(sb)
	return sb

func _open_console() -> void:
	sb_units.value = max_units
	sb_core.value = core_duration
	sb_spread.value = spread_interval
	sb_enemy.value = enemy_attack_interval
	console_open = true
	console_layer.visible = true
	queue_redraw()

func _close_console() -> void:
	console_open = false
	console_layer.visible = false
	queue_redraw()

func _console_apply() -> void:
	max_units = int(round(sb_units.value))
	core_duration = sb_core.value
	spread_interval = sb_spread.value
	enemy_attack_interval = sb_enemy.value
	_update_status()
	queue_redraw()

func _console_defaults() -> void:
	max_units = MAX_UNITS_DEFAULT
	core_duration = CORE_DURATION_DEFAULT
	spread_interval = SPREAD_INTERVAL_DEFAULT
	enemy_attack_interval = ENEMY_ATTACK_INTERVAL_DEFAULT
	sb_units.value = max_units
	sb_core.value = core_duration
	sb_spread.value = spread_interval
	sb_enemy.value = enemy_attack_interval
	_update_status()
	queue_redraw()
