class_name HexDeploy
extends RefCounted

## 交互 / 部署 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：核心的部署（spawn_core / try_place / finalize_directional）、移除（remove_core /
## try_remove）、开始扩散（start）、关卡复位（reset）。费用校验、定向模式的
## “先选地块再选相邻方向”流程、部署费用的扣减/返还都在此。

const CORE_SCENE := preload("res://scenes/player_core.tscn")

var game

# 变形之地专用随机源：与全局 randi()/randf() 隔离，确保每颗核心独立随机变身，
# 不受其他系统（地图、掉落、炮台等）消费全局随机流的影响。
var _swap_rng := RandomNumberGenerator.new()

func _init(g) -> void:
	game = g
	_swap_rng.randomize()

func spawn_core(cell: Vector2i, type_idx: int, dir: Vector2i, free: bool = false) -> void:
	# —— 特殊地块效果 ——
	var placed_idx := type_idx  # 玩家实际选择的类型（费用基准，变形不改变费用）
	var tile_kind := str(game.special_tiles.get(cell, ""))
	var kind_def: Dictionary = {}
	if tile_kind != "":
		kind_def = game.special_kind_defs.get(tile_kind, {})
	# 变形之地：部署阶段（DEPLOY）放到变形之地【不立即变形】——由 start() 在战斗开始后
	# 统一变形，避免“部署→看结果→重试”刷随机；战斗已开始（RUNNING）再部署到变形之地则立即变形。
	# 变形目标从【所有】核心类型中随机选取（不只已解锁），且变形本身不改变费用。
	if not kind_def.is_empty() and bool(kind_def.get("swap_random", false)) \
			and game.phase == game.Phase.RUNNING:
		var alt := _random_other_type_index(placed_idx)
		if alt >= 0:
			type_idx = alt
	var core_id: String = game.drop_effects.core_id_of_type(type_idx)
	var cost: int = game.drop_effects.deploy_cost(placed_idx)
	if not free:
		if game.deploy_points < cost:
			game.hud.set_status("部署费用不足：需要 %d 点，剩余 %d 点" % [cost, game.deploy_points])
			return
		game.deploy_points -= cost
	var src_cfg: Dictionary = game.core_types[type_idx]
	# 复制一份配置快照，避免「核心长寿」的生存时间修改污染共享的 core_types 数据
	var cfg: Dictionary = src_cfg.duplicate()
	cfg["duration"] = float(src_cfg.get("duration", 15.0)) * game.drop_effects.survival_multiplier(core_id)
	# 长寿之地：存活时间再延长
	if kind_def.has("duration_mult"):
		cfg["duration"] *= float(kind_def["duration_mult"])
	var n: PlayerCore = CORE_SCENE.instantiate()
	n.setup(cell, type_idx, cfg, dir, game.hex_size, game.map_offset)
	n.spawn_time = game.battle_time
	n.uid = game.next_core_uid
	game.next_core_uid += 1
	game.core_container.add_child(n)
	game.units[cell] = n
	game.core_spread_timers[cell] = 0.0  # 该核心扩散计时从零开始（每核心独立）
	var pl: Dictionary = n.payload()
	pl["origin_id"] = core_id
	pl["origin_spawn_time"] = n.spawn_time
	pl["hp"] = 1
	game.spread.pollute_with(cell, pl)
	game.drop_effects.on_core_deployed(n, cell)
	game.hud.update_cost_ui()
	if game.tutorial_gate == "deploy":
		game.guide.on_deployed()

func remove_core(cell: Vector2i) -> void:
	var n: PlayerCore = game.units.get(cell)
	if n != null:
		game.units.erase(cell)
		n.queue_free()

func try_place(cell: Vector2i) -> void:
	if not game.geometry.in_bounds(cell):
		return
	if game.selected_core < 0:
		game.hud.set_status("请先选择核心类型")
		return
	if game.walls.has(cell):
		return
	if game.turret_positions.has(cell):
		return
	if game.units.has(cell):
		return
	var t: Dictionary = game.core_types[game.selected_core]
	# 蓄力核心等可无视「最外圈」限制；其余核心仍限最外圈
	if not game.map_data.behavior_for_mode(str(t.get("mode", ""))).deploy_anywhere() \
			and not game.geometry.is_edge(cell):
		game.hud.set_status("只能在最外围一圈部署单位")
		return
	var cost: int = game.drop_effects.deploy_cost(game.selected_core)
	if game.deploy_points < cost:
		game.hud.set_status("部署费用不足：需要 %d 点，剩余 %d 点" % [cost, game.deploy_points])
		return
	if game.map_data.behavior_for_mode(str(t["mode"])).needs_direction():
		# 定向模式核心：先选地块，再选相邻方向
		game.awaiting_direction = true
		game.pending_cell = cell
		game.pending_type = game.selected_core
		game.hud.update_status()
		game.queue_redraw()
		return
	# 其余模式：立即放置
	spawn_core(cell, game.selected_core, Vector2i.ZERO)
	game.hud.update_status()
	game.queue_redraw()

func finalize_directional(dir_cell: Vector2i) -> void:
	var dir: Vector2i = dir_cell - game.pending_cell
	spawn_core(game.pending_cell, game.pending_type, dir)
	game.awaiting_direction = false
	game.hud.update_status()
	game.queue_redraw()

func try_remove(cell: Vector2i) -> void:
	if game.units.has(cell):
		var refund: int = game.drop_effects.deploy_cost((game.units[cell] as PlayerCore).type_index)
		remove_core(cell)
		game.polluted.erase(cell)
		game.deploy_points = mini(game.deploy_points + refund, PlayerCore.DEPLOY_COST_MAX)
		game.hud.update_cost_ui()
		game.hud.update_status()
		game.queue_redraw()

# ---------------------------------------------------------------------------
# 变形之地（random_swap）：战斗开始后变身
# ---------------------------------------------------------------------------
## 从【所有】核心类型（不只已解锁）里随机挑一个与 excluded 不同的类型；全同则返回 -1
## 使用模块自带的 _swap_rng（与全局 RNG 隔离），保证每个地块/每颗核心独立抽签
func _random_other_type_index(excluded: int) -> int:
	var others: Array = []
	for i in range(game.core_types.size()):
		if i != excluded:
			others.append(i)
	if others.is_empty():
		return -1
	return others[_swap_rng.randi_range(0, others.size() - 1)]

## 战斗开始：遍历 DEPLOY 阶段就位、坐在变形之地上的核心，逐一变身
## 返回 {"count": 变身数量, "types": 变身后产生的不同核心类型数}
func _transform_units_on_swap_tiles() -> Dictionary:
	var cells: Array = game.units.keys()
	var transformed := 0
	var seen_types := {}
	for cell in cells:
		if not game.units.has(cell):
			continue
		var n: PlayerCore = game.units[cell]
		var kid := str(game.special_tiles.get(cell, ""))
		if kid == "":
			continue
		var kd: Dictionary = game.special_kind_defs.get(kid, {})
		if not bool(kd.get("swap_random", false)):
			continue
		if _transform_unit(n):
			transformed += 1
			seen_types[str(n.type_index)] = true
	return {"count": transformed, "types": seen_types.size()}

## 把一颗已部署的核心原地变身成随机其他核心类型（费用不变、uid 不变）
func _transform_unit(n: PlayerCore) -> bool:
	var alt := _random_other_type_index(n.type_index)
	if alt < 0:
		return false
	var src_cfg: Dictionary = game.core_types[alt]
	var cfg: Dictionary = src_cfg.duplicate()
	var new_id := str(src_cfg.get("id", ""))
	cfg["duration"] = float(src_cfg.get("duration", 15.0)) * game.drop_effects.survival_multiplier(new_id)
	# 变身发生在战斗开始前：清掉旧身份留下的污染足迹（含部署类词条铺的相邻格），
	# 再按新类型重写本格载荷；uid 不变，后续 owner 归属仍有效。
	var old_uid := n.uid
	for c in game.polluted.keys():
		if int(game.polluted[c].get("owner", -1)) == old_uid:
			game.polluted.erase(c)
	var dir := Vector2i.ZERO
	var old_dir := n.direction
	if game.map_data.behavior_for_mode(str(cfg.get("mode", "radial"))).needs_direction():
		# 新类型也需要方向：原方向（若仍指向有效邻格）保留，否则随机挑一个有效方向
		if old_dir != Vector2i.ZERO and _direction_valid(n.coord, old_dir):
			dir = old_dir
		else:
			dir = _random_valid_direction(n.coord)
	n.type_index = alt
	n.config = cfg
	n.remaining = float(cfg.get("duration", 15.0))
	n.direction = dir
	n.spawn_time = 0.0
	var pl: Dictionary = n.payload()
	pl["origin_id"] = new_id
	pl["origin_spawn_time"] = n.spawn_time
	pl["hp"] = 1
	game.spread.pollute_with(n.coord, pl)
	n.queue_redraw()
	return true

## 指定方向是否指向有效（不越界、不穿墙）的相邻格
func _direction_valid(cell: Vector2i, dir: Vector2i) -> bool:
	var t: Vector2i = cell + dir
	return game.geometry.in_bounds(t) and not game.walls.has(t)

## 为定向类型随机挑一个“朝地图内/不越界不穿墙”的方向（与变形同源随机）
func _random_valid_direction(cell: Vector2i) -> Vector2i:
	var valid: Array = []
	for d in game.NEIGHBORS:
		var t: Vector2i = cell + d
		if game.geometry.in_bounds(t) and not game.walls.has(t):
			valid.append(d)
	if valid.is_empty():
		return Vector2i.ZERO
	return valid[_swap_rng.randi_range(0, valid.size() - 1)]

func start() -> void:
	if game.phase != game.Phase.DEPLOY:
		return
	# 变形之地：战斗开始瞬间（仍在 DEPLOY 阶段、尚未进入 RUNNING）把坐在变形之地上
	# 的核心统一变身成随机其他核心（从【所有】核心类型中选取，不只已解锁）。
	var swap_info: Dictionary = _transform_units_on_swap_tiles()
	var transformed := int(swap_info.get("count", 0))
	game.phase = game.Phase.RUNNING
	game.core_spread_timers.clear()
	game.mode_spread_timers.clear()
	game.awaiting_direction = false
	game.battle_time = 0.0
	game.drop_effects.on_battle_start()
	for t in game.turret_map.values():
		t.reset()
	if game.start_button != null:
		game.start_button.disabled = true
	game.hud.update_status()
	if transformed > 0:
		game.hud.set_status("变形之地：%d 颗核心变身成其他核心（产生 %d 种不同核心类型）" % [transformed, int(swap_info.get("types", 0))])
	game.queue_redraw()

func reset() -> void:
	game.phase = game.Phase.DEPLOY
	game.deploy_points = PlayerCore.DEPLOY_COST_START
	game.battle_time = 0.0
	game.lose_grace = 0.0
	game.units.clear()
	game.polluted.clear()
	game.special_tiles.clear()
	# 每场随机（测试布尔）：清空后按本局累计（special_pool）或一次性（special_once）重新铺格
	game.map_data.apply_special_layout_for_battle()
	if game.core_container != null and is_instance_valid(game.core_container):
		game.core_container.queue_free()
	game.core_container = Node2D.new()
	game.core_container.name = "PlayerCores"
	game.core_container.z_index = 10
	game.add_child(game.core_container)
	game.core_spread_timers.clear()
	game.mode_spread_timers.clear()
	game.turrets.rebuild()
	if game.items != null:
		game.items.on_round_reset()  # 每轮：清掉绑定在场实例上的道具临时效果
	game.awaiting_direction = false
	if game.start_button != null:
		game.start_button.disabled = (game.mode == game.Mode.EDIT)
	game.hud.update_cost_ui()
	game.hud.update_status()
	game.queue_redraw()
