class_name HexHud
extends RefCounted

## HUD —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：左上角状态/开始/重置/模式切换面板、右下角核心类型选择面板（含部署费用条）、
## 状态文案与部署费用显示的构建与刷新。

var game

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

	var group := ButtonGroup.new()
	for i in range(game.core_types.size()):
		var t: Dictionary = game.core_types[i]
		var btn := Button.new()
		btn.text = t["name"]
		btn.toggle_mode = true
		btn.button_group = group
		btn.custom_minimum_size = Vector2(140, 0)
		btn.pressed.connect(select_core.bind(i))
		game.core_buttons.append(btn)
		vbox.add_child(btn)
	if game.selected_core >= 0 and game.selected_core < game.core_buttons.size():
		game.core_buttons[game.selected_core].button_pressed = true

	# 先添加子节点再设置锚点，确保按实际内容尺寸定位到右下角
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)

func select_core(i: int) -> void:
	if i < 0 or i >= game.core_types.size():
		return
	game.selected_core = i
	game.awaiting_direction = false
	for j in range(game.core_buttons.size()):
		game.core_buttons[j].button_pressed = (j == i)
	if game.tutorial_spotlight == "core":
		game.tutorial_spotlight = "map"
		game.guide.update_spotlight()
	update_status()
	game.queue_redraw()

func set_status(text: String) -> void:
	if game.status_label:
		game.status_label.text = text

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
			set_status("部署阶段：当前核心「%s」（消耗 %d 点费用）｜剩余部署费用 %d/%d（只能部署在最外围一圈）" % [t["name"], game.map_data.mode_deploy_cost(str(t["mode"])), game.deploy_points, PlayerCore.DEPLOY_COST_MAX])
	elif game.phase == game.Phase.RUNNING:
		if game.awaiting_direction:
			set_status("定向核心：请点击相邻地块选择延伸方向（右键取消）")
		else:
			set_status("扩散中…… 已污染 %d/%d | 存活核心 %d | 存活炮台 %d（仍可在外围继续部署）" % [game.polluted.size(), game.total_hexes, game.units.size(), game.turrets.alive_count()])
	elif game.phase == game.Phase.WON:
		set_status("胜利！所有敌方炮台都被污染损毁")
	elif game.phase == game.Phase.LOST:
		set_status("失败！所有单位核心已结束，而仍有存活的敌方炮台")
