extends Node2D

## 六边形污染扩散 —— 玩法示例（框架）
##
## 本文件只保留框架：路径/默认值、颜色常量、枚举、运行时状态、以及生命周期
## （_ready / _process / _notification / _unhandled_input / _draw）与各模块的装配。
## 各模块的具体逻辑已拆分到 scripts/ 下的独立文件（通过组合而非继承协作）：
##   - hex_map.gd       数据加载 / 地图序列化 / 核心类型 / 行为模式注册
##   - hex_geometry.gd  布局与几何（居中、尺寸、坐标换算、边界/邻接）
##   - hex_draw.gd      绘制
##   - hex_deploy.gd    交互 / 部署（放置、移除、开始、复位）
##   - hex_spread.gd    污染与扩散、炮台损毁判定
##   - hex_turrets.gd   敌方炮台实例化与统计
##   - hex_tutorial.gd  新手教程
##   - hex_editor.gd    地图编辑器
##   - hex_hud.gd       HUD / 核心选择 / 状态文案
##   - hex_console.gd   控制台
##
## 地图从 level1.json 读取（半径、敌方炮台位置、墙）；核心类型从 cores.json 读取。
## 两种模式（Tab 或左上角按钮切换）：游玩模式 / 地图编辑模式。

# ---------------------------------------------------------------------------
# 路径与默认值
# ---------------------------------------------------------------------------
# 关卡列表（按顺序）；level_index 指向当前关卡
const LEVEL_PATHS: Array[String] = [
	"res://maps/level1.json",
	"res://maps/level2.json",
	"res://maps/level3.json",
	"res://maps/level4.json",
	"res://maps/test_turrets.json",
]
var level_index := 0
const CORES_PATH := "res://maps/cores.json"   # 核心数据文件

const HEX_SIZE_DEFAULT := 26.0              # 六边形中心到顶点的距离（像素，默认）
const ENEMY_ATTACK_INTERVAL_DEFAULT := 0.5  # 敌方攻击间隔（秒，默认）
const TURRET_ATTACK_RANGE := 3              # 炮台攻击范围（格），用于范围高亮
const FIRST_RUN_FLAG := "user://has_started.flag"  # 首次进入标记

# UI 缩放（随窗口大小变化）：以默认窗口 1152x648 为基准，窗口变大 UI 放大、变小则缩小
const UI_REF_WIDTH := 1600.0
const UI_REF_HEIGHT := 900.0
const UI_SCALE_MIN := 0.5
const UI_SCALE_MAX := 3.0
var ui_scale := 1.0

# 运行时数值（可在控制台修改）
var hex_size := HEX_SIZE_DEFAULT
var enemy_attack_interval := ENEMY_ATTACK_INTERVAL_DEFAULT
# 部署费用（玩家整体资源；初始值与上限定义在 PlayerCore）
var deploy_points := PlayerCore.DEPLOY_COST_START
# 战斗时间（秒）：RUNNING 阶段累积，用于「部署后前 N 秒」类掉落词条
var battle_time := 0.0

# 地图数据（从文件读取 / 编辑）
var map_radius := 0                            # 六边形地图半径（中心向外层数）
var walls: Dictionary = {}                    # Vector2i -> true
var turret_positions: Array[Vector2i] = []    # 所有敌方炮台位置
var turret_types: Dictionary = {}             # 炮台位置 -> 类型名（basic/sniper/rapid）
var turret_interval_overrides: Dictionary = {} # 类型名 -> 攻击间隔覆盖（秒；控制台临时平衡用，重建关卡时仍生效）

# 核心数据（从文件读取）
var core_types: Array = []     # 每个元素为 Dictionary：{id,name,mode,duration,spread_interval,color,unlocked_by_default}
# 解锁核心（局内）：新一局只解锁 cores.json 中 unlocked_by_default=true 的核心（默认「定向核心」），
# 其余核心作为通关掉落供玩家挑选（见 hex_rewards.gd）
var unlocked_core_ids: Array = []
var next_core_uid := 1            # 核心实例 uid 自增分配（污染地块归属标记用）

const COL_BG           := Color("0d1321")
const COL_TILE         := Color("243045")
const COL_TILE_HOVER   := Color("35476b")
const COL_POLLUTED     := Color("5f2fd6")
const COL_POLLUTED_HI  := Color("8a5cff")
const COL_UNIT         := Color("3fc1ff")
const COL_UNIT_RING    := Color("d7f3ff")
const COL_TURRET       := Color("ff5252")
const COL_TURRET_RING  := Color("ffd6d6")
const COL_TURRET_DEAD  := Color("4a2525")
const COL_WALL         := Color("2a303d")
const COL_WALL_EDGE    := Color("6b7688")
const COL_LINE         := Color(1.0, 1.0, 1.0, 0.10)

enum Phase { DEPLOY, RUNNING, WON, LOST }

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(-1, 1),
	Vector2i(0, 1), Vector2i(0, -1),
]

var phase := Phase.DEPLOY
# units: Vector2i -> PlayerCore 节点（我方可部署核心，每颗 = 一个场景实例）
var units: Dictionary = {}
var polluted: Dictionary = {}               # 所有被污染地块：Vector2i -> {mode,dir}
var core_container: Node2D               # 我方核心场景实例容器
var turret_map: Dictionary = {}            # Vector2i -> EnemyTurret 节点
var turret_container: Node2D               # 敌方炮台场景实例容器
var mode_spread_timers: Dictionary = {}    # 模式名 -> 该模式扩散累计秒数
var mode_intervals: Dictionary = {}        # 模式名 -> 该模式扩散间隔（秒）
var hover_cell := Vector2i(999999, 999999)
var map_offset := Vector2.ZERO
var total_hexes := 0

# 核心选择与定向部署
var selected_core := -1  # -1 = 尚未选择核心类型
var awaiting_direction := false
var pending_cell := Vector2i.ZERO
var pending_type := 0

var tutorial_active := false   # 新手教程是否正在播放（期间屏蔽游戏交互）
var tutorial_node: Tutorial = null
var tutorial_gate := ""          # 教程门槛："" | "deploy" | "attack"
var tutorial_spotlight := ""     # 教程聚光灯："" | "core" | "map"
var core_selector_panel: PanelContainer = null

# 控制台
var console_open := false
var console_layer: CanvasLayer
# 本局词条总览弹窗是否打开（打开时暂停游戏并屏蔽输入）
var buff_overview_open := false

var status_label: Label
var start_button: Button
var core_buttons: Array[Button] = []
var core_selector_layer: CanvasLayer
var hud_layer: CanvasLayer

# 关卡奖励界面（通关后弹出：3 选 1 掉落；继续按钮 = 跳过本次掉落）
var reward_layer: CanvasLayer
var reward_title: Label
var reward_cards_box: HBoxContainer
var reward_continue_button: Button
# 专属词条的承载核心选择（选完 buff 掉落卡后弹出）
var unique_layer: CanvasLayer
var unique_title: Label
var unique_box: VBoxContainer
var _pending_unique_effect := ""

# 暂停与倍速（UI 在右上角）
const SPEED_LEVELS: Array[float] = [1.0, 2.0, 4.0]
var paused := false
var speed_index := 0
var game_speed := 1.0
var game_controls_layer: CanvasLayer
var pause_button: Button
var speed_button: Button

# 部署费用条（位于核心类型选择区上方）
var cost_bar: ProgressBar
var cost_value_label: Label

# 地图编辑器
enum Mode { PLAY, EDIT }
var mode := Mode.PLAY
var editor_brush := 0              # 0=墙, 1=炮台
var editor_layer: CanvasLayer
var mode_button: Button
var radius_label: Label
var wall_btn: Button
var turret_btn: Button
var file_dialog: FileDialog
var file_dialog_purpose := 0       # 0=导入, 1=导出

# ---------------------------------------------------------------------------
# 模块装配（组合：每个模块持有一个指向本节点的 game 引用）
# ---------------------------------------------------------------------------
var map_data: HexMap
var geometry: HexGeometry
var drawer: HexDraw
var deploy: HexDeploy
var guide: HexTutorial
var editor: HexEditor
var spread: HexSpread
var turrets: HexTurrets
var hud: HexHud
var console: HexConsole
var drop_effects: DropEffects
var rewards: HexRewards

func _create_modules() -> void:
	map_data = HexMap.new(self)
	geometry = HexGeometry.new(self)
	drawer = HexDraw.new(self)
	deploy = HexDeploy.new(self)
	guide = HexTutorial.new(self)
	editor = HexEditor.new(self)
	spread = HexSpread.new(self)
	turrets = HexTurrets.new(self)
	hud = HexHud.new(self)
	console = HexConsole.new(self)
	drop_effects = DropEffects.new(self)
	rewards = HexRewards.new(self)

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------
func _ready() -> void:
	_create_modules()
	map_data.load_map()
	map_data.load_cores()
	map_data.register_core_modes()
	rewards.reset_run()   # 新一局：只解锁默认核心（定向）
	selected_core = clampi(selected_core, -1, core_types.size() - 1)
	geometry.fit_hex_size()
	geometry.recenter()
	hud.build_hud()
	console.build_console()
	hud.build_core_selector()
	hud.build_buff_overview()
	editor.build_editor_ui()
	editor.build_file_dialog()
	_build_reward_screen()
	_build_unique_target_screen()
	_build_game_controls()
	_update_ui_scale()
	deploy.reset()
	queue_redraw()
	guide.check_first_run()
	# 窗口尺寸变化时，自动重算地图大小与位置
	get_viewport().size_changed.connect(_on_viewport_size_changed)

func _process(delta: float) -> void:
	if paused:
		return
	if tutorial_active:
		return
	if console_open:
		return
	if buff_overview_open:
		return  # 词条总览打开时暂停游戏
	if mode != Mode.PLAY:
		return
	if phase != Phase.RUNNING:
		return
	delta *= game_speed  # 倍速
	battle_time += delta
	# 1) 核心倒计时（到期后核心消失，但其污染地块保留）
	var expired: Array = []
	for cell in units.keys():
		var n: PlayerCore = units[cell]
		if n.advance(delta):
			expired.append(cell)
	for cell in expired:
		var n: PlayerCore = units.get(cell)
		if n != null:
			var burst := n.burst_cells()
			if not burst.is_empty():
				spread.burst_from(cell, burst, n.mode(), str(n.config.get("id", "")), n.spawn_time)
		deploy.remove_core(cell)
	# 2) 所有核心已结束：停止蔓延；若仍有存活炮台则失败
	if units.is_empty():
		if turrets.alive_count() > 0:
			phase = Phase.LOST
		hud.update_status()
		queue_redraw()
		return
	# 3)+4) 各模式扩散：有该模式的存活核心，就按该模式间隔蔓延其污染地块
	var active_modes: Dictionary = {}
	for n in units.values():
		active_modes[n.mode()] = true
	for m in active_modes:
		var bm := CoreMode.for_mode(m)
		if bm == null:
			continue
		var iv: float = mode_intervals.get(m, bm.interval_fallback()) * drop_effects.spread_interval_multiplier(m)
		mode_spread_timers[m] = mode_spread_timers.get(m, 0.0) + delta
		if mode_spread_timers[m] >= iv:
			mode_spread_timers[m] = 0.0
			spread.spread_mode(m, bm)
	# 5) 炮台摧毁 / 胜利判定
	spread.check_turret_destruction()
	if phase == Phase.WON and reward_layer != null and not reward_layer.visible:
		_show_reward_screen()
	if phase != Phase.RUNNING:
		hud.update_status()
		queue_redraw()
		return
	# 6) 敌方攻击（每个存活炮台独立计时）
	var attacked := false
	for t in turret_map.values():
		if t.tick(delta, polluted, units, {}, {}, drop_effects, battle_time):
			attacked = true
			queue_redraw()
	if attacked and tutorial_gate == "attack":
		guide.on_attack()
	if units.is_empty() and turrets.alive_count() > 0:
		phase = Phase.LOST
	spread.free_orphan_cores()
	hud.update_status()
	queue_redraw()

func _on_viewport_size_changed() -> void:
	geometry.fit_hex_size()
	geometry.recenter()
	_update_ui_scale()
	_update_cores_layout()
	guide.update_spotlight()
	queue_redraw()

## 窗口/地图尺寸变化时，同步各核心节点的渲染位置
func _update_cores_layout() -> void:
	for n: PlayerCore in units.values():
		n.update_layout(hex_size, map_offset)

# ---------------------------------------------------------------------------
# UI 缩放
# ---------------------------------------------------------------------------
func _update_ui_scale() -> void:
	var vs := get_viewport_rect().size
	var s := clampf(minf(vs.x / UI_REF_WIDTH, vs.y / UI_REF_HEIGHT), UI_SCALE_MIN, UI_SCALE_MAX)
	ui_scale = s
	# 各 UI 层按各自锚点缩放：scale + offset 使锚定位置（左上/顶中/居中/右下）保持不变
	_set_layer_transform(hud_layer, s, Vector2.ZERO)
	_set_layer_transform(editor_layer, s, Vector2(vs.x * (1.0 - s) * 0.5, 0.0))
	_set_layer_transform(console_layer, s, Vector2(vs.x * (1.0 - s) * 0.5, vs.y * (1.0 - s) * 0.5))
	_set_layer_transform(core_selector_layer, s, Vector2(vs.x * (1.0 - s), vs.y * (1.0 - s)))
	_set_layer_transform(game_controls_layer, s, Vector2(vs.x * (1.0 - s), 0.0))
	_set_layer_transform(reward_layer, s, Vector2(vs.x * (1.0 - s) * 0.5, vs.y * (1.0 - s) * 0.5))
	# 教程层（若正在播放）也按居中锚点缩放
	if tutorial_node != null and is_instance_valid(tutorial_node):
		_set_layer_transform(tutorial_node, s, Vector2(vs.x * (1.0 - s) * 0.5, vs.y * (1.0 - s) * 0.5))

func _set_layer_transform(layer: CanvasLayer, s: float, offset: Vector2) -> void:
	if layer == null:
		return
	layer.scale = Vector2(s, s)
	layer.offset = offset

## 核心选择区面板在屏幕上的矩形（已按 UI 缩放换算，供教程聚光灯使用）
func core_selector_screen_rect() -> Rect2:
	if core_selector_panel == null:
		return Rect2()
	var vs := get_viewport_rect().size
	var s := ui_scale
	var off := Vector2(vs.x * (1.0 - s), vs.y * (1.0 - s))
	return Rect2(core_selector_panel.global_position * s + off, core_selector_panel.size * s).grow(14.0 * s)

# ---------------------------------------------------------------------------
# 关卡奖励界面（通关后弹出 3 选 1 掉落；点卡片领取，继续 = 跳过）
# 候选内容与领取逻辑在 hex_rewards.gd（支持 core 解锁 / buff 词条等多种掉落类型）
# ---------------------------------------------------------------------------
func _build_reward_screen() -> void:
	reward_layer = CanvasLayer.new()
	reward_layer.layer = 25
	reward_layer.visible = false
	add_child(reward_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	reward_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_STOP
	reward_layer.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	reward_title = Label.new()
	reward_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reward_title.add_theme_font_size_override("font_size", 30)
	vbox.add_child(reward_title)

	var sub := Label.new()
	sub.text = "选择你的奖励（3 选 1，点击即领取）"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", Color("9fb0cc"))
	vbox.add_child(sub)

	reward_cards_box = HBoxContainer.new()
	reward_cards_box.add_theme_constant_override("separation", 14)
	reward_cards_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(reward_cards_box)

	reward_continue_button = Button.new()
	reward_continue_button.text = "继续 ▸（跳过本次掉落）"
	reward_continue_button.pressed.connect(_on_reward_continue)
	vbox.add_child(reward_continue_button)

func _show_reward_screen() -> void:
	if reward_title != null:
		reward_title.text = "第 %d 关完成！" % (level_index + 1)
	# 重建候选卡片
	for child in reward_cards_box.get_children():
		reward_cards_box.remove_child(child)
		child.queue_free()
	var options: Array = rewards.build_options()
	if options.is_empty():
		var hint := Label.new()
		hint.text = "（所有核心与词条都已拥有，无掉落可选）"
		hint.add_theme_color_override("font_color", Color("9fb0cc"))
		reward_cards_box.add_child(hint)
	for opt in options:
		reward_cards_box.add_child(_make_reward_card(opt))
	if reward_layer != null:
		reward_layer.visible = true

func _make_reward_card(opt: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(200, 216)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.tooltip_text = str(opt.get("desc", ""))
	card.gui_input.connect(_on_card_input.bind(opt))
	var col: Color = opt.get("color", Color.WHITE)
	var style := StyleBoxFlat.new()
	style.bg_color = col.darkened(0.78)
	style.border_color = col
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	card.add_theme_stylebox_override("panel", style)

	var cm := MarginContainer.new()
	cm.add_theme_constant_override("margin_left", 10)
	cm.add_theme_constant_override("margin_top", 10)
	cm.add_theme_constant_override("margin_right", 10)
	cm.add_theme_constant_override("margin_bottom", 10)
	card.add_child(cm)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	cm.add_child(box)

	var title := Label.new()
	title.text = str(opt.get("title", "?"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", col.lightened(0.25))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	var sub := Label.new()
	sub.text = str(opt.get("sub", ""))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color("cfe0ff"))
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(sub)

	var desc := Label.new()
	desc.text = str(opt.get("desc", ""))
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color("9fb0cc"))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 56)
	box.add_child(desc)

	var tag := Label.new()
	tag.text = "点击领取"
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.add_theme_font_size_override("font_size", 12)
	tag.add_theme_color_override("font_color", col)
	box.add_child(tag)
	return card

func _on_card_input(ev: InputEvent, opt: Dictionary) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var kind := str(opt.get("kind", ""))
		# 专属词条：先弹出“选择承载核心”，选择后才真正授予并进入下一关
		if kind == "buff" and rewards.is_unique_effect(str(opt.get("id", ""))):
			_open_unique_target(opt)
			return
		rewards.apply_option(opt)
		_advance_after_reward()

## 专属词条：弹出选择“作用于哪一颗核心”的界面（列出所有已解锁核心）
func _open_unique_target(opt: Dictionary) -> void:
	_pending_unique_effect = str(opt.get("id", ""))
	if unique_layer == null:
		return
	if unique_title != null:
		unique_title.text = "选择承载核心：获得「%s」" % str(opt.get("title", "词条"))
	for ch in unique_box.get_children():
		unique_box.remove_child(ch)
		ch.queue_free()
	var added := false
	for i in range(core_types.size()):
		if not rewards.is_type_unlocked(i):
			continue
		added = true
		var t: Dictionary = core_types[i]
		var col: Color = map_data.core_color(t)
		var btn := Button.new()
		btn.text = "【%s】%s" % [str(t.get("name", "核心")), str(t.get("id", ""))]
		btn.custom_minimum_size = Vector2(240, 0)
		btn.add_theme_color_override("font_color", col.lightened(0.15))
		btn.pressed.connect(_on_unique_core_chosen.bind(i))
		unique_box.add_child(btn)
	if not added:
		var lbl := Label.new()
		lbl.text = "（暂无已解锁核心）"
		lbl.add_theme_color_override("font_color", Color("9fb0cc"))
		unique_box.add_child(lbl)
	unique_layer.visible = true

func _on_unique_core_chosen(type_idx: int) -> void:
	if _pending_unique_effect != "":
		rewards.grant_unique_buff(_pending_unique_effect, type_idx)
	_pending_unique_effect = ""
	if unique_layer != null:
		unique_layer.visible = false
	_hide_reward_screen()
	_advance_after_reward()

func _on_unique_cancel() -> void:
	_pending_unique_effect = ""
	if unique_layer != null:
		unique_layer.visible = false

## 构建“专属词条 → 选择承载核心”弹窗层
func _build_unique_target_screen() -> void:
	unique_layer = CanvasLayer.new()
	unique_layer.layer = 26
	unique_layer.visible = false
	add_child(unique_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.66)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	unique_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	unique_layer.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	unique_title = Label.new()
	unique_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	unique_title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(unique_title)

	var note := Label.new()
	note.text = "专属词条只会作用于你选择的这一颗核心（本局内）。"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_color_override("font_color", Color("9fb0cc"))
	vbox.add_child(note)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420, 220)
	vbox.add_child(scroll)
	unique_box = VBoxContainer.new()
	unique_box.add_theme_constant_override("separation", 6)
	scroll.add_child(unique_box)

	var cancel_btn := Button.new()
	cancel_btn.text = "取消（返回掉落选择）"
	cancel_btn.pressed.connect(_on_unique_cancel)
	vbox.add_child(cancel_btn)

func _hide_reward_screen() -> void:
	if reward_layer != null:
		reward_layer.visible = false

## 领取奖励后 / 点继续（跳过）：进入下一关；最后一关之后回到第一关（循环）
func _advance_after_reward() -> void:
	level_index = (level_index + 1) % LEVEL_PATHS.size()
	_load_level(level_index)
	_hide_reward_screen()

func _on_reward_continue() -> void:
	_advance_after_reward()

## 加载指定关卡并复位游戏到部署阶段
func _load_level(idx: int) -> void:
	level_index = idx
	map_data.load_map()
	geometry.fit_hex_size()
	geometry.recenter()
	deploy.reset()
	queue_redraw()

# ---------------------------------------------------------------------------
# 暂停与倍速（右上角 UI）
# ---------------------------------------------------------------------------
func _build_game_controls() -> void:
	game_controls_layer = CanvasLayer.new()
	game_controls_layer.layer = 10
	add_child(game_controls_layer)

	var panel := PanelContainer.new()
	game_controls_layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	margin.add_child(hbox)

	speed_button = Button.new()
	speed_button.text = "1x"
	speed_button.pressed.connect(_cycle_speed)
	hbox.add_child(speed_button)

	pause_button = Button.new()
	pause_button.text = "暂停"
	pause_button.pressed.connect(_toggle_pause)
	hbox.add_child(pause_button)

	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)

func _toggle_pause() -> void:
	paused = not paused
	if pause_button != null:
		pause_button.text = "继续" if paused else "暂停"
	if paused:
		hud.set_status("已暂停（右上角可继续 / 调速）")
	else:
		hud.update_status()
	queue_redraw()

func _cycle_speed() -> void:
	speed_index = (speed_index + 1) % SPEED_LEVELS.size()
	game_speed = SPEED_LEVELS[speed_index]
	if speed_button != null:
		speed_button.text = str(int(game_speed)) + "x"

func _unhandled_input(event: InputEvent) -> void:
	if reward_layer != null and reward_layer.visible:
		return  # 奖励界面弹出时屏蔽游戏输入
	if paused:
		return  # 暂停时屏蔽游戏输入（右上角按钮仍可用）
	if buff_overview_open:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			hud.close_buff_overview()
		return  # 词条总览打开时屏蔽游戏输入
	if tutorial_active:
		return
	if tutorial_gate == "deploy" and event is InputEventKey:
		return  # 部署等待期间屏蔽键盘，只允许鼠标放置
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R:
			if console_open:
				console.close()
			else:
				console.open()
			return
		if event.keycode == KEY_ESCAPE:
			if console_open:
				console.close()
			return
		if event.keycode == KEY_TAB:
			editor.toggle_mode()
			return
	if console_open:
		return
	if mode == Mode.EDIT:
		editor.handle_input(event)
		return
	if event is InputEventMouseMotion:
		hover_cell = geometry.pixel_to_hex(event.position)
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		var cell := geometry.pixel_to_hex(event.position)
		if phase == Phase.DEPLOY or phase == Phase.RUNNING:
			if awaiting_direction:
				if event.button_index == MOUSE_BUTTON_LEFT:
					if geometry.is_neighbor(cell, pending_cell):
						deploy.finalize_directional(cell)
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					awaiting_direction = false
					hud.update_status()
					queue_redraw()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				deploy.try_place(cell)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				deploy.try_remove(cell)
	elif event is InputEventKey and event.pressed:
		# 数字键选择核心类型（与右下角 UI 同步）
		for i in range(core_types.size()):
			if event.keycode == KEY_1 + i:
				hud.select_core(i)
				return
		if (event.keycode == KEY_SPACE or event.keycode == KEY_ENTER) and phase == Phase.DEPLOY:
			deploy.start()

func _draw() -> void:
	drawer.draw()
