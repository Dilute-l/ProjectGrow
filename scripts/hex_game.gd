extends Node2D

## 六边形污染扩散 —— 玩法示例
## 地图从 level1.json 读取（半径、敌方炮台位置、墙）；核心类型从 cores.json 读取（含持续时间、扩散间隔、颜色、模式）。
## 两种模式（Tab 或左上角按钮切换）：
##   - 游玩模式：部署核心、污染扩散、与敌方炮台对战；
##   - 地图编辑模式：放置/擦除墙与炮台、调整半径、导入/导出地图 JSON。
## 核心类型（右下角选择）：
##   - 扩散核心（radial）：污染身下地块，并每隔一段时间向周围所有相邻地块扩散；
##   - 定向核心（directional）：部署时须点击相邻地块选择方向，其污染的地块会沿该方向扩散。
## 只能在地图最外围一圈部署单位；墙阻挡污染且不可部署；核心到期后其污染地块保留但不再扩散。
## 每个敌方炮台每隔一段时间攻击，清除离自己最近的污染地块。
## 污染到达所有敌方炮台所在地块 => 胜利；所有核心结束而仍有存活炮台 => 失败。
## 按 R 打开/关闭控制台，可调整最大部署数量与敌方攻击间隔。

# ---------------------------------------------------------------------------
# 路径与默认值
# ---------------------------------------------------------------------------
const MAP_PATH := "res://maps/level1.json"    # 地图数据文件
const CORES_PATH := "res://maps/cores.json"   # 核心数据文件

const HEX_SIZE_DEFAULT := 26.0              # 六边形中心到顶点的距离（像素，默认）
const MAX_UNITS_DEFAULT := 4                # 最大部署数量（默认）
const ENEMY_ATTACK_INTERVAL_DEFAULT := 0.5  # 敌方攻击间隔（秒，默认）
const TURRET_ATTACK_RANGE := 3              # 炮台攻击范围（格），用于范围高亮；与 enemy_turret.gd 默认一致

# 运行时数值（可在控制台修改）
var hex_size := HEX_SIZE_DEFAULT
var max_units := MAX_UNITS_DEFAULT
var enemy_attack_interval := ENEMY_ATTACK_INTERVAL_DEFAULT

# 地图数据（从文件读取 / 编辑）
var map_radius := 0                            # 六边形地图半径（中心向外层数）
var walls: Dictionary = {}                    # Vector2i -> true
var turret_positions: Array[Vector2i] = []    # 所有敌方炮台位置

# 核心数据（从文件读取）
var core_types: Array = []     # 每个元素为 Dictionary：{id,name,mode,duration,spread_interval,color}（数据来自 cores.json）

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
# units: Vector2i -> PlayerCore 节点（我方可部署核心，每颗 = 一个场景实例）
var units: Dictionary = {}
var polluted: Dictionary = {}               # 所有被污染地块：Vector2i -> {mode,dir}（胜利判定与敌方攻击用）
const CORE_SCENE := preload("res://scenes/player_core.tscn")  # 我方核心独立场景（模块化）
var core_container: Node2D               # 我方核心场景实例容器
const TURRET_SCENE := preload("res://scenes/enemy_turret.tscn")  # 敌方炮台独立场景（模块化）
var turret_map: Dictionary = {}            # Vector2i -> EnemyTurret 节点（存活/计时在节点内部）
var turret_container: Node2D               # 敌方炮台场景实例容器
var mode_spread_timers: Dictionary = {}    # 模式名 -> 该模式扩散累计秒数
var mode_intervals: Dictionary = {}        # 模式名 -> 该模式扩散间隔（秒，来自 cores.json）
var hover_cell := Vector2i(999999, 999999)
var map_offset := Vector2.ZERO
var total_hexes := 0

# 核心选择与定向部署
var selected_core := 0
var awaiting_direction := false
var pending_cell := Vector2i.ZERO
var pending_type := 0

# 控制台
var console_open := false
var console_layer: CanvasLayer
var sb_units: SpinBox
var sb_enemy: SpinBox

var status_label: Label
var info_label: Label
var start_button: Button
var tutorial_box: VBoxContainer
var core_buttons: Array[Button] = []
var core_selector_layer: CanvasLayer

# 地图编辑器
enum Mode { PLAY, EDIT }
var mode := Mode.PLAY
var editor_brush := 0              # 0=墙, 1=炮台
var editor_layer: CanvasLayer
var mode_button: Button
var radius_label: Label
var wall_btn: Button
var turret_btn: Button
var file_dialog: FileDialog
var file_dialog_purpose := 0       # 0=导入, 1=导出

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------
func _ready() -> void:
	_load_map()
	_load_cores()
	_register_core_modes()
	selected_core = clampi(selected_core, 0, core_types.size() - 1)
	_fit_hex_size()
	_recenter()
	_build_hud()
	_build_console()
	_build_core_selector()
	_build_editor_ui()
	_build_file_dialog()
	_reset()
	queue_redraw()

func _process(delta: float) -> void:
	if console_open:
		return
	if mode != Mode.PLAY:
		return
	if phase != Phase.RUNNING:
		return
	# 1) 核心倒计时（到期后核心消失，但其污染地块保留）
	var expired: Array = []
	for cell in units.keys():
		var n: PlayerCore = units[cell]
		if n.advance(delta):
			expired.append(cell)
	for cell in expired:
		_remove_core(cell)
	# 2) 所有核心已结束：停止蔓延；若仍有存活炮台则失败
	if units.is_empty():
		if _alive_turret_count() > 0:
			phase = Phase.LOST
		_update_status()
		queue_redraw()
		return
	# 3)+4) 各模式扩散：有该模式的存活核心，就按该模式间隔蔓延其污染地块
	var active_modes: Dictionary = {}
	for n in units.values():
		active_modes[n.mode()] = true
	for m in active_modes:
		var bm := CoreMode.for_mode(m)
		if bm == null:
			continue
		var iv: float = mode_intervals.get(m, bm.interval_fallback())
		mode_spread_timers[m] = mode_spread_timers.get(m, 0.0) + delta
		if mode_spread_timers[m] >= iv:
			mode_spread_timers[m] = 0.0
			_spread_mode(m, bm)
	# 5) 炮台摧毁 / 胜利判定
	_check_turret_destruction()
	if phase != Phase.RUNNING:
		_update_status()
		queue_redraw()
		return
	# 6) 敌方攻击（每个存活炮台独立计时）
	for t in turret_map.values():
		if t.tick(delta, polluted, units):
			queue_redraw()
	if units.is_empty() and _alive_turret_count() > 0:
		phase = Phase.LOST
	_free_orphan_cores()
	_update_status()
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_fit_hex_size()
		_recenter()
		queue_redraw()

# ---------------------------------------------------------------------------
# 数据加载 / 地图序列化
# ---------------------------------------------------------------------------
func _load_map() -> void:
	var loaded := false
	if FileAccess.file_exists(MAP_PATH):
		var f := FileAccess.open(MAP_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				_apply_map_data(data)
				loaded = true
	if not loaded:
		_apply_map_data({"radius": 5})
	if turret_positions.is_empty():
		turret_positions.append(Vector2i.ZERO)
	total_hexes = all_cells().size()

func _apply_map_data(data: Dictionary) -> void:
	map_radius = int(data.get("radius", 5))
	if map_radius < 1:
		map_radius = 5
	walls.clear()
	turret_positions.clear()
	var t = data.get("turrets", null)
	if t is Array:
		for entry in t:
			if entry is Dictionary:
				turret_positions.append(Vector2i(int(entry.get("q", 0)), int(entry.get("r", 0))))
	else:
		var single = data.get("turret", null)
		if single is Dictionary:
			turret_positions.append(Vector2i(int(single.get("q", 0)), int(single.get("r", 0))))
	var w = data.get("walls", [])
	if w is Array:
		for entry in w:
			if entry is Dictionary:
				walls[Vector2i(int(entry.get("q", 0)), int(entry.get("r", 0)))] = true
	_prune_map()

func _prune_map() -> void:
	for cell in walls.keys():
		if not in_bounds(cell):
			walls.erase(cell)
	var valid: Array[Vector2i] = []
	for p in turret_positions:
		if in_bounds(p) and not walls.has(p):
			valid.append(p)
	turret_positions = valid

func _map_to_dict() -> Dictionary:
	var turrets_arr: Array = []
	for p in turret_positions:
		turrets_arr.append({"q": p.x, "r": p.y})
	var walls_arr: Array = []
	for cell in walls:
		walls_arr.append({"q": cell.x, "r": cell.y})
	return {"radius": map_radius, "turrets": turrets_arr, "walls": walls_arr}

func _export_map(path: String) -> void:
	if not path.ends_with(".json"):
		path += ".json"
	var text := JSON.stringify(_map_to_dict(), "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		_set_status("已导出地图：" + path)
	else:
		_set_status("导出失败：无法写入 " + path)

func _import_map(path: String) -> void:
	if not FileAccess.file_exists(path):
		_set_status("导入失败：文件不存在 " + path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_set_status("导入失败：无法读取 " + path)
		return
	var text := f.get_as_text()
	f.close()
	var data = JSON.parse_string(text)
	if data is Dictionary:
		_apply_map_data(data)
		total_hexes = all_cells().size()
		_fit_hex_size()
		_recenter()
		_reset()
		if radius_label:
			radius_label.text = "半径 %d" % map_radius
		_set_status("已导入地图：" + path)
	else:
		_set_status("导入失败：JSON 格式错误")
	queue_redraw()

func _load_cores() -> void:
	core_types.clear()
	if FileAccess.file_exists(CORES_PATH):
		var f := FileAccess.open(CORES_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				var arr = data.get("cores", [])
				if arr is Array:
					for entry in arr:
						if entry is Dictionary:
							core_types.append({
								"id": str(entry.get("id", "core")),
								"name": str(entry.get("name", "核心")),
								"mode": str(entry.get("mode", "radial")),
								"duration": float(entry.get("duration", 15.0)),
								"spread_interval": float(entry.get("spread_interval", 0.9)),
								"color": str(entry.get("color", "#3fc1ff")),
							})
	if core_types.is_empty():
		core_types.append({"id": "spread", "name": "扩散核心", "mode": "radial", "duration": 15.0, "spread_interval": 0.9, "color": "#3fc1ff"})
	mode_intervals.clear()
	for t in core_types:
		mode_intervals[str(t["mode"])] = float(t["spread_interval"])

func _core_color(t: Dictionary) -> Color:
	var hex := str(t.get("color", ""))
	if hex == "":
		return COL_UNIT
	return Color(hex)

# 注册内置核心行为模式；以后新增「新模式」只需：cores.json 条目 + CoreMode 子类 + 此处一行注册
func _register_core_modes() -> void:
	CoreMode.register("radial", RadialCoreMode.new())
	CoreMode.register("directional", DirectionalCoreMode.new())

# 取模式行为；未注册的模式按径向兜底并告警
func _behavior_for_mode(mode_name: String) -> CoreMode:
	var b := CoreMode.for_mode(mode_name)
	if b == null:
		push_warning("未注册的核心模式「%s」，按径向处理" % mode_name)
		b = CoreMode.for_mode("radial")
	return b

# ---------------------------------------------------------------------------
# 布局与几何
# ---------------------------------------------------------------------------
func _recenter() -> void:
	var vs := get_viewport_rect().size
	map_offset = Vector2(vs.x * 0.5, vs.y * 0.5 + 50.0)

func _fit_hex_size() -> void:
	var vs := get_viewport_rect().size
	var margin := 60.0
	var avail_w := vs.x - margin * 2.0
	var avail_h := vs.y - margin * 2.0 - 90.0
	var by_w := avail_w / (3.0 * map_radius + 2.0)
	var by_h := avail_h / (sqrt(3.0) * (2.0 * map_radius + 1.0))
	hex_size = clampf(minf(HEX_SIZE_DEFAULT, minf(by_w, by_h)), 8.0, HEX_SIZE_DEFAULT)

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
	return cube_dist(cell, Vector2i.ZERO) <= map_radius

func all_cells() -> Array[Vector2i]:
	var arr: Array[Vector2i] = []
	for q in range(-map_radius, map_radius + 1):
		for r in range(-map_radius, map_radius + 1):
			var c := Vector2i(q, r)
			if in_bounds(c):
				arr.append(c)
	return arr

func _is_neighbor(a: Vector2i, b: Vector2i) -> bool:
	return NEIGHBORS.has(a - b)

func _is_edge(cell: Vector2i) -> bool:
	return cube_dist(cell, Vector2i.ZERO) == map_radius

# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), COL_BG)
	for cell in all_cells():
		draw_hex(hex_center(cell), hex_size - 1.2, _tile_color(cell))
	# 炮台攻击范围高亮
	for cell in all_cells():
		if not walls.has(cell) and not turret_positions.has(cell) and _in_any_turret_range(cell):
			draw_hex(hex_center(cell), hex_size - 1.2, Color(1.0, 0.35, 0.35, 0.16))
	# 可部署的最外围一圈提示（部署阶段）
	if mode == Mode.PLAY and phase == Phase.DEPLOY:
		for cell in all_cells():
			if _is_edge(cell) and not walls.has(cell) and not turret_positions.has(cell):
				draw_arc(hex_center(cell), hex_size * 0.55, 0.0, TAU, 24, Color(0.8, 1.0, 1.0, 0.30), 2.0)
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
	# 我方单位（核心，PlayerCore 场景实例）
	for cell in units:
		var n: PlayerCore = units[cell]
		var t: Dictionary = n.config
		var col := _core_color(t)
		var c := hex_center(cell)
		draw_circle(c, hex_size * 0.40, col)
		draw_arc(c, hex_size * 0.40, 0.0, TAU, 24, col.lightened(0.5), 2.0)
		# 持续时间环
		var frac := clampf(n.remaining / float(t["duration"]), 0.0, 1.0)
		draw_arc(c, hex_size * 0.52, -PI * 0.5, -PI * 0.5 + TAU * frac, 24, col.lightened(0.5), 3.0)
		# 定向模式核心：绘制方向箭头
		if n.mode() == "directional":
			var dirv: Vector2i = n.direction
			var dirpx := (hex_center(cell + dirv) - c).normalized()
			draw_line(c, c + dirpx * hex_size * 0.62, col.lightened(0.25), 3.0)
			draw_circle(c + dirpx * hex_size * 0.62, 3.0, col.lightened(0.25))
	# 定向部署待选方向的高亮
	if awaiting_direction:
		var pc := hex_center(pending_cell)
		draw_arc(pc, hex_size * 0.6, 0.0, TAU, 24, COL_UNIT_RING, 3.0)
		for d in NEIGHBORS:
			var n := pending_cell + d
			if in_bounds(n) and not walls.has(n) and not turret_positions.has(n):
				draw_arc(hex_center(n), hex_size * 0.3, 0.0, TAU, 16, Color(1.0, 1.0, 1.0, 0.35), 2.0)
	# 敌方炮台（可为多个）
	for p in turret_positions:
		var tc := hex_center(p)
		var t: EnemyTurret = turret_map.get(p)
		var alive := mode == Mode.EDIT or (t != null and t.alive)
		if alive:
			draw_circle(tc, hex_size * 0.52, COL_TURRET)
			draw_arc(tc, hex_size * 0.52, 0.0, TAU, 24, COL_TURRET_RING, 2.0)
			var dir := Vector2(0.0, -1.0) * hex_size * 0.82
			var perp := Vector2(hex_size * 0.22, 0.0)
			draw_colored_polygon(PackedVector2Array([tc + dir, tc + perp, tc - perp]), COL_TURRET)
			if phase == Phase.RUNNING and mode == Mode.PLAY and t != null:
				var afrac := t.charge_fraction()
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
	if cell == hover_cell and not turret_positions.has(cell) and not units.has(cell):
		if mode == Mode.EDIT:
			return COL_TILE_HOVER
		if phase == Phase.DEPLOY and _is_edge(cell):
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
		if event.keycode == KEY_TAB:
			_toggle_mode()
			return
	if console_open:
		return
	if mode == Mode.EDIT:
		_handle_editor_input(event)
		return
	if event is InputEventMouseMotion:
		hover_cell = pixel_to_hex(event.position)
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		var cell := pixel_to_hex(event.position)
		if phase == Phase.DEPLOY:
			if awaiting_direction:
				if event.button_index == MOUSE_BUTTON_LEFT:
					if _is_neighbor(cell, pending_cell):
						_finalize_directional(cell)
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					awaiting_direction = false
					_update_status()
					queue_redraw()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				_try_place(cell)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_try_remove(cell)
	elif event is InputEventKey and event.pressed:
		# 数字键选择核心类型（与右下角 UI 同步）
		for i in range(core_types.size()):
			if event.keycode == KEY_1 + i:
				_select_core(i)
				return
		if (event.keycode == KEY_SPACE or event.keycode == KEY_ENTER) and phase == Phase.DEPLOY:
			_start()

func _spawn_core(cell: Vector2i, type_idx: int, dir: Vector2i) -> void:
	var cfg: Dictionary = core_types[type_idx]
	var n: PlayerCore = CORE_SCENE.instantiate()
	n.setup(cell, type_idx, cfg, dir)
	core_container.add_child(n)
	units[cell] = n
	_pollute_with(cell, n.payload())

func _remove_core(cell: Vector2i) -> void:
	var n: PlayerCore = units.get(cell)
	if n != null:
		units.erase(cell)
		n.queue_free()

func _try_place(cell: Vector2i) -> void:
	if not in_bounds(cell):
		return
	if walls.has(cell):
		return
	if turret_positions.has(cell):
		return
	if not _is_edge(cell):
		_set_status("只能在最外围一圈部署单位")
		return
	if units.has(cell):
		return
	if units.size() >= max_units:
		_set_status("已达到最大部署数量（%d 个）" % max_units)
		return
	var t: Dictionary = core_types[selected_core]
	if _behavior_for_mode(str(t["mode"])).needs_direction():
		# 定向模式核心：先选地块，再选相邻方向
		awaiting_direction = true
		pending_cell = cell
		pending_type = selected_core
		_update_status()
		queue_redraw()
		return
	# 其余模式：立即放置
	_spawn_core(cell, selected_core, Vector2i.ZERO)
	_update_status()
	queue_redraw()

func _finalize_directional(dir_cell: Vector2i) -> void:
	var dir: Vector2i = dir_cell - pending_cell
	_spawn_core(pending_cell, pending_type, dir)
	awaiting_direction = false
	_update_status()
	queue_redraw()

func _try_remove(cell: Vector2i) -> void:
	if units.has(cell):
		_remove_core(cell)
		polluted.erase(cell)
		_update_status()
		queue_redraw()

func _start() -> void:
	if phase != Phase.DEPLOY:
		return
	if units.is_empty():
		_set_status("请至少部署一个单位")
		return
	phase = Phase.RUNNING
	mode_spread_timers.clear()
	awaiting_direction = false
	for t in turret_map.values():
		t.reset()
	start_button.disabled = true
	_update_status()
	queue_redraw()

func _reset() -> void:
	phase = Phase.DEPLOY
	units.clear()
	polluted.clear()
	if core_container != null and is_instance_valid(core_container):
		core_container.queue_free()
	core_container = Node2D.new()
	core_container.name = "PlayerCores"
	add_child(core_container)
	mode_spread_timers.clear()
	_rebuild_turrets()
	awaiting_direction = false
	start_button.disabled = (mode == Mode.EDIT)
	_update_status()
	queue_redraw()

# ---------------------------------------------------------------------------
# 地图编辑器
# ---------------------------------------------------------------------------
func _toggle_mode() -> void:
	_set_mode(Mode.EDIT if mode == Mode.PLAY else Mode.PLAY)

func _set_mode(m: int) -> void:
	mode = m
	_reset()
	editor_layer.visible = (mode == Mode.EDIT)
	core_selector_layer.visible = (mode == Mode.PLAY)
	if mode_button:
		mode_button.text = "编辑模式" if mode == Mode.PLAY else "游玩模式"
	_update_status()
	queue_redraw()

func _handle_editor_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hover_cell = pixel_to_hex(event.position)
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		var cell := pixel_to_hex(event.position)
		if not in_bounds(cell):
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			_editor_place(cell)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_editor_erase(cell)

func _editor_place(cell: Vector2i) -> void:
	if editor_brush == 0:  # 墙
		walls[cell] = true
		turret_positions.erase(cell)  # 墙与炮台不重叠
	else:  # 炮台
		walls.erase(cell)
		if not turret_positions.has(cell):
			turret_positions.append(cell)
	queue_redraw()

func _editor_erase(cell: Vector2i) -> void:
	walls.erase(cell)
	turret_positions.erase(cell)
	queue_redraw()

func _select_brush(i: int) -> void:
	editor_brush = i
	if wall_btn:
		wall_btn.button_pressed = (i == 0)
	if turret_btn:
		turret_btn.button_pressed = (i == 1)

func _change_radius(delta: int) -> void:
	map_radius = clampi(map_radius + delta, 1, 10)
	_prune_map()
	total_hexes = all_cells().size()
	_fit_hex_size()
	_recenter()
	if radius_label:
		radius_label.text = "半径 %d" % map_radius
	queue_redraw()

func _open_import_dialog() -> void:
	file_dialog_purpose = 0
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.current_dir = ProjectSettings.globalize_path("res://maps")
	file_dialog.popup_centered()

func _open_export_dialog() -> void:
	file_dialog_purpose = 1
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.current_dir = ProjectSettings.globalize_path("res://maps")
	file_dialog.popup_centered()

func _on_file_selected(path: String) -> void:
	if file_dialog_purpose == 0:
		_import_map(path)
	else:
		_export_map(path)

func _build_editor_ui() -> void:
	editor_layer = CanvasLayer.new()
	editor_layer.layer = 10
	editor_layer.visible = false
	add_child(editor_layer)

	var panel := PanelContainer.new()
	editor_layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	margin.add_child(hbox)

	var lbl := Label.new()
	lbl.text = "地图编辑："
	hbox.add_child(lbl)

	var group := ButtonGroup.new()
	wall_btn = Button.new()
	wall_btn.text = "墙"
	wall_btn.toggle_mode = true
	wall_btn.button_group = group
	wall_btn.button_pressed = true
	wall_btn.pressed.connect(_select_brush.bind(0))
	hbox.add_child(wall_btn)

	turret_btn = Button.new()
	turret_btn.text = "炮台"
	turret_btn.toggle_mode = true
	turret_btn.button_group = group
	turret_btn.pressed.connect(_select_brush.bind(1))
	hbox.add_child(turret_btn)

	hbox.add_child(VSeparator.new())

	var minus := Button.new()
	minus.text = "-"
	minus.pressed.connect(_change_radius.bind(-1))
	hbox.add_child(minus)

	radius_label = Label.new()
	radius_label.text = "半径 %d" % map_radius
	hbox.add_child(radius_label)

	var plus := Button.new()
	plus.text = "+"
	plus.pressed.connect(_change_radius.bind(1))
	hbox.add_child(plus)

	hbox.add_child(VSeparator.new())

	var import_btn := Button.new()
	import_btn.text = "导入 JSON"
	import_btn.pressed.connect(_open_import_dialog)
	hbox.add_child(import_btn)

	var export_btn := Button.new()
	export_btn.text = "导出 JSON"
	export_btn.pressed.connect(_open_export_dialog)
	hbox.add_child(export_btn)

	# 先添加子节点再设置锚点，确保按实际内容尺寸居中于顶部
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)

func _build_file_dialog() -> void:
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.json", "JSON 文件")
	file_dialog.file_selected.connect(_on_file_selected)
	add_child(file_dialog)

# ---------------------------------------------------------------------------
# 污染与扩散
# ---------------------------------------------------------------------------
# 污染统一放在 polluted：Vector2i -> {mode,dir}；各模式的扩散规则由 CoreMode 提供
func _pollute_with(cell: Vector2i, payload: Dictionary) -> void:
	polluted[cell] = payload

# 对一种模式的所有污染地块做一次扩散（行为规则来自 CoreMode，主脚本只做通用过滤）
func _spread_mode(mode_name: String, bm: CoreMode) -> void:
	var snapshot: Array = polluted.keys()
	var newly: Dictionary = {}
	for cell in snapshot:
		var pl: Dictionary = polluted[cell]
		if str(pl.get("mode", "")) != mode_name:
			continue
		for n: Vector2i in bm.spread_candidates(cell, pl):
			if in_bounds(n) and not polluted.has(n) and not walls.has(n) and not newly.has(n):
				newly[n] = pl
	for c in newly:
		_pollute_with(c, newly[c])

# 敌方攻击清除目标地块后 units 中对应核心已被 erase；此函数释放残留的场景实例
func _free_orphan_cores() -> void:
	if core_container == null or not is_instance_valid(core_container):
		return
	for child in core_container.get_children():
		if not units.has((child as PlayerCore).coord):
			child.queue_free()

func _check_turret_destruction() -> void:
	var destroyed := false
	for t in turret_map.values():
		if t.check_contamination(polluted):
			destroyed = true
	if destroyed and _alive_turret_count() == 0:
		phase = Phase.WON

# ---------------------------------------------------------------------------
# 敌方炮台（逻辑已下放至 EnemyTurret 场景节点；此处负责实例化与统计）
# ---------------------------------------------------------------------------
func _rebuild_turrets() -> void:
	if turret_container != null and is_instance_valid(turret_container):
		turret_container.queue_free()
	turret_container = Node2D.new()
	turret_container.name = "EnemyTurrets"
	add_child(turret_container)
	turret_map.clear()
	for p in turret_positions:
		var t: EnemyTurret = TURRET_SCENE.instantiate()
		t.setup(p, enemy_attack_interval)
		turret_container.add_child(t)
		turret_map[p] = t

func _alive_turret_count() -> int:
	var n := 0
	for t in turret_map.values():
		if t.alive:
			n += 1
	return n

func _in_any_turret_range(cell: Vector2i) -> bool:
	if mode == Mode.EDIT:
		for p in turret_positions:
			if cube_dist(cell, p) <= TURRET_ATTACK_RANGE:
				return true
	else:
		for t in turret_map.values():
			if t.alive and cube_dist(cell, t.coord) <= t.attack_range:
				return true
	return false
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

	# 教程窗口（标题 + 说明，可关闭）
	tutorial_box = VBoxContainer.new()
	vbox.add_child(tutorial_box)

	var title_row := HBoxContainer.new()
	tutorial_box.add_child(title_row)

	var title := Label.new()
	title.text = "六边形污染扩散"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	var close_tut := Button.new()
	close_tut.text = "关闭"
	close_tut.pressed.connect(_close_tutorial)
	title_row.add_child(close_tut)

	info_label = Label.new()
	info_label.text = "在右下角选择要部署的核心类型：\n· 扩散核心（径向）：污染身下地块，并每隔一段时间向周围所有相邻地块扩散。\n· 定向核心：部署后需点击相邻地块选择延伸方向，其污染的地块会沿该方向扩散。\n只能在地图最外围一圈部署单位；墙阻挡污染且不可部署；核心到期后其污染地块保留但不再扩散。\n每个敌方炮台每隔一段时间攻击，清除离自己最近的污染地块。\n污染到达所有敌方炮台所在地块则获胜；所有核心结束而仍有存活炮台则失败。\n按 R 打开控制台调整数值；按 Tab 切换编辑/游玩模式。"
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.custom_minimum_size = Vector2(460, 0)
	tutorial_box.add_child(info_label)

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

	mode_button = Button.new()
	mode_button.text = "编辑模式"
	mode_button.pressed.connect(_toggle_mode)
	hbox.add_child(mode_button)

func _build_core_selector() -> void:
	core_buttons.clear()
	core_selector_layer = CanvasLayer.new()
	core_selector_layer.layer = 10
	add_child(core_selector_layer)

	var panel := PanelContainer.new()
	core_selector_layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "选择核心类型"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var group := ButtonGroup.new()
	for i in range(core_types.size()):
		var t: Dictionary = core_types[i]
		var btn := Button.new()
		btn.text = t["name"]
		btn.toggle_mode = true
		btn.button_group = group
		btn.custom_minimum_size = Vector2(140, 0)
		btn.pressed.connect(_select_core.bind(i))
		core_buttons.append(btn)
		vbox.add_child(btn)
	core_buttons[selected_core].button_pressed = true

	# 先添加子节点再设置锚点，确保按实际内容尺寸定位到右下角
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)

func _select_core(i: int) -> void:
	if i < 0 or i >= core_types.size():
		return
	selected_core = i
	awaiting_direction = false
	for j in range(core_buttons.size()):
		core_buttons[j].button_pressed = (j == i)
	_update_status()
	queue_redraw()

func _close_tutorial() -> void:
	if tutorial_box:
		tutorial_box.visible = false

func _set_status(text: String) -> void:
	if status_label:
		status_label.text = text

func _update_status() -> void:
	if mode == Mode.EDIT:
		_set_status("编辑模式：左键放置（墙/炮台），右键擦除；工具栏可调半径、导入/导出 JSON")
		return
	match phase:
		Phase.DEPLOY:
			if awaiting_direction:
				_set_status("定向核心：请点击相邻地块选择延伸方向（右键取消）")
			else:
				var t: Dictionary = core_types[selected_core]
				_set_status("部署阶段：当前核心「%s」，剩余可部署 %d 个（只能部署在最外围一圈）" % [t["name"], max_units - units.size()])
		Phase.RUNNING:
			_set_status("扩散中…… 已污染 %d/%d | 存活核心 %d | 存活炮台 %d" % [polluted.size(), total_hexes, units.size(), _alive_turret_count()])
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

	# 敌方
	vbox.add_child(_section_label("—— 敌方 ——"))
	sb_enemy = _add_spin_row(vbox, "攻击间隔（秒）", 0.1, 30.0, 0.1, enemy_attack_interval, false)

	var hint := Label.new()
	hint.text = "核心的持续时间、扩散间隔、颜色等请在 cores.json 中修改。\n修改后点击“应用”生效；按 R 或 Esc 关闭。"
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
	enemy_attack_interval = sb_enemy.value
	for t in turret_map.values():
		t.attack_interval = enemy_attack_interval
	_update_status()
	queue_redraw()

func _console_defaults() -> void:
	max_units = MAX_UNITS_DEFAULT
	enemy_attack_interval = ENEMY_ATTACK_INTERVAL_DEFAULT
	for t in turret_map.values():
		t.attack_interval = enemy_attack_interval
	sb_units.value = max_units
	sb_enemy.value = enemy_attack_interval
	_update_status()
	queue_redraw()
