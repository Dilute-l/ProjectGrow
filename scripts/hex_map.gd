class_name HexMap
extends RefCounted

## 数据加载与地图序列化 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：读取/解析 level1.json（地图：半径、墙、炮台）与 cores.json（核心类型），
## 地图的导出/导入，以及核心行为模式的注册。
## 内存状态（map_radius / walls / turret_positions / core_types / mode_intervals）
## 仍由主脚本持有，本模块只负责读写这些字段。

var game

func _init(g) -> void:
	game = g

# ---------------------------------------------------------------------------
# 地图加载
# ---------------------------------------------------------------------------
func load_map() -> void:
	var loaded := false
	if FileAccess.file_exists(game.LEVEL_PATHS[game.level_index]):
		var f := FileAccess.open(game.LEVEL_PATHS[game.level_index], FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				apply_map_data(data)
				loaded = true
	if not loaded:
		apply_map_data({"radius": 5})
	if game.turret_positions.is_empty():
		game.turret_positions.append(Vector2i.ZERO)
	game.total_hexes = game.geometry.all_cells().size()

func apply_map_data(data: Dictionary) -> void:
	game.map_radius = int(data.get("radius", 5))
	if game.map_radius < 1:
		game.map_radius = 5
	game.walls.clear()
	game.turret_positions.clear()
	game.turret_types.clear()
	var t = data.get("turrets", null)
	if t is Array:
		for entry in t:
			if entry is Dictionary:
				var pos := Vector2i(int(entry.get("q", 0)), int(entry.get("r", 0)))
				game.turret_positions.append(pos)
				game.turret_types[pos] = str(entry.get("type", "basic"))
	else:
		var single = data.get("turret", null)
		if single is Dictionary:
			var pos := Vector2i(int(single.get("q", 0)), int(single.get("r", 0)))
			game.turret_positions.append(pos)
			game.turret_types[pos] = str(single.get("type", "basic"))
	var w = data.get("walls", [])
	if w is Array:
		for entry in w:
			if entry is Dictionary:
				game.walls[Vector2i(int(entry.get("q", 0)), int(entry.get("r", 0)))] = true
	prune_map()

## 去掉越界的墙与炮台，以及落在墙上的炮台
func prune_map() -> void:
	for cell in game.walls.keys():
		if not game.geometry.in_bounds(cell):
			game.walls.erase(cell)
	var valid: Array[Vector2i] = []
	for p in game.turret_positions:
		if game.geometry.in_bounds(p) and not game.walls.has(p):
			valid.append(p)
		else:
			game.turret_types.erase(p)
	game.turret_positions = valid

# ---------------------------------------------------------------------------
# 地图序列化
# ---------------------------------------------------------------------------
func map_to_dict() -> Dictionary:
	var turrets_arr: Array = []
	for p in game.turret_positions:
		turrets_arr.append({"q": p.x, "r": p.y, "type": str(game.turret_types.get(p, "basic"))})
	var walls_arr: Array = []
	for cell in game.walls:
		walls_arr.append({"q": cell.x, "r": cell.y})
	return {"radius": game.map_radius, "turrets": turrets_arr, "walls": walls_arr}

func export_map(path: String) -> void:
	if not path.ends_with(".json"):
		path += ".json"
	var text := JSON.stringify(map_to_dict(), "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		game.hud.set_status("已导出地图：" + path)
	else:
		game.hud.set_status("导出失败：无法写入 " + path)

func import_map(path: String) -> void:
	if not FileAccess.file_exists(path):
		game.hud.set_status("导入失败：文件不存在 " + path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		game.hud.set_status("导入失败：无法读取 " + path)
		return
	var text := f.get_as_text()
	f.close()
	var data = JSON.parse_string(text)
	if data is Dictionary:
		apply_map_data(data)
		game.total_hexes = game.geometry.all_cells().size()
		game.geometry.fit_hex_size()
		game.geometry.recenter()
		game.deploy.reset()
		if game.radius_label:
			game.radius_label.text = "半径 %d" % game.map_radius
		game.hud.set_status("已导入地图：" + path)
	else:
		game.hud.set_status("导入失败：JSON 格式错误")
	game.queue_redraw()

# ---------------------------------------------------------------------------
# 核心类型加载与行为模式
# ---------------------------------------------------------------------------
func load_cores() -> void:
	game.core_types.clear()
	if FileAccess.file_exists(game.CORES_PATH):
		var f := FileAccess.open(game.CORES_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				var arr = data.get("cores", [])
				if arr is Array:
					for entry in arr:
						if entry is Dictionary:
							game.core_types.append({
								"id": str(entry.get("id", "core")),
								"name": str(entry.get("name", "核心")),
								"mode": str(entry.get("mode", "radial")),
								"duration": float(entry.get("duration", 15.0)),
								"spread_interval": float(entry.get("spread_interval", 0.9)),
								"cost": int(entry.get("cost", 1)),
								"color": str(entry.get("color", "#3fc1ff")),
								"unlocked_by_default": bool(entry.get("unlocked_by_default", false)),
							})
	if game.core_types.is_empty():
		game.core_types.append({"id": "spread", "name": "扩散核心", "mode": "radial", "duration": 15.0, "spread_interval": 0.9, "cost": 2, "color": "#3fc1ff"})
	game.mode_intervals.clear()
	for t in game.core_types:
		game.mode_intervals[str(t["mode"])] = float(t["spread_interval"])

func core_color(t: Dictionary) -> Color:
	var hex := str(t.get("color", ""))
	if hex == "":
		return game.COL_UNIT
	return Color(hex)

## 注册内置核心行为模式；新增「新模式」只需：cores.json 条目 + CoreMode 子类 + 此处一行注册
func register_core_modes() -> void:
	CoreMode.register("radial", RadialCoreMode.new())
	CoreMode.register("directional", DirectionalCoreMode.new())
	CoreMode.register("charge", ChargeCoreMode.new())
	CoreMode.register("speedy", SpeedyCoreMode.new())

## 取模式行为；未注册的模式按径向兜底并告警
func behavior_for_mode(mode_name: String) -> CoreMode:
	var b := CoreMode.for_mode(mode_name)
	if b == null:
		push_warning("未注册的核心模式「%s」，按径向处理" % mode_name)
		b = CoreMode.for_mode("radial")
	return b

## 新一局默认解锁的核心 id：取 cores.json 里 unlocked_by_default=true 的条目；
## 若一条都没有，回退为「定向模式的核心」（再退为首个核心），避免开不了局。
func default_unlocked_ids() -> Array:
	var out: Array = []
	for t in game.core_types:
		if bool(t.get("unlocked_by_default", false)):
			out.append(str(t.get("id", "")))
	if not out.is_empty():
		return out
	for t in game.core_types:
		if str(t.get("mode", "")) == "directional":
			return [str(t.get("id", "directional"))]
	if not game.core_types.is_empty():
		return [str(game.core_types[0].get("id", "core"))]
	return []

# ---------------------------------------------------------------------------
# 特殊地块库（maps/special_tiles.json）
# ---------------------------------------------------------------------------
const SPECIAL_TILES_PATH := "res://maps/special_tiles.json"

## 文件缺失 / 损坏时的兜底（应与 special_tiles.json 内容一致）
const SPECIAL_TILES_FALLBACK: Array = [
	{"id": "fast_spread", "name": "急速之地", "color": "#5cd8ff",
	 "desc": "核心部署于此地块时，蔓延时间间隔 -50%", "spread_mult": 0.5},
	{"id": "long_life", "name": "长寿之地", "color": "#8ae29a",
	 "desc": "核心部署于此地块时，存活时间延长 50%", "duration_mult": 1.5},
	{"id": "random_swap", "name": "变形之地", "color": "#ff9a5c",
	 "desc": "核心部署于此地块时，战斗开始后变身为随机其他核心（从所有核心类型中选取）", "swap_random": true},
]

## 加载特殊地块种类定义（写入 game.special_kind_defs）
func load_special_tiles() -> void:
	game.special_kind_defs.clear()
	if FileAccess.file_exists(SPECIAL_TILES_PATH):
		var f := FileAccess.open(SPECIAL_TILES_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary and data.get("special_tiles") is Array:
				for entry in data["special_tiles"]:
					if entry is Dictionary:
						var id := str(entry.get("id", ""))
						if id != "":
							game.special_kind_defs[id] = entry.duplicate()
	if game.special_kind_defs.is_empty():
		push_warning("HexMap: 特殊地块库 %s 缺失或为空，使用内置兜底" % SPECIAL_TILES_PATH)
		for e in SPECIAL_TILES_FALLBACK:
			game.special_kind_defs[str(e["id"])] = e.duplicate()

## 随机取一个当前“可部署地块”（最外圈、非墙、非炮台、未被单位占用、未被指定为其他特殊地块）
func random_deployable_cell() -> Vector2i:
	var cells: Array[Vector2i] = []
	for c in game.geometry.all_cells():
		if game.geometry.is_edge(c) and not game.walls.has(c) \
				and not game.turret_positions.has(c) and not game.units.has(c) \
				and not game.special_tiles.has(c):
			cells.append(c)
	if cells.is_empty():
		return Vector2i(999999, 999999)
	return cells[randi() % cells.size()]

## 指定：把“随机一个可部署地块”标为 kind_id 特殊地块（可多次调用以叠加多个）
func designate_special_tile(kind_id: String) -> bool:
	if not game.special_kind_defs.has(kind_id):
		return false
	var cell := random_deployable_cell()
	if cell.x == 999999:
		game.hud.set_status("没有可用于指定特殊地块的可部署地块")
		return false
	game.special_tiles[cell] = kind_id
	game.hud.set_status("已将地块 %s 指定为「%s」（悬停可查看效果）" % [str(cell), str(game.special_kind_defs[kind_id].get("name", kind_id))])
	game.queue_redraw()
	return true

# ---------------------------------------------------------------------------
# 每场随机（测试布尔）：把本局累计的特殊地块按次数随机铺到可部署地块
# ---------------------------------------------------------------------------
## 开启 special_auto_every_battle：每场战斗开始前，把 special_pool 里每种地块
## 按累计次数随机铺到可部署格（随机种子每场重掷）。关闭时：把 special_once 里的
## 一次性地块铺一次后清空（战后获得 = 仅下一场生效）。
## 由 deploy.reset() 在清空 special_tiles 后调用。返回实际铺设的格数。
func apply_special_layout_for_battle() -> int:
	var total := 0
	if game.special_auto_every_battle:
		for kid in game.special_pool.keys():
			total += _designate_random_cells(str(kid), int(game.special_pool[kid]))
	else:
		for kid in game.special_once.keys():
			total += _designate_random_cells(str(kid), int(game.special_once[kid]))
		game.special_once.clear()
	return total

## 把 kind_id 随机铺 count 个可部署格（彼此不重复、不与已有特殊地块重叠）；返回铺设数
func _designate_random_cells(kind_id: String, count: int) -> int:
	if count <= 0 or not game.special_kind_defs.has(kind_id):
		return 0
	var placed := 0
	var guard := 0
	while placed < count and guard < 200:
		guard += 1
		var cell := random_deployable_cell()
		if cell.x == 999999:
			break
		game.special_tiles[cell] = kind_id
		placed += 1
	return placed
