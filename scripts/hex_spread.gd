class_name HexSpread
extends RefCounted

## 污染与扩散 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：污染字典（polluted）的写入、按模式驱动的扩散、炮台损毁判定（胜利判定）、
## 以及清理敌方攻击后残留的核心场景实例。扩散的具体形状/方向规则由 CoreMode 提供，
## 本模块只做统一的越界/墙/已污染过滤。

var game

func _init(g) -> void:
	game = g

## 污染统一放在 polluted：Vector2i -> {mode,dir}
func pollute_with(cell: Vector2i, payload: Dictionary) -> void:
	game.polluted[cell] = payload

## 对一种模式的所有污染地块做一次扩散（行为规则来自 CoreMode，这里只做通用过滤）
func spread_mode(mode_name: String, bm: CoreMode) -> void:
	var snapshot: Array = game.polluted.keys()
	var newly: Dictionary = {}
	for cell in snapshot:
		var pl: Dictionary = game.polluted[cell]
		if str(pl.get("mode", "")) != mode_name:
			continue
		for n: Vector2i in bm.spread_candidates(cell, pl):
			if game.geometry.in_bounds(n) and not game.polluted.has(n) and not game.walls.has(n) and not newly.has(n):
				newly[n] = pl
	for c in newly:
		pollute_with(c, newly[c])

## 核心到期爆发：一次性向候选格写入污染（蓄力类核心到期时调用）
func burst_from(origin: Vector2i, candidates: Array, mode_name: String) -> void:
	var newly: Dictionary = {}
	for n: Vector2i in candidates:
		if game.geometry.in_bounds(n) and not game.polluted.has(n) and not game.walls.has(n) and not newly.has(n):
			newly[n] = {"mode": mode_name, "dir": Vector2i.ZERO, "source": origin}
	for c in newly:
		pollute_with(c, newly[c])

## 敌方攻击清除目标地块后，units 中对应核心已被 erase；此函数释放残留的场景实例
func free_orphan_cores() -> void:
	if game.core_container == null or not is_instance_valid(game.core_container):
		return
	for child in game.core_container.get_children():
		if not game.units.has((child as PlayerCore).coord):
			child.queue_free()

## 蔓延结算后逐炮台判定污染损毁；全部损毁 => 胜利
func check_turret_destruction() -> void:
	var destroyed := false
	for t in game.turret_map.values():
		if t.check_contamination(game.polluted):
			destroyed = true
	if destroyed and game.turrets.alive_count() == 0:
		game.phase = game.Phase.WON
