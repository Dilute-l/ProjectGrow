class_name HexRewards
extends RefCounted

## 关卡通关奖励 —— 模块。
##
## 职责：每关胜利(WON)后提供战后掉落，并在玩家选择后应用。
## 解锁规则：本局(每次进入 hex_game = 一局)开始时，只解锁 cores.json 里
## 标记 unlocked_by_default 的核心（默认只有「定向核心」）。
##
## 【战后掉落结构】(build_drop_queue)
## 每场 WON 生成一串「掉落项」(queue)，逐项弹出让玩家 3 选 1：
##   - 第 1 项「必定掉落」（必定出现）：
##       首胜（本局第 1 次通关）必定是新单位；
##       之后每场：20% 稀有词条 / 40% 普通词条 / 40% 新单位；
##   - 第 2 项「概率掉落」：30% 概率出现，目前内容为特殊地块
##     （special_tiles.json 的种类，重复获得可叠加出现数量）。
## 每一项内部都是 3 选 1，且候选等概率出现。
##
## 词条稀有度（只影响战后掉落展示与归类，不改变词条效果）：
##   - 普通词条 = effects.json 里 category=="generic" 的四条
##     （蔓延加速 / 蔓延分支 / 地块坚韧 / 核心长寿）；
##   - 稀有词条 = 其余所有词条（当前为 category=="unique" 的七条）。
## 词条作用规则（沿用原有效果）：
##   - 稀有词条（专属/unique）：选中后需再选择一颗「已解锁核心」来承载，只作用于该核心；
##   - 普通词条（通用/generic）：无需选择，直接作用于全体（当前已解锁的核心）。
## 特殊地块作用规则（由 hex_game.special_auto_every_battle 决定）：
##   - 开启「每场随机」：本局每获得 1 次该地块，此后每场战斗随机出现 1 个该地块
##     （special_pool 累计，可重复选择叠加数量）；
##   - 关闭「每场随机」：一次性 —— 仅下一场战斗出现 1 个该地块（special_once）。
##
## 【掉落类型接口】每个候选是一个 Dictionary：
##   { "kind": <String>, "id": <String>, "title": <String>, "sub": <String>,
##     "color": <Color>, "desc": <String> }
## 应用时按 kind 在 _apply_option() 里分发。将来要加新的掉落类型，只需：
##   1) 在对应的候选池构建函数里加入该类候选；
##   2) 在 _apply_option() 里加一个对应分支。
## 内置 kind：
##   - "core"：解锁一种核心（加入 game.unlocked_core_ids，随后选择栏刷新）；
##   - "buff"：给核心授予词条（drop_effects.grant，尊重叠加上限）；
##   - "tile"：获得一种特殊地块（special_tiles.json 里的种类；按上面的开关规则生效）。

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
	game.special_pool.clear()
	game.special_once.clear()
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
# 战后掉落生成（必定掉落 + 概率掉落）
# ---------------------------------------------------------------------------
## 概率掉落的触发概率（30%）
const CHANCE_DROP_PROBABILITY := 0.30
## 必定掉落的类别概率（非首胜）：20% 稀有词条，40% 普通词条，余下 40% 新单位
const RARE_ROLL_CHANCE := 0.20
const NORMAL_ROLL_CHANCE := 0.40

## 本局已通关（生成过掉落）的次数；第 1 次通关必定是“新单位”
var _wins := 0

## 生成本次 WON 的整串掉落项；每个元素为：
##   { "kind": "core"/"buff"/"tile"（展示用）, "label": 展示文案,
##     "options": Array（≤OFFER_COUNT 张卡，等概率）}
func build_drop_queue() -> Array:
	_wins += 1
	var queue: Array = []
	# —— 必定掉落（总是出现）——
	var gk := _roll_guaranteed_kind()
	var gpool := _pool_for_kind(gk)
	if gpool.is_empty():
		for alt in ["core", "normal", "rare"]:
			if alt == gk:
				continue
			gpool = _pool_for_kind(alt)
			if not gpool.is_empty():
				gk = alt
				break
	queue.append(_make_queue_item(gk, gpool, true))
	# —— 概率掉落（30% 触发；目前内容 = 特殊地块）——
	if randf() < CHANCE_DROP_PROBABILITY:
		var cpool := _build_chance_pool()
		if not cpool.is_empty():
			queue.append(_make_queue_item("chance", cpool, false))
	return queue

## 必定掉落的类别（kind 记号）：首胜强制 core，其余按 20/40/40 掷
func _roll_guaranteed_kind() -> String:
	if _wins <= 1:
		return "core"
	var r := randf()
	if r < RARE_ROLL_CHANCE:
		return "rare"
	if r < RARE_ROLL_CHANCE + NORMAL_ROLL_CHANCE:
		return "normal"
	return "core"

## 取某个类别的候选池（均匀池，之后统一洗牌取 3）
func _pool_for_kind(kind: String) -> Array:
	match kind:
		"core":
			return _build_core_pool()
		"normal":
			return _build_buff_pool(false)
		"rare":
			return _build_buff_pool(true)
		"chance":
			return _build_chance_pool()
	return []

## 组装一个掉落项：洗牌 + 截取 ≤OFFER_COUNT 张卡
func _make_queue_item(kind: String, pool: Array, guaranteed: bool) -> Dictionary:
	var opts: Array = pool.duplicate()
	opts.shuffle()
	if opts.size() > OFFER_COUNT:
		opts = opts.slice(0, OFFER_COUNT)
	return {
		"kind": kind,
		"guaranteed": guaranteed,
		"label": _kind_label(kind),
		"options": opts,
	}

func _kind_label(kind: String) -> String:
	match kind:
		"core":
			return "新单位"
		"normal":
			return "普通词条"
		"rare":
			return "稀有词条"
		"chance":
			return "特殊地块"
	return kind

## 未解锁核心的候选
func _build_core_pool() -> Array:
	var out: Array = []
	for i in range(game.core_types.size()):
		if is_type_unlocked(i):
			continue
		out.append(_make_core_option(i))
	return out

## 词条候选：rare=true 稀有词条（非 generic），rare=false 普通词条（generic 四条）
func _build_buff_pool(rare: bool) -> Array:
	var out: Array = []
	for e in game.drop_effects.effect_defs():
		var is_rare := str(e.get("category", "")) != "generic"
		if is_rare != rare:
			continue
		if _buff_eligible(e):
			out.append(_make_buff_option(e, rare))
	return out

## 概率掉落候选池：目前只有特殊地块；以后新增内容往这里 append 即可
func _build_chance_pool() -> Array:
	var out: Array = []
	for kid in game.special_kind_defs.keys():
		out.append(_make_tile_option(str(kid)))
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

func _make_buff_option(e: Dictionary, rare: bool) -> Dictionary:
	# 稀有 = unique（专属）；普通 = generic（通用）
	return {
		"kind": "buff",
		"id": str(e.get("id", "")),
		"title": str(e.get("name", "词条")),
		"sub": ("稀有词条 · 专属" if rare else "普通词条 · 通用"),
		"color": Color("d8b4ff") if rare else Color("8ae29a"),
		"desc": str(e.get("desc", "")),
	}

func _make_tile_option(kind_id: String) -> Dictionary:
	var d: Dictionary = game.special_kind_defs.get(kind_id, {})
	var held := int(game.special_pool.get(kind_id, 0))
	return {
		"kind": "tile",
		"id": kind_id,
		"title": str(d.get("name", kind_id)),
		"sub": "特殊地块 · 每场 ×%d" % (held + 1) if game.special_auto_every_battle else "特殊地块 · 一次性（下一场）",
		"color": Color(str(d.get("color", "#9fb0cc"))),
		"desc": "%s（悬停地图可查看效果）。%s" % [
			str(d.get("desc", "")),
			"获得后本局每场随机出现 ×%d，可继续叠加。" % (held + 1) if game.special_auto_every_battle else "获得后仅下一场出现 1 个该地块（一次性）。",
		],
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
		"tile":
			grant_tile(str(opt.get("id", "")))
		_:
			push_warning("HexRewards: 未知掉落类型「%s」" % str(opt.get("kind", "")))

## 战后/控制台获得一张特殊地块卡：
##   - 开启每场随机（special_auto_every_battle）：计入 special_pool，本局每场随机出现；
##   - 关闭：计入 special_once，仅下一场出现（一次性）。
func grant_tile(kind_id: String) -> void:
	if not game.special_kind_defs.has(kind_id):
		game.hud.set_status("未知的特殊地块种类「%s」" % kind_id)
		game.hud.update_status()
		return
	var d: Dictionary = game.special_kind_defs[kind_id]
	var tname := str(d.get("name", kind_id))
	if game.special_auto_every_battle:
		game.special_pool[kind_id] = int(game.special_pool.get(kind_id, 0)) + 1
		game.hud.set_status("已获得特殊地块「%s」：之后每场随机出现 ×%d" % [tname, int(game.special_pool[kind_id])])
	else:
		game.special_once[kind_id] = int(game.special_once.get(kind_id, 0)) + 1
		game.hud.set_status("已获得特殊地块「%s」：仅下一场出现（一次性）" % tname)
	game.hud.update_status()

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
