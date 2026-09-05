class_name HexTurrets
extends RefCounted

## 敌方炮台的实例化与统计 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：按 turret_positions 重建 EnemyTurret 场景实例（turret_map / turret_container）、
## 存活计数、以及“某地块是否在任一（存活）炮台攻击范围内”的范围高亮查询。
## 单个炮台的状态与攻击逻辑已封装在 EnemyTurret 节点内部，本模块只做装配与统计。

const TURRET_SCENE := preload("res://scenes/enemy_turret.tscn")

var game

func _init(g) -> void:
	game = g

## 依据 turret_positions 重建全部炮台实例
func rebuild() -> void:
	if game.turret_container != null and is_instance_valid(game.turret_container):
		game.turret_container.queue_free()
	game.turret_container = Node2D.new()
	game.turret_container.name = "EnemyTurrets"
	game.add_child(game.turret_container)
	game.turret_map.clear()
	for p in game.turret_positions:
		var t: EnemyTurret = TURRET_SCENE.instantiate()
		var type_name: String = str(game.turret_types.get(p, "basic"))
		t.setup(p, type_name, game.enemy_attack_interval)
		if game.turret_interval_overrides.has(type_name):
			t.attack_interval = float(game.turret_interval_overrides[type_name])
		game.turret_container.add_child(t)
		game.turret_map[p] = t

## 存活炮台数量
func alive_count() -> int:
	var n := 0
	for t in game.turret_map.values():
		if t.alive:
			n += 1
	return n

## 某地块是否落入任一（存活）炮台的攻击范围（用于范围高亮）
func in_any_range(cell: Vector2i) -> bool:
	if game.mode == game.Mode.EDIT:
		for p in game.turret_positions:
			if game.geometry.cube_dist(cell, p) <= game.TURRET_ATTACK_RANGE:
				return true
	else:
		for t in game.turret_map.values():
			if t.alive and game.geometry.cube_dist(cell, t.coord) <= t.attack_range:
				return true
	return false

## 返回覆盖该地块的炮台类型名（多个时返回先遍历到者）；无覆盖返回空字符串
func covering_type(cell: Vector2i) -> String:
	if game.mode == game.Mode.EDIT:
		for p in game.turret_positions:
			var type_name: String = str(game.turret_types.get(p, "basic"))
			var stats: Dictionary = EnemyTurret.enemy_def(type_name)
			if game.geometry.cube_dist(cell, p) <= int(stats["range"]):
				return type_name
	else:
		for t in game.turret_map.values():
			if t.alive and game.geometry.cube_dist(cell, t.coord) <= t.attack_range:
				return t.turret_type
	return ""
