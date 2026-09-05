class_name HexRewards
extends RefCounted

## 关卡通关奖励 —— 模块。
##
## 职责：每关胜利(WON)后提供 3 选 1 的掉落候选（offer），并在玩家选择后应用。
## 解锁规则：本局(每次进入 hex_game = 一局)开始时，只解锁 cores.json 里
## 标记 unlocked_by_default 的核心（默认只有「定向核心」）。
## 掉落类型规则：每场 WON 只出现【一种】类型的候选 ——
##   - 首胜（本局第 1 次通关）：必定是新核心选择；
##   - 之后每场：75% 概率为增强 BUFF，25% 概率为新核心。
## buff 与新核心不会在同一次掉落里混出。
## 词条作用规则：
##   - 专属(unique)词条：选中后需再选择一颗「已解锁核心」来承载，只作用于该核心；
##   - 通用(generic)词条：无需选择，直接作用于全体（当前已解锁的核心）。
##
## 【掉落类型接口】每个候选是一个 Dictionary：
##   { "kind": <String>, "id": <String>, "title": <String>, "sub": <String>,
##     "color": <Color>, "desc": <String> }
## 应用时按 kind 在 _apply_option() 里分发。将来要加新的掉落类型，只需：
##   1) 在 build_options() 里加入该类候选；
##   2) 在 _apply_option() 里加一个对应分支。
## 内置 kind：
##   - "core"：解锁一种核心（加入 game.unlocked_core_ids，随后选择栏刷新）；
##   - "buff"：给所有【已解锁】核心授予词条（drop_effects.grant，尊重叠加上限）。

var game

const OFFER_COUNT := 3

func _init(g) -> void:
	game = g

# ---------------------------------------------------------------------------
# 解锁集合（局内）
# ---------------------------------------------------------------------------
## 新一局开始：根据 cores.json 的 unlocked_by_default 重建解锁集合，并清零通关计数
func reset_run() -> void:
	game.unlocked_core_ids = game.map_data.default_unlocked_ids()
	_wins = 0

## type_idx 对应的核心是否已解锁
func is_type_unlocked(type_idx: int) -> bool:
	if type_idx < 0 or type_idx >= game.core_types.size():
		return false
	return game.unlocked_core_ids.has(str(game.core_types[type_idx].get("id", "")))

## 当前已解锁的核心 id 列表
func unlocked_ids() -> Array:
	return game.unlocked_core_ids

# ---------------------------------------------------------------------------
# 候选生成（掉落类型二选一：每场只出 buff 或核心中的一种）
# ---------------------------------------------------------------------------
## 掉落类型概率（非首胜）：75% 增强 BUFF，25% 新核心
const BUFF_ROLL_CHANCE := 0.75

## 本局已通关（生成过掉落）的次数；第 1 次通关必定是“新核心”选择
var _wins := 0

## 生成本次 WON 后的候选（同一批只含一种类型，3 选 1，不足则给现有全部）
func build_options() -> Array:
	_wins += 1
	var core_pool := _build_core_pool()
	var buff_pool := _build_buff_pool()
	# 首胜强制核心；否则按 75/25 掷类型
	var kind := "buff" if (_wins > 1 and randf() < BUFF_ROLL_CHANCE) else "core"
	var pool := buff_pool if kind == "buff" else core_pool
	# 所选类型没有可用候选时，兜底换另一种；都没有则为空（界面显示提示）
	if pool.is_empty():
		pool = core_pool if kind == "buff" else buff_pool
	if pool.is_empty():
		return []
	pool.shuffle()
	if pool.size() > OFFER_COUNT:
		pool = pool.slice(0, OFFER_COUNT)
	return pool

## 未解锁核心的候选
func _build_core_pool() -> Array:
	var out: Array = []
	for i in range(game.core_types.size()):
		if is_type_unlocked(i):
			continue
		out.append(_make_core_option(i))
	return out

## 还能叠加的 BUFF 词条候选
func _build_buff_pool() -> Array:
	var out: Array = []
	for e in game.drop_effects.effect_defs():
		if _buff_eligible(e):
			out.append(_make_buff_option(e))
	return out

func _make_core_option(type_idx: int) -> Dictionary:
	var t: Dictionary = game.core_types[type_idx]
	var mode_name := str(t.get("mode", ""))
	var bm = game.map_data.behavior_for_mode(mode_name)
	return {
		"kind": "core",
		"id": str(t.get("id", "")),
		"title": str(t.get("name", "核心")),
		"sub": "解锁 · 费用 %d · %s扩散" % [game.drop_effects.deploy_cost(type_idx), bm.display_name()],
		"color": game.map_data.core_color(t),
		"desc": "通关奖励：本局从此可部署「%s」。" % str(t.get("name", "核心")),
	}

func _make_buff_option(e: Dictionary) -> Dictionary:
	var cat := str(e.get("category", "generic"))
	return {
		"kind": "buff",
		"id": str(e.get("id", "")),
		"title": str(e.get("name", "词条")),
		"sub": "词条 · %s" % ("专属" if cat == "unique" else "通用"),
		"color": Color("d8b4ff") if cat == "unique" else Color("8ae29a"),
		"desc": str(e.get("desc", "")),
	}

## 该词条是否还能授予（只要对任一已解锁核心未到上限即可进入候选池）
func _buff_eligible(e: Dictionary) -> bool:
	var eid := str(e.get("id", ""))
	for i in range(game.core_types.size()):
		if not is_type_unlocked(i):
			continue
		var cid := str(game.core_types[i].get("id", ""))
		if game.drop_effects.stacks(cid, eid) < game.drop_effects.max_stacks(eid):
			return true
	return false

# ---------------------------------------------------------------------------
# 应用选择
# ---------------------------------------------------------------------------
func apply_option(opt: Dictionary) -> void:
	match str(opt.get("kind", "")):
		"core":
			_unlock_core(str(opt.get("id", "")))
		"buff":
			_grant_buff(str(opt.get("id", "")))
		_:
			push_warning("HexRewards: 未知掉落类型「%s」" % str(opt.get("kind", "")))

func _unlock_core(core_id: String) -> void:
	if game.unlocked_core_ids.has(core_id):
		return
	game.unlocked_core_ids.append(core_id)
	var name := _core_name_of_id(core_id)
	game.hud.refresh_core_unlocks()
	game.hud.set_status("已解锁核心「%s」" % name)
	game.hud.update_status()

func _grant_buff(effect_id: String) -> void:
	var e = game.drop_effects.find_effect(effect_id)
	var granted := 0
	for i in range(game.core_types.size()):
		if not is_type_unlocked(i):
			continue
		var before = game.drop_effects.stacks(str(game.core_types[i].get("id", "")), effect_id)
		game.drop_effects.grant(i, effect_id)
		if game.drop_effects.stacks(str(game.core_types[i].get("id", "")), effect_id) > before:
			granted += 1
	if granted > 0:
		game.hud.set_status("已获得词条「%s」（作用于全体）" % str(e.get("name", effect_id)))
		game.hud.update_status()
	else:
		game.hud.set_status("该词条已达上限，未生效")

## 该词条是否为「专属」类（专属词条需玩家再选择一颗核心来承载）
func is_unique_effect(effect_id: String) -> bool:
	var e = game.drop_effects.find_effect(effect_id)
	return not e.is_empty() and str(e.get("category", "")) == "unique"

## 专属词条：只作用于指定的一颗已解锁核心（type_idx），本次仅此一颗
func grant_unique_buff(effect_id: String, type_idx: int) -> void:
	if type_idx < 0 or type_idx >= game.core_types.size():
		return
	if not is_type_unlocked(type_idx):
		return
	var core_id := str(game.core_types[type_idx].get("id", ""))
	var before = game.drop_effects.stacks(core_id, effect_id)
	game.drop_effects.grant(type_idx, effect_id)
	var e = game.drop_effects.find_effect(effect_id)
	var core_name := str(game.core_types[type_idx].get("name", core_id))
	if game.drop_effects.stacks(core_id, effect_id) > before:
		game.hud.set_status("已获得词条「%s」（作用于：%s）" % [str(e.get("name", effect_id)), core_name])
		game.hud.update_status()
	else:
		game.hud.set_status("该词条已达上限，未生效")

func _core_name_of_id(core_id: String) -> String:
	for t in game.core_types:
		if str(t.get("id", "")) == core_id:
			return str(t.get("name", core_id))
	return core_id
