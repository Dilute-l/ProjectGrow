class_name HexConsole
extends RefCounted

## 控制台 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：按 R 打开的数值调整面板。提供：
##   - 每种核心的扩散间隔（秒）分项调节（写回 core_types 并同步 mode_intervals）；
##   - 每种敌方炮台类型的攻击间隔（秒）分项调节（存 turret_interval_overrides，
##     即时同步到场上该类型节点，并作用于之后的关卡重建）；
##   - 掉落词条授予（drop_effects 自带的面板）；
##   - 应用 / 恢复默认 / 重播教程 / 关闭。
## 说明：核心的持续时间/颜色等仍请改 cores.json（本面板只做“临时平衡”间隔调整）。

var game

# 分项控件与默认值快照（build_console 时记录 cores.json 加载值）
var core_spread_spins: Array = []      # 与 core_types 下标一一对应
var turret_type_names: Array = []      # 类型名（basic/sniper/rapid/beam）
var turret_interval_spins: Array = []  # 与 turret_type_names 对应
var default_core_spreads: Array = []   # 每类核心的默认扩散间隔

const TURRET_TYPE_LABELS := {
	"basic": "基础",
	"sniper": "狙击",
	"rapid": "快速",
	"beam": "光束",
}

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
	dim.offset_left = -5000.0
	dim.offset_top = -5000.0
	dim.offset_right = 5000.0
	dim.offset_bottom = 5000.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	game.console_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	game.console_layer.add_child(center)

	# 可滚动面板，行数较多时也能完整显示
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 560)
	center.add_child(scroll)

	var panel := PanelContainer.new()
	scroll.add_child(panel)

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
	title.text = "控制台 · 平衡调试"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	# —— 我方核心：每种核心的扩散间隔 ——
	vbox.add_child(section_label("—— 我方核心 · 扩散间隔（秒） ——"))
	core_spread_spins.clear()
	default_core_spreads.clear()
	for i in range(game.core_types.size()):
		var t: Dictionary = game.core_types[i]
		var nm := str(t.get("name", "核心"))
		var val := float(t.get("spread_interval", 0.9))
		default_core_spreads.append(val)
		var sb := add_spin_row(vbox, nm, 0.05, 10000.0, 0.05, val, false)
		core_spread_spins.append(sb)

	# —— 敌方炮台：每种类型的攻击间隔（绝对秒数） ——
	vbox.add_child(section_label("—— 敌方炮台 · 攻击间隔（秒/按类型） ——"))
	turret_type_names.clear()
	turret_interval_spins.clear()
	for key in EnemyTurret.TURRET_TYPES.keys():
		turret_type_names.append(str(key))
	for type_name in turret_type_names:
		var lbl := "%s（%s）" % [type_name, _turret_type_label(type_name)]
		var sb := add_spin_row(vbox, lbl, 0.1, 300.0, 0.1, _turret_current_interval(type_name), false)
		turret_interval_spins.append(sb)

	# 掉落效果（仅此处可授予）
	game.drop_effects.add_console_section(vbox)

	var hint := Label.new()
	hint.text = "调整的是“临时”数值：核心扩散间隔写回当前局，炮台间隔对同类型全场生效并延续到之后的关卡。\n应用后生效；恢复默认还原 cores.json 加载值；按 R 或 Esc 关闭。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
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
	lbl.custom_minimum_size = Vector2(220, 0)
	row.add_child(lbl)

	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.rounded = rounded
	sb.value = initial
	sb.custom_minimum_size = Vector2(150, 0)
	row.add_child(sb)
	return sb

func open() -> void:
	# 打开时把每个分项同步为当前实际值
	for i in range(core_spread_spins.size()):
		if i < game.core_types.size():
			core_spread_spins[i].value = float(game.core_types[i].get("spread_interval", 0.9))
	for k in range(turret_interval_spins.size()):
		var type_name: String = turret_type_names[k]
		turret_interval_spins[k].value = _turret_current_interval(type_name)
	game.drop_effects.refresh_grant_ui()
	game.console_open = true
	game.console_layer.visible = true
	game.queue_redraw()

func close() -> void:
	game.console_open = false
	game.console_layer.visible = false
	game.queue_redraw()

## 应用当前面板数值
func apply() -> void:
	# 1) 每种核心的扩散间隔
	for i in range(core_spread_spins.size()):
		if i >= game.core_types.size():
			continue
		var val := float(core_spread_spins[i].value)
		game.core_types[i]["spread_interval"] = val
	_rebuild_mode_intervals()
	# 2) 每种炮台的攻击间隔（绝对秒数）
	for k in range(turret_interval_spins.size()):
		if k >= turret_type_names.size():
			continue
		var type_name: String = turret_type_names[k]
		var val := float(turret_interval_spins[k].value)
		game.turret_interval_overrides[type_name] = val
		for t in game.turret_map.values():
			if t.turret_type == type_name:
				t.attack_interval = val
	game.hud.update_status()
	game.queue_redraw()

## 恢复 cores.json 加载值（本局临时数值还原）
func defaults() -> void:
	for i in range(default_core_spreads.size()):
		if i >= game.core_types.size():
			continue
		game.core_types[i]["spread_interval"] = default_core_spreads[i]
		core_spread_spins[i].value = default_core_spreads[i]
	_rebuild_mode_intervals()
	game.turret_interval_overrides.clear()
	for k in range(turret_interval_spins.size()):
		if k >= turret_type_names.size():
			continue
		var type_name: String = turret_type_names[k]
		turret_interval_spins[k].value = _default_effective_interval(type_name)
	for t in game.turret_map.values():
		t.set_base_interval(game.enemy_attack_interval)
	game.hud.update_status()
	game.queue_redraw()

## 同步 mode_intervals（每种模式取最后一个同模式核心的间隔）
func _rebuild_mode_intervals() -> void:
	game.mode_intervals.clear()
	for t in game.core_types:
		game.mode_intervals[str(t["mode"])] = float(t["spread_interval"])

## 该类型当前实际攻击间隔：有覆盖取覆盖，否则按默认基础 × 类型倍率
func _turret_current_interval(type_name: String) -> float:
	if game.turret_interval_overrides.has(type_name):
		return float(game.turret_interval_overrides[type_name])
	return _default_effective_interval(type_name)

func _default_effective_interval(type_name: String) -> float:
	var stats: Dictionary = EnemyTurret.TURRET_TYPES.get(type_name, EnemyTurret.TURRET_TYPES["basic"])
	return game.enemy_attack_interval * float(stats["interval_mult"])

func _turret_type_label(type_name: String) -> String:
	return str(TURRET_TYPE_LABELS.get(type_name, type_name))
