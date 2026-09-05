class_name HexHud
extends RefCounted

## HUD —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：左上角状态/开始/重置/模式切换面板、右下角核心类型选择面板（含部署费用条）、
## 状态文案与部署费用显示的构建与刷新。

var game

# —— 本局词条（Buff）总览弹窗 ——
var buff_button: Button
var buff_layer: CanvasLayer
var buff_content: VBoxContainer
# 核心选择按钮所在容器（解锁变化时重建按钮用）
var core_buttons_box: VBoxContainer

func _init(g) -> void:
	game = g

func build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	game.add_child(layer)
	game.hud_layer = layer

	var panel := PanelContainer.new()
	panel.position = Vector2(16, 12)
	layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	game.status_label = Label.new()
	game.status_label.add_theme_font_size_override("font_size", 16)
	game.status_label.add_theme_color_override("font_color", Color("ffd166"))
	vbox.add_child(game.status_label)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(hbox)

	game.start_button = Button.new()
	game.start_button.text = "开始扩散"
	game.start_button.pressed.connect(game.deploy.start)
	hbox.add_child(game.start_button)

	var reset_button := Button.new()
	reset_button.text = "重置"
	reset_button.pressed.connect(game.deploy.reset)
	hbox.add_child(reset_button)

	game.mode_button = Button.new()
	game.mode_button.text = "编辑模式"
	game.mode_button.pressed.connect(game.editor.toggle_mode)
	hbox.add_child(game.mode_button)

func build_core_selector() -> void:
	game.core_buttons.clear()
	game.core_selector_layer = CanvasLayer.new()
	game.core_selector_layer.layer = 10
	game.add_child(game.core_selector_layer)

	var panel := PanelContainer.new()
	game.core_selector_layer.add_child(panel)
	game.core_selector_panel = panel

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)
	core_buttons_box = vbox

	# 本局词条总览按钮（位于部署费用条上方）
	var buff_row := HBoxContainer.new()
	buff_row.add_theme_constant_override("separation", 6)
	vbox.add_child(buff_row)
	buff_button = Button.new()
	buff_button.text = "🧪 本局词条"
	buff_button.custom_minimum_size = Vector2(140, 0)
	buff_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buff_button.pressed.connect(toggle_buff_overview)
	buff_row.add_child(buff_button)

	# 部署费用条（实时显示剩余费用；位于核心类型上方）
	var cost_row := HBoxContainer.new()
	cost_row.add_theme_constant_override("separation", 6)
	vbox.add_child(cost_row)
	var cost_caption := Label.new()
	cost_caption.text = "部署费用"
	cost_caption.add_theme_font_size_override("font_size", 14)
	cost_row.add_child(cost_caption)
	game.cost_bar = ProgressBar.new()
	game.cost_bar.min_value = 0.0
	game.cost_bar.max_value = float(PlayerCore.DEPLOY_COST_MAX)
	game.cost_bar.value = float(game.deploy_points)
	game.cost_bar.show_percentage = false
	game.cost_bar.custom_minimum_size = Vector2(100, 0)
	cost_row.add_child(game.cost_bar)
	game.cost_value_label = Label.new()
	game.cost_value_label.add_theme_font_size_override("font_size", 14)
	cost_row.add_child(game.cost_value_label)
	update_cost_ui()

	var title := Label.new()
	title.text = "选择核心类型"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	# 只显示已解锁的核心；未解锁的直接不显示（不再以 🔒 占位）
	_populate_core_buttons(vbox)

	# 先添加子节点再设置锚点，确保按实际内容尺寸定位到右下角
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)

## 重建核心选择按钮：仅列出已解锁核心，每个按钮用 meta("core_type") 记录其 core_types 索引
func _populate_core_buttons(parent: Control) -> void:
	for b in game.core_buttons:
		if is_instance_valid(b):
			b.queue_free()
	game.core_buttons.clear()
	var group := ButtonGroup.new()
	for i in range(game.core_types.size()):
		if not _type_unlocked(i):
			continue  # 未解锁的核心不显示
		var t: Dictionary = game.core_types[i]
		var btn := Button.new()
		btn.text = str(t.get("name", "核心"))
		btn.toggle_mode = true
		btn.button_group = group
		btn.custom_minimum_size = Vector2(140, 0)
		btn.set_meta("core_type", i)
		btn.pressed.connect(select_core.bind(i))
		game.core_buttons.append(btn)
		parent.add_child(btn)
	# 恢复选中高亮（按 meta 的 core_type 匹配，而非按钮下标）
	if game.selected_core >= 0 and _type_unlocked(game.selected_core):
		for b in game.core_buttons:
			if int(b.get_meta("core_type", -1)) == game.selected_core:
				b.button_pressed = true
				break

## 已解锁核心的 type_idx 列表（按 core_types 顺序），供数字键等按显示顺序选择
func visible_core_indices() -> Array[int]:
	var out: Array[int] = []
	for i in range(game.core_types.size()):
		if _type_unlocked(i):
			out.append(i)
	return out

func select_core(i: int) -> void:
	if i < 0 or i >= game.core_types.size():
		return
	if not _type_unlocked(i):
		set_status("「%s」尚未解锁（通关后的掉落中可选）" % str(game.core_types[i].get("name", "核心")))
		return
	game.selected_core = i
	game.awaiting_direction = false
	for b in game.core_buttons:
		b.button_pressed = (int(b.get_meta("core_type", -1)) == i)
	if game.tutorial_spotlight == "core":
		game.tutorial_spotlight = "map"
		game.guide.update_spotlight()
	update_status()
	game.queue_redraw()

func set_status(text: String) -> void:
	if game.status_label:
		game.status_label.text = text

## type_idx 对应的核心是否已解锁（委托给 rewards 模块）
func _type_unlocked(i: int) -> bool:
	if game.rewards != null:
		return game.rewards.is_type_unlocked(i)
	return game.unlocked_core_ids.has(str(game.core_types[i].get("id", "")))

## 解锁状态变化后刷新选择栏：重新生成按钮（只显示已解锁核心），并复位失效的选中项
func refresh_core_unlocks() -> void:
	if game.selected_core >= 0 and not _type_unlocked(game.selected_core):
		game.selected_core = -1
	if core_buttons_box != null:
		_populate_core_buttons(core_buttons_box)
	update_status()
	game.queue_redraw()

## 部署费用条文本
func cost_text() -> String:
	return "%d/%d" % [game.deploy_points, PlayerCore.DEPLOY_COST_MAX]

func update_cost_ui() -> void:
	if game.cost_bar != null:
		game.cost_bar.value = float(game.deploy_points)
	if game.cost_value_label != null:
		game.cost_value_label.text = cost_text()

func update_status() -> void:
	if game.mode == game.Mode.EDIT:
		set_status("编辑模式：左键放置（墙/炮台），右键擦除；工具栏可调半径、导入/导出 JSON")
		return
	if game.phase == game.Phase.DEPLOY:
		if game.awaiting_direction:
			set_status("定向核心：请点击相邻地块选择延伸方向（右键取消）")
		elif game.selected_core < 0:
			set_status("部署阶段：请先在右下角选择核心类型")
		else:
			var t: Dictionary = game.core_types[game.selected_core]
			set_status("部署阶段：当前核心「%s」（消耗 %d 点费用）｜剩余部署费用 %d/%d（只能部署在最外围一圈）" % [t["name"], game.drop_effects.deploy_cost(game.selected_core), game.deploy_points, PlayerCore.DEPLOY_COST_MAX])
	elif game.phase == game.Phase.RUNNING:
		if game.awaiting_direction:
			set_status("定向核心：请点击相邻地块选择延伸方向（右键取消）")
		else:
			set_status("扩散中…… 已污染 %d/%d | 存活核心 %d | 存活炮台 %d（仍可在外围继续部署）" % [game.polluted.size(), game.total_hexes, game.units.size(), game.turrets.alive_count()])
	elif game.phase == game.Phase.WON:
		set_status("胜利！所有敌方炮台都被污染损毁")
	elif game.phase == game.Phase.LOST:
		set_status("失败！所有单位核心已结束，而仍有存活的敌方炮台")

# ---------------------------------------------------------------------------
# 本局词条（Buff）总览弹窗
# ---------------------------------------------------------------------------
## 构建弹窗层（一次即可）；内容在每次打开时重建
func build_buff_overview() -> void:
	buff_layer = CanvasLayer.new()
	buff_layer.layer = 24
	buff_layer.visible = false
	game.add_child(buff_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	buff_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	buff_layer.add_child(center)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600, 540)
	center.add_child(scroll)

	var panel := PanelContainer.new()
	scroll.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var top := HBoxContainer.new()
	vbox.add_child(top)
	var title := Label.new()
	title.text = "本局获得的词条（Buff）"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(close_buff_overview)
	top.add_child(close_btn)

	var note := Label.new()
	note.text = "作用于全体的词条会标注「全体」；只强化特定核心的词条会标明其核心。"
	note.add_theme_color_override("font_color", Color("9fb0cc"))
	note.add_theme_font_size_override("font_size", 13)
	vbox.add_child(note)

	buff_content = VBoxContainer.new()
	buff_content.add_theme_constant_override("separation", 4)
	vbox.add_child(buff_content)

func toggle_buff_overview() -> void:
	if game.buff_overview_open:
		close_buff_overview()
	else:
		open_buff_overview()

func open_buff_overview() -> void:
	if buff_layer == null:
		return
	game.buff_overview_open = true
	_fill_buff_overview()
	buff_layer.visible = true
	game.queue_redraw()

func close_buff_overview() -> void:
	game.buff_overview_open = false
	if buff_layer != null:
		buff_layer.visible = false
	game.queue_redraw()

func _fill_buff_overview() -> void:
	if buff_content == null:
		return
	for ch in buff_content.get_children():
		buff_content.remove_child(ch)
		ch.queue_free()
	# 当前已解锁的核心 id 集合
	var unlocked: Array = []
	for i in range(game.core_types.size()):
		if game.rewards != null and game.rewards.is_type_unlocked(i):
			unlocked.append(str(game.core_types[i].get("id", "")))
	# 按词条聚合：effect_id -> {name, cat, desc, per:{core_id: {n, core_name}}}
	var by_effect: Dictionary = {}
	for i in range(game.core_types.size()):
		var cid := str(game.core_types[i].get("id", ""))
		var cur: Dictionary = game.drop_effects.grants.get(cid, {})
		if cur.is_empty():
			continue
		var core_name := str(game.core_types[i].get("name", cid))
		for eid in cur.keys():
			var e = game.drop_effects.find_effect(str(eid))
			if e.is_empty():
				continue
			var key := str(eid)
			var eff: Dictionary = by_effect.get(key, {})
			if eff.is_empty():
				eff = {
					"name": str(e.get("name", key)),
					"cat": str(e.get("category", "generic")),
					"desc": str(e.get("desc", "")),
					"per": {},
				}
				by_effect[key] = eff
			eff["per"][cid] = {"n": int(cur[eid]), "core_name": core_name}
	if by_effect.is_empty():
		var empty := Label.new()
		empty.text = "本局尚未获得任何词条（通关掉落或控制台授予后会显示在这里）。"
		empty.add_theme_color_override("font_color", Color("9fb0cc"))
		buff_content.add_child(empty)
		return
	for key in by_effect:
		var eff: Dictionary = by_effect[key]
		var per: Dictionary = eff["per"]
		var cat_tag := "专属" if str(eff["cat"]) == "unique" else "通用"
		var col := Color("d8b4ff") if cat_tag == "专属" else Color("8ae29a")
		# “全体”：每个已解锁核心都持有该词条，且层数一致
		var all_same := unlocked.size() > 0
		var expect := -1
		for cid in unlocked:
			if not per.has(str(cid)):
				all_same = false
				break
			var nn := int((per[str(cid)] as Dictionary)["n"])
			if expect < 0:
				expect = nn
			elif nn != expect:
				all_same = false
		if all_same and expect > 0:
			_add_buff_card("全体", col, str(eff["name"]), cat_tag, expect, str(eff["desc"]))
			continue
		for cid in per:
			var pc: Dictionary = per[cid]
			_add_buff_card(str(pc["core_name"]), col, str(eff["name"]), cat_tag, int(pc["n"]), str(eff["desc"]))

## 词条卡片（样式贴近战后三选一卡片）；scope 为「全体」或某核心名
func _add_buff_card(scope: String, col: Color, name: String, cat_tag: String, n: int, desc: String) -> void:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = col.darkened(0.82)
	style.border_color = col
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	card.add_theme_stylebox_override("panel", style)

	var cm := MarginContainer.new()
	cm.add_theme_constant_override("margin_left", 12)
	cm.add_theme_constant_override("margin_top", 8)
	cm.add_theme_constant_override("margin_right", 12)
	cm.add_theme_constant_override("margin_bottom", 8)
	card.add_child(cm)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	cm.add_child(box)

	var ttl := Label.new()
	ttl.text = name
	ttl.add_theme_font_size_override("font_size", 16)
	ttl.add_theme_color_override("font_color", col.lightened(0.25))
	box.add_child(ttl)

	var meta := Label.new()
	var stack_txt := "" if n <= 1 else " ×%d" % n
	meta.text = "%s ｜ 作用于：%s%s" % [cat_tag, scope, stack_txt]
	meta.add_theme_font_size_override("font_size", 13)
	meta.add_theme_color_override("font_color", Color("cfe0ff"))
	box.add_child(meta)

	var dsc := Label.new()
	dsc.text = desc
	dsc.add_theme_font_size_override("font_size", 13)
	dsc.add_theme_color_override("font_color", Color("9fb0cc"))
	dsc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(dsc)
	card.tooltip_text = desc
	buff_content.add_child(card)
