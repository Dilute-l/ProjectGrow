class_name DropEffects
extends RefCounted

## 掉落效果 —— 新增模块。
##
## 职责：定义「掉落效果」（以某种触手为核心的强化词条）的数据表与运行时叠加状态，
## 并在部署 / 蔓延 / 清除 / 战斗开始等关键节点提供钩子，供其它模块调用。
## 效果不提供任何掉落 / 奖励获取途径，只能在按 R 打开的控制台里授予
## （见 add_console_section()）。
##
## 词条分两类：
##   - unique（专属）：一种触手每种词条最多 1 层；
##   - generic（通用）：一种触手每种词条最多 5 层，多次叠加按乘算
##     （间隔 0.9^n、概率 1-0.9^n、生存 1.2^n）。
##
## 概念映射（游戏内部命名）：
##   - 触手     = 核心类型（core_types 里的一条，用其 id 标识）；
##   - 触手地块 = 被污染地块（polluted 里的一个键，载荷含
##                origin_id / origin_spawn_time / hp）；
##   - 核心     = 我方部署单位（PlayerCore 实例）。

# ---------------------------------------------------------------------------
# 效果定义表（仅作记录 / 控制台展示；实际逻辑见下方钩子）
# ---------------------------------------------------------------------------
const MAX_GENERIC_STACKS := 5

const EFFECTS: Array = [
	{"id": "battle_extra_core", "category": "unique", "name": "开局增援",
	 "desc": "战斗开始时，在可部署区域随机额外生成一个该核心"},
	{"id": "deploy_surround", "category": "unique", "name": "落地蔓延",
	 "desc": "部署时立刻在周围六格内生成触手地块"},
	{"id": "deploy_shield_10s", "category": "unique", "name": "初生庇护",
	 "desc": "部署后的前10秒内，其生成的地块无法被清除"},
	{"id": "deploy_haste_5s", "category": "unique", "name": "初生急速",
	 "desc": "部署后的前5秒内，蔓延间隔 -50%"},
	{"id": "deploy_gain_cost", "category": "unique", "name": "部署返费",
	 "desc": "部署时获得 5 点费用"},
	{"id": "clear_stun_enemy", "category": "unique", "name": "清算反噬",
	 "desc": "其地块被清除时，使清除者停止攻击 1 秒"},
	{"id": "cost_swap_aura", "category": "unique", "name": "贵胄光环",
	 "desc": "部署费用 +5；在场时其他所有触手部署费用 -2"},
	{"id": "spread_interval_down", "category": "generic", "name": "蔓延加速",
	 "desc": "蔓延时间间隔 -10%（乘算，最多 5 层）"},
	{"id": "spread_extra_tile", "category": "generic", "name": "蔓延分支",
	 "desc": "蔓延时 10% 概率额外随机蔓延一格（乘算，最多 5 层）"},
	{"id": "tile_toughness", "category": "generic", "name": "地块坚韧",
	 "desc": "蔓延生成的地块 10% 概率可承受两次清理（乘算，最多 5 层）"},
	{"id": "core_longevity", "category": "generic", "name": "核心长寿",
	 "desc": "核心生存时间 +20%（乘算，最多 5 层）"},
]

var game

# 运行时叠加状态：core_id(String) -> { effect_id(String) -> 层数(int) }
var grants: Dictionary = {}

# 控制台授予 UI 控件
var grant_core_option: OptionButton
var grant_effect_option: OptionButton
var grant_list_label: Label

func _init(g) -> void:
	game = g

# ---------------------------------------------------------------------------
# 效果定义查询
# ---------------------------------------------------------------------------
static func effect_defs() -> Array:
	return EFFECTS

static func find_effect(effect_id: String) -> Dictionary:
	for e in EFFECTS:
		if str(e["id"]) == effect_id:
			return e
	return {}

## 该词条可叠加层数：generic 5 层，unique 1 层
func max_stacks(effect_id: String) -> int:
	var e := find_effect(effect_id)
	if e.is_empty():
		return 0
	return MAX_GENERIC_STACKS if str(e["category"]) == "generic" else 1

# ---------------------------------------------------------------------------
# 授予 / 查询
# ---------------------------------------------------------------------------
func core_id_of_type(type_idx: int) -> String:
	return str(game.core_types[type_idx].get("id", ""))

func grant(type_idx: int, effect_id: String) -> void:
	if type_idx < 0 or type_idx >= game.core_types.size():
		return
	var core_id := core_id_of_type(type_idx)
	var key := str(effect_id)
	var cur: Dictionary = grants.get(core_id, {})
	var cur_stacks := int(cur.get(key, 0))
	var mx := max_stacks(key)
	if mx <= 0 or cur_stacks >= mx:
		return
	cur[key] = cur_stacks + 1
	grants[core_id] = cur

func has(core_id: String, effect_id: String) -> bool:
	return stacks(core_id, effect_id) > 0

func stacks(core_id: String, effect_id: String) -> int:
	var cur: Dictionary = grants.get(core_id, {})
	return int(cur.get(effect_id, 0))

## 该模式名对应哪些触手（core id）
func core_ids_for_mode(mode_name: String) -> Array:
	var out: Array = []
	for t in game.core_types:
		if str(t.get("mode", "")) == mode_name:
			out.append(str(t.get("id", "")))
	return out

# ---------------------------------------------------------------------------
# 部署费用
# ---------------------------------------------------------------------------
## 部署该触手（type_idx）的实际费用：基础费用 + 贵胄光环自身 +5，其它在场光环 -2
func deploy_cost(type_idx: int) -> int:
	var core_id := core_id_of_type(type_idx)
	var mode_name := str(game.core_types[type_idx].get("mode", ""))
	var cost: int = game.map_data.mode_deploy_cost(mode_name)
	if has(core_id, "cost_swap_aura"):
		cost += 5
	cost -= 2 * aura_count_excluding(core_id)
	return maxi(cost, 0)

## 当前在场的、除 core_id 外拥有「贵胄光环」的触手种类数
func aura_count_excluding(core_id: String) -> int:
	var seen: Dictionary = {}
	for n in game.units.values():
		var oid := str((n as PlayerCore).config.get("id", ""))
		if oid == core_id:
			continue
		if has(oid, "cost_swap_aura") and not seen.has(oid):
			seen[oid] = true
	return seen.size()

# ---------------------------------------------------------------------------
# 数值 / 概率（通用词条按乘算）
# ---------------------------------------------------------------------------
func survival_multiplier(core_id: String) -> float:
	return pow(1.2, stacks(core_id, "core_longevity"))

## 蔓延生成的地块耐久：返回 hp（1 或 2，2 = 可承受两次清理）
func roll_tile_hp(core_id: String) -> int:
	var s := stacks(core_id, "tile_toughness")
	if s <= 0:
		return 1
	if randf() < 1.0 - pow(0.9, s):
		return 2
	return 1

## 该模式的蔓延间隔乘算系数（<1 更快）
func spread_interval_multiplier(mode_name: String) -> float:
	var mult := 1.0
	for core_id in core_ids_for_mode(mode_name):
		var s := stacks(core_id, "spread_interval_down")
		if s > 0:
			mult *= pow(0.9, s)
	# 初生急速：该模式下有任一存活核心处于部署后 5 秒内
	for n in game.units.values():
		var pc := n as PlayerCore
		if pc.mode() != mode_name:
			continue
		if has(str(pc.config.get("id", "")), "deploy_haste_5s") and game.battle_time - pc.spawn_time <= 5.0:
			mult *= 0.5
			break
	return mult

## 蔓延结算后：按概率额外随机蔓延一格（蔓延分支）
func extra_spread(mode_name: String) -> void:
	var p := 0.0
	for core_id in core_ids_for_mode(mode_name):
		var s := stacks(core_id, "spread_extra_tile")
		if s > 0:
			p = 1.0 - (1.0 - p) * pow(0.9, s)
	if p <= 0.0:
		return
	if randf() >= p:
		return
	var tiles: Array = []
	for cell in game.polluted.keys():
		if str(game.polluted[cell].get("mode", "")) == mode_name:
			tiles.append(cell)
	if tiles.is_empty():
		return
	tiles.shuffle()
	var base: Vector2i = tiles[0]
	var pl: Dictionary = game.polluted[base]
	var offs: Array = game.NEIGHBORS.duplicate()
	offs.shuffle()
	for d in offs:
		var n: Vector2i = base + d
		if game.geometry.in_bounds(n) and not game.polluted.has(n) and not game.walls.has(n):
			var np: Dictionary = pl.duplicate()
			np["hp"] = roll_tile_hp(str(np.get("origin_id", "")))
			game.spread.pollute_with(n, np)
			return

# ---------------------------------------------------------------------------
# 部署 / 战斗开始钩子
# ---------------------------------------------------------------------------
## 部署一颗核心后调用：落地蔓延（周围六格）+ 部署返费
func on_core_deployed(n: PlayerCore, cell: Vector2i) -> void:
	var core_id := str(n.config.get("id", ""))
	if has(core_id, "deploy_surround"):
		for d in game.NEIGHBORS:
			var t: Vector2i = cell + d
			if game.geometry.in_bounds(t) and not game.polluted.has(t) \
					and not game.walls.has(t) and not game.turret_positions.has(t):
				game.spread.pollute_with(t, {
					"mode": n.mode(),
					"dir": n.direction,
					"source": cell,
					"origin_id": core_id,
					"origin_spawn_time": n.spawn_time,
					"owner": n.uid,
					"hp": 1,
				})
	if has(core_id, "deploy_gain_cost"):
		game.deploy_points = mini(game.deploy_points + 5, PlayerCore.DEPLOY_COST_MAX)

## 战斗开始（进入 RUNNING）时调用：开局增援
func on_battle_start() -> void:
	for i in range(game.core_types.size()):
		if not has(core_id_of_type(i), "battle_extra_core"):
			continue
		var cell := random_deployable_edge()
		if cell.x == 999999:
			continue
		var dir := Vector2i.ZERO
		if game.map_data.behavior_for_mode(str(game.core_types[i].get("mode", ""))).needs_direction():
			dir = game.NEIGHBORS[randi() % game.NEIGHBORS.size()]
		game.deploy.spawn_core(cell, i, dir, true)

func random_deployable_edge() -> Vector2i:
	var edges: Array[Vector2i] = []
	for c: Vector2i in game.geometry.all_cells():
		if game.geometry.is_edge(c) and not game.walls.has(c) \
				and not game.turret_positions.has(c) and not game.units.has(c):
			edges.append(c)
	if edges.is_empty():
		return Vector2i(999999, 999999)
	return edges[randi() % edges.size()]

# ---------------------------------------------------------------------------
# 清除判定钩子
# ---------------------------------------------------------------------------
## 一次清除判定：返回 true 表示真正移除地块；false 表示被庇护挡住或只是扣除一次 hp
func attempt_clear(payload: Dictionary, battle_time: float) -> bool:
	var core_id := str(payload.get("origin_id", ""))
	if has(core_id, "deploy_shield_10s"):
		var ost := float(payload.get("origin_spawn_time", 0.0))
		if battle_time < ost + 10.0:
			return false
	var hp := int(payload.get("hp", 1))
	if hp > 1:
		payload["hp"] = hp - 1
		return false
	return true

## 真正清除后，应施加给清除者的眩晕秒数（清算反噬）
func stun_on_clear(payload: Dictionary) -> float:
	if has(str(payload.get("origin_id", "")), "clear_stun_enemy"):
		return 1.0
	return 0.0

# ---------------------------------------------------------------------------
# 控制台授予 UI（不提供任何掉落 / 获取途径，仅此处可授予）
# ---------------------------------------------------------------------------
func add_console_section(parent: Control) -> void:
	parent.add_child(_section_label("—— 掉落效果 ——"))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	grant_core_option = OptionButton.new()
	grant_core_option.custom_minimum_size = Vector2(120, 0)
	for t in game.core_types:
		grant_core_option.add_item(str(t.get("name", "核心")))
	row.add_child(grant_core_option)

	grant_effect_option = OptionButton.new()
	grant_effect_option.custom_minimum_size = Vector2(170, 0)
	for idx in range(EFFECTS.size()):
		var e: Dictionary = EFFECTS[idx]
		var tag := "专属" if str(e["category"]) == "unique" else "通用"
		grant_effect_option.add_item("%s·%s" % [tag, str(e["name"])])
		grant_effect_option.set_item_tooltip(idx, str(e["desc"]))
	row.add_child(grant_effect_option)

	var grant_btn := Button.new()
	grant_btn.text = "获得"
	grant_btn.pressed.connect(_on_grant_pressed)
	row.add_child(grant_btn)

	var hint := Label.new()
	hint.text = "通用词条可叠加至多 5 层（乘算），专属词条 1 层。"
	hint.add_theme_color_override("font_color", Color("9fb0cc"))
	parent.add_child(hint)

	grant_list_label = Label.new()
	grant_list_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	grant_list_label.custom_minimum_size = Vector2(340, 0)
	grant_list_label.add_theme_color_override("font_color", Color("ffd166"))
	parent.add_child(grant_list_label)
	refresh_grant_ui()

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("8a9bb8"))
	return l

func _on_grant_pressed() -> void:
	if grant_core_option == null or grant_effect_option == null:
		return
	var type_idx: int = grant_core_option.selected
	var eid := str(EFFECTS[grant_effect_option.selected]["id"])
	var core_name: String = str(game.core_types[type_idx]["name"])
	var effect_name: String = str(EFFECTS[grant_effect_option.selected]["name"])
	var before := stacks(core_id_of_type(type_idx), eid)
	grant(type_idx, eid)
	if stacks(core_id_of_type(type_idx), eid) == before:
		game.hud.set_status("该词条已达上限，无法继续叠加")
	else:
		game.hud.set_status("已获得：%s → %s" % [core_name, effect_name])
	refresh_grant_ui()

func refresh_grant_ui() -> void:
	if grant_list_label != null:
		grant_list_label.text = grants_text()

func grants_text() -> String:
	if grants.is_empty():
		return "尚未获得任何掉落效果。"
	var lines: Array = []
	for i in range(game.core_types.size()):
		var core_id := core_id_of_type(i)
		var cur: Dictionary = grants.get(core_id, {})
		if cur.is_empty():
			continue
		var parts: Array = []
		for eid in cur.keys():
			var e := find_effect(str(eid))
			var nm := str(e.get("name", eid))
			var s := int(cur[eid])
			parts.append(nm if s <= 1 else "%s ×%d" % [nm, s])
		lines.append("%s：%s" % [game.core_types[i]["name"], "、".join(PackedStringArray(parts))])
	return "已获得效果：\n" + "\n".join(PackedStringArray(lines))
