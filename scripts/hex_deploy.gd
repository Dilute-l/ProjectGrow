class_name HexDeploy
extends RefCounted

## 交互 / 部署 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：核心的部署（spawn_core / try_place / finalize_directional）、移除（remove_core /
## try_remove）、开始扩散（start）、关卡复位（reset）。费用校验、定向模式的
## “先选地块再选相邻方向”流程、部署费用的扣减/返还都在此。

const CORE_SCENE := preload("res://scenes/player_core.tscn")

var game

func _init(g) -> void:
	game = g

func spawn_core(cell: Vector2i, type_idx: int, dir: Vector2i, free: bool = false) -> void:
	var core_id: String = game.drop_effects.core_id_of_type(type_idx)
	var cost: int = game.drop_effects.deploy_cost(type_idx)
	if not free:
		if game.deploy_points < cost:
			game.hud.set_status("部署费用不足：需要 %d 点，剩余 %d 点" % [cost, game.deploy_points])
			return
		game.deploy_points -= cost
	var src_cfg: Dictionary = game.core_types[type_idx]
	# 复制一份配置快照，避免「核心长寿」的生存时间修改污染共享的 core_types 数据
	var cfg: Dictionary = src_cfg.duplicate()
	cfg["duration"] = float(src_cfg.get("duration", 15.0)) * game.drop_effects.survival_multiplier(core_id)
	var n: PlayerCore = CORE_SCENE.instantiate()
	n.setup(cell, type_idx, cfg, dir, game.hex_size, game.map_offset)
	n.spawn_time = game.battle_time
	n.uid = game.next_core_uid
	game.next_core_uid += 1
	game.core_container.add_child(n)
	game.units[cell] = n
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
	if not game.geometry.is_edge(cell):
		game.hud.set_status("只能在最外围一圈部署单位")
		return
	if game.units.has(cell):
		return
	var t: Dictionary = game.core_types[game.selected_core]
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

func start() -> void:
	if game.phase != game.Phase.DEPLOY:
		return
	if game.units.is_empty():
		game.hud.set_status("请至少部署一个单位")
		return
	game.phase = game.Phase.RUNNING
	game.mode_spread_timers.clear()
	game.awaiting_direction = false
	game.battle_time = 0.0
	game.drop_effects.on_battle_start()
	for t in game.turret_map.values():
		t.reset()
	game.start_button.disabled = true
	game.hud.update_status()
	game.queue_redraw()

func reset() -> void:
	game.phase = game.Phase.DEPLOY
	game.deploy_points = PlayerCore.DEPLOY_COST_START
	game.battle_time = 0.0
	game.units.clear()
	game.polluted.clear()
	if game.core_container != null and is_instance_valid(game.core_container):
		game.core_container.queue_free()
	game.core_container = Node2D.new()
	game.core_container.name = "PlayerCores"
	game.add_child(game.core_container)
	game.mode_spread_timers.clear()
	game.turrets.rebuild()
	game.awaiting_direction = false
	game.start_button.disabled = (game.mode == game.Mode.EDIT)
	game.hud.update_cost_ui()
	game.hud.update_status()
	game.queue_redraw()
