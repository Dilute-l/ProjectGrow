class_name HexConsole
extends RefCounted

## 控制台 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：按 R 打开的数值调整面板（敌方攻击间隔），应用/恢复默认/重播教程/关闭，
## 以及面板 UI 的构建。

var game

func _init(g) -> void:
	game = g

func build_console() -> void:
	game.console_layer = CanvasLayer.new()
	game.console_layer.layer = 20
	game.console_layer.visible = false
	game.add_child(game.console_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	game.console_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	game.console_layer.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "控制台 · 调整数值"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	# 敌方
	vbox.add_child(section_label("—— 敌方 ——"))
	game.sb_enemy = add_spin_row(vbox, "攻击间隔（秒）", 0.1, 30.0, 0.1, game.enemy_attack_interval, false)

	var hint := Label.new()
	hint.text = "核心的持续时间、扩散间隔、颜色等请在 cores.json 中修改。\n修改后点击“应用”生效；按 R 或 Esc 关闭。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(340, 0)
	hint.add_theme_color_override("font_color", Color("9fb0cc"))
	vbox.add_child(hint)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(hbox)

	var apply_btn := Button.new()
	apply_btn.text = "应用"
	apply_btn.pressed.connect(apply)
	hbox.add_child(apply_btn)

	var default_btn := Button.new()
	default_btn.text = "恢复默认"
	default_btn.pressed.connect(defaults)
	hbox.add_child(default_btn)

	var replay_btn := Button.new()
	replay_btn.text = "重新播放教程"
	replay_btn.pressed.connect(game.guide.replay)
	hbox.add_child(replay_btn)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(close)
	hbox.add_child(close_btn)

func section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("8a9bb8"))
	return l

func add_spin_row(parent: Control, label_text: String, mn: float, mx: float, step: float, initial: float, rounded: bool) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(170, 0)
	row.add_child(lbl)

	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.rounded = rounded
	sb.value = initial
	sb.custom_minimum_size = Vector2(120, 0)
	row.add_child(sb)
	return sb

func open() -> void:
	game.sb_enemy.value = game.enemy_attack_interval
	game.console_open = true
	game.console_layer.visible = true
	game.queue_redraw()

func close() -> void:
	game.console_open = false
	game.console_layer.visible = false
	game.queue_redraw()

func apply() -> void:
	game.enemy_attack_interval = game.sb_enemy.value
	for t in game.turret_map.values():
		t.attack_interval = game.enemy_attack_interval
	game.hud.update_status()
	game.queue_redraw()

func defaults() -> void:
	game.enemy_attack_interval = game.ENEMY_ATTACK_INTERVAL_DEFAULT
	for t in game.turret_map.values():
		t.attack_interval = game.enemy_attack_interval
	game.sb_enemy.value = game.enemy_attack_interval
	game.hud.update_status()
	game.queue_redraw()
