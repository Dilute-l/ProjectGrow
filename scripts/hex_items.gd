class_name HexItems
extends RefCounted

## 一次性道具系统 —— 独立模块（从 hex_game 拆出，同其它 hex_* 模块组合协作）。
##
## 职责：
##   - 读 maps/items.json 的道具定义库（与 effects.json / special_tiles.json 同构）；
##   - 持有本局道具库存（道具可堆叠、跨轮次保留，新一局 reset_run 清空）；
##   - 概率掉落：道具与特殊地块同属「概率掉落」候选（hex_rewards 接入）；
##   - 战斗中随时使用：点击道具 → 进入「瞄准」模式，地图左键点选目标生效、右键取消；
##   - 道具效果（per 目标实例，互不影响）：
##       1) 核心蔓延速度翻倍（与该核心已有的一切加速/减速乘算）；
##       2) 敌方炮台攻速减半 30s（攻击间隔 ×2，到时恢复）；
##       3) 核心剩余生存时间 +100%（按该核心原始生存时长增加）；
##       4) 在目标地块与全部相邻格直接生成静态污染块（不可生成在敌方炮台/墙上）。
##   - 道具定义字段：id / name / desc / color / icon / target(core|turret|tile) / effect。

const ITEMS_PATH := "res://maps/items.json"

## items.json 缺失 / 损坏时的兜底（应与 maps/items.json 保持一致）
const ITEMS_FALLBACK: Array = [
	{"id": "speed_x2_core", "name": "急速增殖", "desc": "点选一颗已部署的核心：其蔓延速度翻倍（与该核心已有的一切加速/减速乘算）",
	 "color": "#5cd8ff", "icon": "⚡", "target": "core", "effect": "core_spread_x2"},
	{"id": "slow_turret_30", "name": "迟缓孢子", "desc": "点选一座敌方炮台：其攻击速度减半（攻击间隔 ×2），持续 30 秒",
	 "color": "#8ae29a", "icon": "🐌", "target": "turret", "effect": "turret_slow_30"},
	{"id": "life_x2_core", "name": "延寿灵液", "desc": "点选一颗已部署的核心：其剩余生存时间 +100%（按该核心原始生存时长的 100% 增加）",
	 "color": "#d8b4ff", "icon": "💧", "target": "core", "effect": "core_life_x2"},
	{"id": "burst_tentacle", "name": "触手爆发", "desc": "点选一个地块：该地块与其所有相邻地块直接生成触手污染（不能在敌方炮台上生成）",
	 "color": "#ff9a5c", "icon": "🌱", "target": "tile", "effect": "burst_tentacle"},
]

## 炮台减速时长（秒）；与道具定义 effect == "turret_slow_30" 对应
const TURRET_SLOW_SECONDS := 30.0

var game

## 道具定义库：id -> 定义 Dictionary
var item_defs: Dictionary = {}

## 库存：item_id -> 数量（本局持有，可堆叠；跨轮次保留，新一局清空）
var stock: Dictionary = {}

## 本关已消耗的道具：item_id -> 数量（仅用于「手动重置本关」时返还）
var _round_consumed := {}

## 「急速增殖」标记：uid -> true（只对标记的那一颗核心生效）
var _spread_boost := {}

## 炮台减速表：turret 节点 -> {orig, remain}（orig=原攻击间隔，remain=剩余秒数）
var _turret_slows := {}

## UI（右下角词条上方）
var bar_vbox: VBoxContainer
var item_buttons_box: VBoxContainer

## 当前瞄准使用的道具 id；"" 表示未瞄准
var armed_item_id := ""

func _init(g) -> void:
	game = g
	_load_items()

# ---------------------------------------------------------------------------
# 道具库
# ---------------------------------------------------------------------------
func _load_items() -> void:
	item_defs.clear()
	if FileAccess.file_exists(ITEMS_PATH):
		var f := FileAccess.open(ITEMS_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary and data.get("items") is Array:
				for entry in data["items"]:
					if entry is Dictionary:
						var id := str(entry.get("id", ""))
						if id != "":
							item_defs[id] = entry.duplicate()
	if item_defs.is_empty():
		push_warning("HexItems: 道具库 %s 缺失或为空，使用内置兜底" % ITEMS_PATH)
		for e in ITEMS_FALLBACK:
			item_defs[str(e["id"])] = e.duplicate()

func def_of(item_id: String) -> Dictionary:
	return item_defs.get(item_id, {})

## 概率掉落 / UI 通用：道具的展示卡（供 hex_rewards 组装候选）
func make_option(item_id: String) -> Dictionary:
	var d := def_of(item_id)
	var col := Color(str(d.get("color", "#9fb0cc")))
	return {
		"kind": "item",
		"id": item_id,
		"title": str(d.get("icon", "")) + " " + str(d.get("name", item_id)),
		"sub": "一次性道具",
		"color": col,
		"desc": str(d.get("desc", "")),
	}

# ---------------------------------------------------------------------------
# 库存
# ---------------------------------------------------------------------------
func count_of(item_id: String) -> int:
	return int(stock.get(item_id, 0))

## 获得一件道具（掉落/测试用）；跨轮次保留
func grant(item_id: String) -> void:
	if not item_defs.has(item_id):
		return
	stock[item_id] = count_of(item_id) + 1
	refresh_bar()

## 扣除一件；数量不足返回 false（不扣）。成功时记入「本关消耗」（供重置返还）
func consume(item_id: String) -> bool:
	var n := count_of(item_id)
	if n <= 0:
		return false
	if n == 1:
		stock.erase(item_id)
	else:
		stock[item_id] = n - 1
	_round_consumed[item_id] = int(_round_consumed.get(item_id, 0)) + 1
	refresh_bar()
	return true

## 新一局（进入 hex_game）清空库存与临时效果
func reset_run() -> void:
	stock.clear()
	_round_consumed.clear()
	_spread_boost.clear()
	_turret_slows.clear()
	armed_item_id = ""
	refresh_bar()

## 每轮（关卡）重置：清掉与场上实例绑定的临时效果（部署/炮台已重建），并清空本关消耗记录。
## restore_consumed=true（手动重置本关）：先把本关消耗的道具退回库存再清空；否则直接清空（通关换关不返还）。
func on_round_reset(restore_consumed: bool = false) -> void:
	if restore_consumed and not _round_consumed.is_empty():
		for item_id in _round_consumed.keys():
			var n := int(_round_consumed[item_id])
			stock[str(item_id)] = count_of(str(item_id)) + n
		game.hud.set_status("已重置本关：本关消耗的道具已返还")
		game.hud.update_status()
	_round_consumed.clear()
	_spread_boost.clear()
	_turret_slows.clear()
	armed_item_id = ""
	refresh_bar()

# ---------------------------------------------------------------------------
# 使用流程（瞄准 → 点选目标）
# ---------------------------------------------------------------------------
func is_aiming() -> bool:
	return armed_item_id != ""

## 点击道具按钮：进入瞄准（数量不足或无定义则忽略）
func arm(item_id: String) -> void:
	if count_of(item_id) <= 0 or not item_defs.has(item_id):
		return
	armed_item_id = item_id
	var d := def_of(item_id)
	game.hud.set_status("使用道具「%s」：请在地图上点选目标（右键取消）" % str(d.get("name", item_id)))

func cancel_arm() -> void:
	armed_item_id = ""
	game.hud.update_status()
	game.queue_redraw()

## 当前瞄准道具有效的目标格类型提示（供绘制/状态使用）
func armed_target() -> String:
	if armed_item_id == "":
		return ""
	return str(def_of(armed_item_id).get("target", ""))

## 瞄准态校验：该格是否为合法目标（core=有存活我方核心 / turret=有存活炮台 / tile=可生成地块）
func can_target(cell: Vector2i) -> bool:
	var target := armed_target()
	if target == "core":
		return game.units.has(cell)
	if target == "turret":
		var t = game.turret_map.get(cell)
		return t != null and t.alive
	if target == "tile":
		return game.geometry.in_bounds(cell) and not game.walls.has(cell) \
				and not game.turret_positions.has(cell) and not game.units.has(cell)
	return false

## 在地图上点选目标格：成功则消耗道具并施加效果；失败提示且不消耗
func try_use_at(cell: Vector2i) -> bool:
	if armed_item_id == "":
		return false
	var d := def_of(armed_item_id)
	var effect := str(d.get("effect", ""))
	var ok: bool = false
	match str(d.get("target", "")):
		"core":
			if game.units.has(cell):
				ok = _apply_core_item(game.units[cell] as PlayerCore, effect)
		"turret":
			var t = game.turret_map.get(cell)
			if t != null and t.alive:
				ok = _apply_turret_item(t, effect)
		"tile":
			ok = _apply_tile_item(cell, effect)
	if ok:
		consume(armed_item_id)
		armed_item_id = ""
		game.hud.update_status()
		game.queue_redraw()
		return true
	game.hud.set_status("该目标不适用于「%s」，请重新选择（右键取消）" % str(d.get("name", armed_item_id)))
	game.queue_redraw()
	return false

## 右键/Esc 取消瞄准
func cancel_targeting() -> void:
	cancel_arm()

# ---------------------------------------------------------------------------
# 道具效果（per 实例）
# ---------------------------------------------------------------------------
func _apply_core_item(n: PlayerCore, effect: String) -> bool:
	match effect:
		"core_spread_x2":
			_spread_boost[n.uid] = true
			game.hud.set_status("「急速增殖」：该核心蔓延速度已翻倍")
			return true
		"core_life_x2":
			var add := float(n.config.get("duration", 15.0))
			n.config["duration"] = float(n.config.get("duration", 15.0)) + add
			n.remaining += add
			n.queue_redraw()
			game.hud.set_status("「延寿灵液」：该核心剩余生存时间 +100%%")
			return true
	return false

func _apply_turret_item(t, effect: String) -> bool:
	if effect == "turret_slow_30":
		if _turret_slows.has(t):
			# 已减速中：重新计时即可（不重复乘）
			(_turret_slows[t] as Dictionary)["remain"] = TURRET_SLOW_SECONDS
		else:
			_turret_slows[t] = {"orig": float(t.attack_interval), "remain": TURRET_SLOW_SECONDS}
			t.attack_interval = float(t.attack_interval) * 2.0
		game.hud.set_status("「迟缓孢子」：该炮台攻击速度减半，持续 30 秒")
		return true
	return false

func _apply_tile_item(cell: Vector2i, effect: String) -> bool:
	if effect != "burst_tentacle":
		return false
	# 中心 + 全部相邻格生成静态污染块；跳过界外/墙/炮台/已污染/我方单位
	var targets: Array[Vector2i] = [cell]
	for d in game.NEIGHBORS:
		var n: Vector2i = cell + d
		if game.geometry.in_bounds(n):
			targets.append(n)
	var placed := 0
	for t in targets:
		if game.walls.has(t) or game.turret_positions.has(t) or game.units.has(t):
			continue
		if game.polluted.has(t):
			continue
		game.spread.pollute_with(t, {
			"mode": "static",  # 静态：不属于任何核心树，不会自行蔓延
			"dir": Vector2i.ZERO,
			"source": cell,
			"origin_id": "",
			"origin_spawn_time": game.battle_time,
			"owner": -1,
			"hp": 1,
		})
		placed += 1
	if placed > 0:
		game.hud.set_status("「触手爆发」：%d 格生成静态触手污染" % placed)
		return true
	return false

# ---------------------------------------------------------------------------
# 每帧推进（减速倒计时；在 hex_game._process 的 RUNNING 段调用）
# ---------------------------------------------------------------------------
func tick(delta: float) -> void:
	if _turret_slows.is_empty():
		return
	var expired: Array = []
	for t in _turret_slows.keys():
		var rec: Dictionary = _turret_slows[t]
		if t == null or not is_instance_valid(t) or not (t as Node).is_inside_tree():
			expired.append(t)
			continue
		if not t.alive:
			expired.append(t)
			continue
		rec["remain"] = float(rec["remain"]) - delta
		if float(rec["remain"]) <= 0.0:
			t.attack_interval = float(rec["orig"])
			expired.append(t)
	for t in expired:
		_turret_slows.erase(t)

# ---------------------------------------------------------------------------
# 供 hex_game 扩散查询
# ---------------------------------------------------------------------------
## 该核心是否有「急速增殖」标记：有则蔓延间隔乘 0.5（<1 更快；与其它加成乘算）
func spread_interval_factor_for_core(n: PlayerCore) -> float:
	if _spread_boost.has(int(n.uid)):
		return 0.5
	return 1.0

# ---------------------------------------------------------------------------
# UI（右下角 · 本局词条上方）
# ---------------------------------------------------------------------------
## 在 core_selector 面板的 vbox 顶部建立道具区；由 hex_hud 在 buff_row 之前调用
func build_bar(parent: VBoxContainer) -> void:
	bar_vbox = VBoxContainer.new()
	bar_vbox.add_theme_constant_override("separation", 4)
	parent.add_child(bar_vbox)
	var caption := Label.new()
	caption.text = "🧰 持有道具"
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", Color("8a9bb8"))
	bar_vbox.add_child(caption)
	item_buttons_box = VBoxContainer.new()
	item_buttons_box.add_theme_constant_override("separation", 3)
	bar_vbox.add_child(item_buttons_box)
	refresh_bar()

func refresh_bar() -> void:
	if item_buttons_box == null:
		return
	for ch in item_buttons_box.get_children():
		item_buttons_box.remove_child(ch)
		ch.queue_free()
	if stock.is_empty():
		var none := Label.new()
		none.text = "（无 · 通关概率掉落获得）"
		none.add_theme_font_size_override("font_size", 12)
		none.add_theme_color_override("font_color", Color("5a6b85"))
		item_buttons_box.add_child(none)
		return
	for item_id in stock.keys():
		var d := def_of(str(item_id))
		if d.is_empty():
			continue
		var n := int(stock[item_id])
		var btn := Button.new()
		btn.text = "%s %s ×%d" % [str(d.get("icon", "")), str(d.get("name", item_id)), n]
		btn.custom_minimum_size = Vector2(150, 0)
		btn.add_theme_color_override("font_color", Color(str(d.get("color", "#9fb0cc"))).lightened(0.25))
		btn.tooltip_text = str(d.get("desc", ""))
		btn.pressed.connect(arm.bind(str(item_id)))
		item_buttons_box.add_child(btn)
