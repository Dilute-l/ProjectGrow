class_name HexSpread
extends RefCounted

## 污染与扩散 —— 从 scripts/hex_game.gd 拆分出来的模块。
## 职责：污染字典（polluted）的写入、扩散（按核心实例 owner 树驱动）、炮台损毁判定
## （胜利判定）、以及清理敌方攻击后残留的核心场景实例。扩散的具体形状/方向规则
## 由 CoreMode 提供，本模块只做统一的越界/墙/已污染过滤。
##
## 扩散语义（per-core）：每颗存活核心拥有独立计时（见 hex_game.core_spread_timers），
## 到点后调用 spread_core()，只蔓延「这颗核心自己的树」= polluted 中 owner==uid 的地块；
## 因此「蔓延加速 / 急速之地」等只作用于坐在该地块、被点选的那一颗核心。
## 无 owner 的旧式地块（历史遗留）沿用旧规则：随任意一颗同模式存活核心一并蔓延。

var game

func _init(g) -> void:
	game = g

## 污染统一放在 polluted：Vector2i -> {mode,dir}
func pollute_with(cell: Vector2i, payload: Dictionary) -> void:
	game.polluted[cell] = payload

## 对一颗核心（owner_uid）自己的污染树做一次扩散（行为规则来自 CoreMode）。
## 遍历其树内各地块：owner==owner_uid 的向外扩一步。新产生的污染全部带 owner；
## 历史遗留的无 owner 地块视为无主，冻结不再外扩（与“核心失效即冻结”同语义）。
func spread_core(owner_uid: int, mode_name: String, bm: CoreMode) -> void:
	var snapshot: Array = game.polluted.keys()
	var newly: Dictionary = {}
	for cell in snapshot:
		var pl: Dictionary = game.polluted[cell]
		if str(pl.get("mode", "")) != mode_name:
			continue
		var owner := int(pl.get("owner", -1))
		if owner != owner_uid:
			continue  # 只扩这颗核心自己的树；无主历史地块冻结
		for n: Vector2i in bm.spread_candidates(cell, pl):
			if game.geometry.in_bounds(n) and not game.polluted.has(n) and not game.walls.has(n) and not newly.has(n):
				var np: Dictionary = pl.duplicate()
				# 无方向模式（径向等）：补上触手方向 = 从来源核心指向该地块，映射到最近邻域
				var ndir: Vector2i = np.get("dir", Vector2i.ZERO)
				if ndir == Vector2i.ZERO:
					var src: Vector2i = np.get("source", cell)
					np["dir"] = game.geometry.nearest_dir(n - src)
				# 每个蔓延生成的地块单独掷「地块坚韧」耐久
				np["hp"] = game.drop_effects.roll_tile_hp(str(np.get("origin_id", "")))
				newly[n] = np
	for c in newly:
		pollute_with(c, newly[c])
	# 蔓延分支：结算后按概率额外随机蔓延一格（按该 owner 树判定）
	game.drop_effects.extra_spread_owner(mode_name, owner_uid)

## 该地块是否仍可扩散：带 owner 的必须是场上仍存活的对应核心；
## 无 owner 的旧式地块沿用旧规则（该模式有存活核心即可）
func _owner_active(pl: Dictionary, mode_name: String) -> bool:
	var owner := int(pl.get("owner", -1))
	if owner < 0:
		return _any_alive_of_mode(mode_name)
	for n in game.units.values():
		if int(n.uid) == owner:
			return true
	return false

func _any_alive_of_mode(mode_name: String) -> bool:
	for n in game.units.values():
		if n.mode() == mode_name:
			return true
	return false

## 核心到期爆发：一次性向候选格写入污染（蓄力类核心到期时调用）。
## 爆发地块也带 owner（= 即将失效的核心 uid），因此爆发后即静止、不再外扩。
func burst_from(origin: Vector2i, candidates: Array, mode_name: String, origin_id: String = "", origin_spawn_time: float = 0.0) -> void:
	var owner := -1
	var on = game.units.get(origin)
	if on != null:
		owner = int(on.uid)
	var newly: Dictionary = {}
	for n: Vector2i in candidates:
		if game.geometry.in_bounds(n) and not game.polluted.has(n) and not game.walls.has(n) and not newly.has(n):
			newly[n] = {
				"mode": mode_name,
				"dir": game.geometry.nearest_dir(n - origin),
				"source": origin,
				"origin_id": origin_id,
				"origin_spawn_time": origin_spawn_time,
				"owner": owner,
				"hp": game.drop_effects.roll_tile_hp(origin_id),
			}
	for c in newly:
		pollute_with(c, newly[c])

## 敌方攻击清除目标地块后，units 中对应核心已被 erase；此函数释放残留的场景实例。
## 核心耗尽后的「变暗尸体」节点（polluted 仍含其格）保留，直到其污染被清除。
func free_orphan_cores() -> void:
	if game.core_container == null or not is_instance_valid(game.core_container):
		return
	for child in game.core_container.get_children():
		var pc := child as PlayerCore
		if not game.units.has(pc.coord) and not game.polluted.has(pc.coord):
			child.queue_free()

## 蔓延结算后逐炮台判定污染损毁；全部损毁 => 胜利
func check_turret_destruction() -> void:
	var destroyed := false
	for t in game.turret_map.values():
		if t.check_contamination(game.polluted):
			destroyed = true
	if destroyed and game.turrets.alive_count() == 0:
		game.phase = game.Phase.WON
