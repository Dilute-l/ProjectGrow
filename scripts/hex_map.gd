class_name HexMap
extends RefCounted

## 数据加载与地图序列化 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：读取/解析 level1.json（地图：半径、墙、炮台）与 cores.json（核心类型），
## 地图的导出/导入，以及核心行为模式的注册与费用查询。
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
	if FileAccess.file_exists(game.MAP_PATH):
		var f := FileAccess.open(game.MAP_PATH, FileAccess.READ)
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
	var t = data.get("turrets", null)
	if t is Array:
		for entry in t:
			if entry is Dictionary:
				game.turret_positions.append(Vector2i(int(entry.get("q", 0)), int(entry.get("r", 0))))
	else:
		var single = data.get("turret", null)
		if single is Dictionary:
			game.turret_positions.append(Vector2i(int(single.get("q", 0)), int(single.get("r", 0))))
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
	game.turret_positions = valid

# ---------------------------------------------------------------------------
# 地图序列化
# ---------------------------------------------------------------------------
func map_to_dict() -> Dictionary:
	var turrets_arr: Array = []
	for p in game.turret_positions:
		turrets_arr.append({"q": p.x, "r": p.y})
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
								"color": str(entry.get("color", "#3fc1ff")),
							})
	if game.core_types.is_empty():
		game.core_types.append({"id": "spread", "name": "扩散核心", "mode": "radial", "duration": 15.0, "spread_interval": 0.9, "color": "#3fc1ff"})
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

## 取模式行为；未注册的模式按径向兜底并告警
func behavior_for_mode(mode_name: String) -> CoreMode:
	var b := CoreMode.for_mode(mode_name)
	if b == null:
		push_warning("未注册的核心模式「%s」，按径向处理" % mode_name)
		b = CoreMode.for_mode("radial")
	return b

## 部署该模式一颗核心的费用：读取对应 CoreMode 子类里的 DEPLOY_COST 常量
func mode_deploy_cost(mode_name: String) -> int:
	var bm := behavior_for_mode(mode_name)
	var cm: Dictionary = bm.get_script().get_script_constant_map()
	if cm.has("DEPLOY_COST"):
		return int(cm["DEPLOY_COST"])
	push_warning("模式「%s」未定义 DEPLOY_COST，按 1 计" % mode_name)
	return 1
