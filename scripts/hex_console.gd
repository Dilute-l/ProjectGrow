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
var core_duration_spins: Array = []    # 与 core_types 下标一一对应（存活时间）
var default_core_durations: Array = [] # 每类核心的默认存活时间
var special_kind_option: OptionButton  # 特殊地块种类选择
var special_kind_ids: Array = []       # 与下拉项对应的种类 id
var special_auto_check: CheckBox       # 每场随机（测试布尔）开关
var special_counts_label: Label        # 本局持有/一次性 统计

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

	# —— 我方核心：每种核心的存活时间 ——
	vbox.add_child(section_label("—— 我方核心 · 存活时间（秒） ——"))
	core_duration_spins.clear()
	default_core_durations.clear()
	for i in range(game.core_types.size()):
		var t: Dictionary = game.core_types[i]
		var nm := str(t.get("name", "核心"))
		var val := float(t.get("duration", 15.0))
		default_core_durations.append(val)
		var sb := add_spin_row(vbox, nm, 0.5, 300.0, 0.5, val, false)
		core_duration_spins.append(sb)

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

	# —— 特殊地块：随机指定到可部署地块 ——
	vbox.add_child(section_label("—— 特殊地块 ——"))
	special_kind_ids.clear()
	special_kind_option = OptionButton.new()
	special_kind_option.custom_minimum_size = Vector2(200, 0)
	for kid in game.special_kind_defs.keys():
		special_kind_ids.append(str(kid))
		var kd: Dictionary = game.special_kind_defs[kid]
		special_kind_option.add_item(str(kd.get("name", kid)))
		special_kind_option.set_item_tooltip(special_kind_option.item_count - 1, str(kd.get("desc", "")))
	var st_row := HBoxContainer.new()
	st_row.add_theme_constant_override("separation", 8)
	vbox.add_child(st_row)
	st_row.add_child(special_kind_option)
	var st_btn := Button.new()
	st_btn.text = "随机指定到可部署地块"
	st_btn.pressed.connect(_on_special_designate_pressed)
	st_row.add_child(st_btn)
	# 每场随机（测试布尔）：开启后，每场战斗按战后/控制台获得次数随机出现特殊地块
	var auto_row := HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 8)
	vbox.add_child(auto_row)
	special_auto_check = CheckBox.new()
	special_auto_check.text = "每场随机：战后获得的地块每场随机出现（测试布尔）"
	special_auto_check.button_pressed = game.special_auto_every_battle
	special_auto_check.toggled.connect(_on_special_auto_toggled)
	auto_row.add_child(special_auto_check)
	var sim_btn := Button.new()
	sim_btn.text = "模拟战后获得 +1"
	sim_btn.pressed.connect(_on_special_simulate_pressed)
	auto_row.add_child(sim_btn)
	special_counts_label = Label.new()
	special_counts_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	special_counts_label.custom_minimum_size = Vector2(400, 0)
	special_counts_label.add_theme_color_override("font_color", Color("ffd166"))
	vbox.add_child(special_counts_label)
	var st_hint := Label.new()
	st_hint.text = "开启开关时：本局每获得 1 次该地块，之后每场随机出现 1 个（按战后卡次数累计）。关闭时：地块卡为一次性，仅下一场出现。模拟按钮=战后获得 +1（免通关即可测试）。\n「随机指定」按钮为当前场手动指定 1 格（每场重置后清空）。悬停地块可查看效果。"
	st_hint.add_theme_color_override("font_color", Color("9fb0cc"))
	st_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(st_hint)
	_refresh_special_counts()

	# 掉落效果（仅此处可授予）
	game.drop_effects.add_console_section(vbox)

	var hint := Label.new()
	hint.text = "均为“临时”数值：扩散间隔与存活时间写回当前局（存活时间只影响之后部署的新核心），炮台间隔对同类型全场生效并延续到之后的关卡。\n应用后生效；恢复默认还原 cores.json 加载值；按 R 或 Esc 关闭。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(440, 0)
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
	for i in range(core_duration_spins.size()):
		if i < game.core_types.size():
			core_duration_spins[i].value = float(game.core_types[i].get("duration", 15.0))
	for k in range(turret_interval_spins.size()):
		var type_name: String = turret_type_names[k]
		turret_interval_spins[k].value = _turret_current_interval(type_name)
	if special_auto_check != null:
		special_auto_check.button_pressed = game.special_auto_every_battle
	_refresh_special_counts()
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
	# 2) 每种核心的存活时间
	for i in range(core_duration_spins.size()):
		if i >= game.core_types.size():
			continue
		var val := float(core_duration_spins[i].value)
		game.core_types[i]["duration"] = val
	# 3) 每种炮台的攻击间隔（绝对秒数）
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
	for i in range(default_core_durations.size()):
		if i >= game.core_types.size():
			continue
		game.core_types[i]["duration"] = default_core_durations[i]
		core_duration_spins[i].value = default_core_durations[i]
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
	var stats: Dictionary = EnemyTurret.enemy_def(type_name)
	return game.enemy_attack_interval * float(stats["interval_mult"])

func _turret_type_label(type_name: String) -> String:
	return EnemyTurret.enemy_name(type_name)

func _on_special_designate_pressed() -> void:
	if special_kind_option == null or special_kind_ids.is_empty():
		return
	game.map_data.designate_special_tile(str(special_kind_ids[special_kind_option.selected]))

func _on_special_auto_toggled(on: bool) -> void:
	game.special_auto_every_battle = on
	game.hud.set_status(("已开启每场随机：战后获得的地块每场按次数随机出现" if on else "已关闭每场随机：战后获得的地块改为一次性（仅下一场）"))
	game.hud.update_status()
	_refresh_special_counts()

## 免通关测试：等价于在战后掉落里选了一次当前种类的地块卡
func _on_special_simulate_pressed() -> void:
	if special_kind_option == null or special_kind_ids.is_empty():
		return
	game.rewards.grant_tile(str(special_kind_ids[special_kind_option.selected]))
	_refresh_special_counts()

func _refresh_special_counts() -> void:
	if special_counts_label == null:
		return
	var parts: Array = []
	for kid in game.special_pool.keys():
		var nm := str(game.special_kind_defs.get(kid, {}).get("name", kid))
		parts.append("%s×%d(每场)" % [nm, int(game.special_pool[kid])])
	for kid in game.special_once.keys():
		var nm := str(game.special_kind_defs.get(kid, {}).get("name", kid))
		parts.append("%s×%d(一次性)" % [nm, int(game.special_once[kid])])
	special_counts_label.text = "本局地块统计：" + ("、".join(PackedStringArray(parts)) if not parts.is_empty() else "（无）")
