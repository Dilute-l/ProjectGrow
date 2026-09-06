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
##   - hex_level_select.gd 随机关卡：读每关 difficulty，按已通关数随机指定下一关
##
## 地图从 level1.json 读取（半径、敌方炮台位置、墙）；核心类型从 cores.json 读取。
## 两种模式（Tab 或左上角按钮切换）：游玩模式 / 地图编辑模式。

# ---------------------------------------------------------------------------
# 路径与默认值
# ---------------------------------------------------------------------------
# 关卡列表（按顺序，供编辑器/随机选关使用）；level_index 指向当前关卡
const LEVEL_PATHS: Array[String] = [
	"res://maps/level0.json",
	"res://maps/level1.json",
	"res://maps/level2.json",
	"res://maps/level3.json",
	"res://maps/level4.json",
	"res://maps/level5.json",
	"res://maps/level6.json",
	"res://maps/level7.json",
	"res://maps/level8.json",
	"res://maps/level9.json",
	"res://maps/level10.json",
	# 拓展关卡（难度 11；主线 BOSS 通关后随机进入）
	"res://maps/level-1.json",
	"res://maps/level-2.json",
	"res://maps/leveljb.json",
	"res://maps/levelmi.json",
]
var level_index := 0
# 本局已通关数（随机关卡选关的“完成总关卡数”；每通关一关 +1，新一局清零）
var cleared_levels := 0
# 失败宽限计时：失败条件满足后累计满 0.5 秒才判负（避免核心与最后敌人同时消失时误判）
var lose_grace := 0.0
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
# 特殊地块：定义来自 maps/special_tiles.json；special_tiles = 地块 -> 种类 id
var special_kind_defs: Dictionary = {}     # id -> 定义（name/desc/color/效果参数…）
var special_tiles: Dictionary = {}         # Vector2i -> 种类 id（当前关卡内已指定，可多次指定）
# —— 特殊地块 · 每场随机（测试布尔）——
# special_auto_every_battle = true：本局在战后获得的特殊地块按「获得次数」每场随机出现；
# false：战后获得的地块卡为一次性（仅下一场出现，随后清空）。
var special_auto_every_battle := false
# 本局战后获得的地块（开启开关后：每场按次数随机出现）：kind_id -> 次数
var special_pool: Dictionary = {}
# 一次性地块（关闭开关时战后获得）：kind_id -> 次数；只作用于下一场，应用后清空
var special_once: Dictionary = {}

# 核心数据（从文件读取）
var core_types: Array = []     # 每个元素为 Dictionary：{id,name,mode,duration,spread_interval,color,unlocked_by_default}
# 解锁核心（局内）：新一局只解锁 cores.json 中 unlocked_by_default=true 的核心（默认「傲慢之眼」），
# 其余核心作为通关掉落供玩家挑选（见 hex_rewards.gd）
var unlocked_core_ids: Array = []
var upgraded_core_ids: Array = []   # 本局已升级过的核心 id（每种核心至多升级一次）
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
var turret_container: Node2D               # 敌方炮台场景实例容器（逻辑节点，不绘制）
var turret_overlay: TurretOverlay          # 敌方炮台覆盖层（独立绘制，最高图层）
# 每颗核心独立的扩散计时（cell -> 累计秒数）：取代旧的模式级 mode_spread_timers，
# 使加速/急速之地等效果只作用于“坐在该地块/被点选”的那一颗核心。
var core_spread_timers: Dictionary = {}
# 模式级扩散间隔（秒；由 cores.json / 控制台维护，作为每颗核心的基准间隔）
var mode_spread_timers: Dictionary = {}    # 兼容旧字段：扩散重置时一并清空（不再用于计时）
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
var core_buttons: Array = []
var core_selector_layer: CanvasLayer
var core_info_layer: CanvasLayer
var hud_layer: CanvasLayer

# 关卡奖励界面（通关后弹出；掉落队列逐项弹出：必定掉落 → 概率掉落(30%)）
# 候选内容与领取逻辑在 hex_rewards.gd（支持 core 解锁 / buff 词条 / tile 地块）
var reward_layer: CanvasLayer
var reward_title: Label
var reward_sub_label: Label
var reward_cards_box: HBoxContainer
var reward_continue_button: Button
# 本次 WON 的掉落队列（由 rewards.build_drop_queue() 生成）与当前下标
var _reward_queue: Array = []
var _reward_queue_idx := 0
# 专属词条的承载核心选择（选完 buff 掉落卡后弹出）
var unique_layer: CanvasLayer
var unique_title: Label
var unique_box: VBoxContainer
var _pending_unique_effect := ""

# 暂停与倍速（UI 在右上角）
const SPEED_LEVELS: Array[float] = [1.0, 2.0, 4.0]
# 右上角 GUI 场景与图标（scenes/gui.tscn / images/GUI）：倍速档位 1x/2x/4x，暂停/继续
const GUI_SCENE := preload("res://scenes/gui.tscn")
const GUI_SPEED_NODE := "Speed"     # gui.tscn 中倍速按钮节点名（icon 初始为 1x.png）
const GUI_PAUSE_NODE := "Pause"     # gui.tscn 中暂停按钮节点名（icon 初始为 pause.png）
const GUI_SETTINGS_NODE := "Settings"  # gui.tscn 中设置按钮节点名（点击 = 呼出 ESC 暂停/设置菜单）
const GUI_RESET_NODE := "Reset"        # gui.tscn 中“重置”按钮节点名（icon 为 Reset.png）
const ICON_1X := preload("res://images/GUI/1x.png")
const ICON_2X := preload("res://images/GUI/2x.png")
const ICON_4X := preload("res://images/GUI/4x.png")
const ICON_PAUSE := preload("res://images/GUI/pause.png")
const ICON_CONTINUE := preload("res://images/GUI/continue.png")
# 道具栏（右上角 · 键位提示下方）：整体放大倍数（约 1.5~2 倍，取 1.75）、与键位标签的间距
const ITEM_BAR_SCALE := 1.75
const ITEM_BAR_GAP := 12.0
var paused := false
var speed_index := 0
var game_speed := 1.0
var game_controls_layer: CanvasLayer
var pause_button: Button
var speed_button: Button
var settings_button: Button
var reset_button: Button
# 顶部中央关卡指示：主线显示“第 X 关”；通关主线后（cleared_levels >= MAIN_LINE_LEVELS）进入无尽模式
const MAIN_LINE_LEVELS := 11   # 主线关卡数（level0~level10 共 11 个）
var level_indicator_layer: CanvasLayer
var level_indicator_label: Label
# 暂停菜单（ESC 打开）：变暗遮罩 + 继续游戏 / 重置 / 编辑模式 / 回到主菜单
var pause_menu_open := false
var pause_menu_layer: CanvasLayer
var edit_mode_button: Button   # 暂停菜单中的“编辑模式/游玩模式”切换按钮
# 音量设置（ESC 暂停菜单中的滑块；0.0 ~ 1.0）
var volume_master := 1.0
# 音乐默认 -10dB（与 VolumeSettings.MUSIC_DEFAULT 一致；实际值启动时由 volume.cfg 决定）
var volume_music := 0.3162277660168379
var volume_sfx := 1.0

# 部署费用条（位于核心类型选择区上方）
var cost_bar: ProgressBar
var cost_value_label: Label

# 地图编辑器
enum Mode { PLAY, EDIT }
var mode := Mode.PLAY
var editor_brush := 0              # 0=墙, 1=炮台
var editor_turret_type := "basic"  # 地图编辑器当前选择的炮台种类（basic/sniper/rapid/beam/sweeper/mortar）
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
var level_select: HexLevelSelect
var items: HexItems
var core_selector_ui: CoreSelectorUI

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
	level_select = HexLevelSelect.new(self)
	items = HexItems.new(self)
	core_selector_ui = CoreSelectorUI.new(self)

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------
func _ready() -> void:
	_create_modules()
	_ensure_audio_buses()           # 建立 Music / SFX 总线，并挂接 BGM / SpreadSE
	_load_volume_settings()         # 读取并应用上次保存的音量
	EnemyTurret.load_enemy_defs()   # 从 maps/enemies.json 加载敌方炮台类型（数值 + 中文名）
	Tutorial.load_enemy_stages()    # 提前加载敌人首次遭遇台词（供关卡切换时检测新敌人）
	map_data.load_map()
	map_data.load_cores()
	map_data.register_core_modes()
	map_data.load_special_tiles()
	rewards.reset_run()   # 新一局：只解锁默认核心（定向）
	items.reset_run()     # 新一局：清空一次性道具库存
	cleared_levels = 0    # 新一局：已通关数清零（随机关卡选关依据）
	selected_core = clampi(selected_core, -1, core_types.size() - 1)
	geometry.fit_hex_size()
	geometry.recenter()
	hud.build_hud()
	console.build_console()
	core_selector_ui.build()
	hud.build_buff_overview()
	editor.build_editor_ui()
	editor.build_file_dialog()
	_build_reward_screen()
	_build_unique_target_screen()
	_build_game_controls()
	_build_pause_menu()
	_build_level_indicator()
	_update_level_indicator()
	_update_ui_scale()
	# 图层顺序（z_index）：触手 GroundOverlay(0) < 我方核心 PlayerCores(10) < 敌方炮台 TurretOverlay(20)
	var ground := get_node("GroundOverlay")
	if ground != null:
		ground.z_index = 0
	turret_overlay = TurretOverlay.new()
	turret_overlay.name = "TurretOverlay"
	turret_overlay.z_index = 20
	add_child(turret_overlay)
	deploy.reset()
	queue_redraw()
	guide.check_first_run()
	# 开局默认进入暂停（而非停留在等待部署状态）
	_set_paused(true)
	# 窗口尺寸变化时，自动重算地图大小与位置
	get_viewport().size_changed.connect(_on_viewport_size_changed)

func _process(delta: float) -> void:
	if paused:
		return
	if pause_menu_open:
		return  # 暂停菜单打开时暂停游戏
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
				$SpreadSE.play()   # 自爆核心到期爆发：复用蔓延音效播放爆发声
			# 核心耗尽：从 units 移除、节点变暗保留（污染地块仍在）
			units.erase(cell)
			n.mark_corpse()
	# 2) 各核心独立扩散：每颗存活核心各自计时、只蔓延自己的树（owner==uid）。
	# 间隔 = 该模式基准间隔 × 该核心词条乘数 × 所在格特殊地块 × 道具急速增殖。
	for cell in units.keys():
		var n: PlayerCore = units[cell]
		var m := n.mode()
		var bm := CoreMode.for_mode(m)
		if bm == null:
			continue
		var iv: float = drop_effects.spread_interval_for(m, bm.interval_fallback()) \
				* drop_effects.spread_interval_multiplier_for_core(n) \
				* _core_terrain_interval_factor(n)
		if items != null:
			iv *= items.spread_interval_factor_for_core(n)
		core_spread_timers[cell] = core_spread_timers.get(cell, 0.0) + delta
		if core_spread_timers[cell] >= iv:
			core_spread_timers[cell] = 0.0
			spread.spread_core(int(n.uid), m, bm)
			$SpreadSE.play()
	# 5) 炮台摧毁 / 胜利判定
	spread.check_turret_destruction()
	if phase == Phase.WON and reward_layer != null and not reward_layer.visible:
		_show_reward_screen()
	if phase != Phase.RUNNING:
		hud.update_status()
		queue_redraw()
		return
	# 5.5) 道具计时（如炮台减速剩余时间；到期恢复原攻击间隔）
	if items != null:
		items.tick(delta)
	# 6) 敌方攻击（每个存活炮台独立计时）
	var attacked := false
	for t in turret_map.values():
		if t.tick(delta, polluted, units, {}, {}, drop_effects, battle_time):
			attacked = true
			queue_redraw()
	if attacked and tutorial_gate == "attack":
		guide.on_attack()
	# 失败判定：满足失败条件后累计满 0.5 秒才判负，避免核心与最后敌人同时消失时误判
	if _should_lose():
		lose_grace += delta
		if lose_grace >= 0.5:
			phase = Phase.LOST
	else:
		lose_grace = 0.0
	spread.free_orphan_cores()
	hud.update_status()
	queue_redraw()

## 失败条件：场上没有存活核心，且部署点数不足以部署任何已解锁核心（且仍有存活炮台）
func _should_lose() -> bool:
	if not units.is_empty():
		return false
	if turrets.alive_count() == 0:
		return false  # 没有存活炮台（此时应已判胜）
	for i in range(core_types.size()):
		if rewards.is_type_unlocked(i) and deploy_points >= drop_effects.deploy_cost(i):
			return false  # 还有至少一个已解锁核心可部署
	return true

## 该核心所在格的特殊地块对蔓延间隔的倍率（只作用于坐上去的这一颗；例如「急速之地」）
func _core_terrain_interval_factor(n: PlayerCore) -> float:
	var kid := str(special_tiles.get(n.coord, ""))
	if kid == "":
		return 1.0
	var def: Dictionary = special_kind_defs.get(kid, {})
	if def.has("spread_mult"):
		return float(def["spread_mult"])
	return 1.0

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
	_set_layer_transform(core_info_layer, s, Vector2(0.0, vs.y * (1.0 - s)))
	_set_layer_transform(game_controls_layer, s, Vector2(vs.x * (1.0 - s), 0.0))
	_set_layer_transform(reward_layer, s, Vector2(vs.x * (1.0 - s) * 0.5, vs.y * (1.0 - s) * 0.5))
	_set_layer_transform(pause_menu_layer, s, Vector2(vs.x * (1.0 - s) * 0.5, vs.y * (1.0 - s) * 0.5))
	# 顶部中央关卡指示：按顶中锚点缩放
	_set_layer_transform(level_indicator_layer, s, Vector2(vs.x * (1.0 - s) * 0.5, 0.0))
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
# 关卡奖励界面（通关后按“掉落队列”逐项弹出；点卡片领取，继续 = 跳过剩余）
# 掉落队列由 hex_rewards.build_drop_queue() 生成：第 1 项必定掉落，第 2 项概率掉落(30%)
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

	reward_sub_label = Label.new()
	reward_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reward_sub_label.add_theme_font_size_override("font_size", 16)
	reward_sub_label.add_theme_color_override("font_color", Color("9fb0cc"))
	vbox.add_child(reward_sub_label)

	reward_cards_box = HBoxContainer.new()
	reward_cards_box.add_theme_constant_override("separation", 14)
	reward_cards_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(reward_cards_box)

	reward_continue_button = Button.new()
	reward_continue_button.text = "跳过 ▸"
	reward_continue_button.pressed.connect(_on_reward_continue)
	vbox.add_child(reward_continue_button)

## 通关后入口：构建掉落队列并展示第 1 项
func _show_reward_screen() -> void:
	_reward_queue = rewards.build_drop_queue()
	_reward_queue_idx = 0
	_render_reward_item()

## 渲染当前掉落项；队列为空则显示“无掉落”提示
func _render_reward_item() -> void:
	if reward_title == null:
		return
	for child in reward_cards_box.get_children():
		reward_cards_box.remove_child(child)
		child.queue_free()
	if _reward_queue_idx < 0 or _reward_queue_idx >= _reward_queue.size():
		# 空队列（理论上所有候选都已被拿完）
		reward_title.text = "第 %d 关完成！" % (cleared_levels + 1)
		reward_sub_label.text = "（没有可用掉落，继续进入下一关）"
		reward_continue_button.text = "继续 ▸ 下一关"
		if reward_layer != null:
			reward_layer.visible = true
		return
	var item: Dictionary = _reward_queue[_reward_queue_idx]
	# var prefix := "必定掉落" if bool(item.get("guaranteed", true)) else "概率掉落"
	reward_title.text = "第 %d 关完成" % [cleared_levels + 1]
	reward_sub_label.text = "选择你的奖励"
	var options: Array = item.get("options", [])
	if options.is_empty():
		var hint := Label.new()
		hint.text = "（该类候选已无可选项）"
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
	var kind := str(opt.get("kind", ""))
	var is_upgrade := kind == "upgrade"
	var hl := Color("ffd166")
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
	title.add_theme_color_override("font_color", hl if is_upgrade else col.lightened(0.25))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	var sub := Label.new()
	sub.text = str(opt.get("sub", ""))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color("cfe0ff"))
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(sub)

	# 升级卡用 RichTextLabel 以支持 BBCode 高亮变化数值；其余卡保持普通 Label
	var desc: Control
	if is_upgrade:
		var rtl := RichTextLabel.new()
		rtl.bbcode_enabled = true
		rtl.text = str(opt.get("desc_bbcode", ""))
		rtl.fit_content = true
		rtl.scroll_active = false
		rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rtl.add_theme_font_size_override("normal_font_size", 13)
		rtl.add_theme_color_override("default_color", Color("9fb0cc"))
		rtl.custom_minimum_size = Vector2(0, 56)
		desc = rtl
	else:
		var lbl := Label.new()
		lbl.text = str(opt.get("desc", ""))
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color("9fb0cc"))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(0, 56)
		desc = lbl
	box.add_child(desc)

	# 升级卡：在描述末尾用高亮色追加升级效果
	if is_upgrade:
		var eff := Label.new()
		eff.text = str(opt.get("upgrade_text", ""))
		eff.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		eff.add_theme_font_size_override("font_size", 13)
		eff.add_theme_color_override("font_color", hl)
		eff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(eff)

	var tag := Label.new()
	tag.text = "点击升级" if is_upgrade else "点击领取"
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.add_theme_font_size_override("font_size", 12)
	tag.add_theme_color_override("font_color", col)
	box.add_child(tag)
	# 新核心 / 升级奖励：在卡片底部显示对应核心的图标
	if kind == "core" or kind == "upgrade":
		var icon: Texture2D = CoreSelectorUI.CORE_ICONS.get(str(opt.get("mode", "")), null)
		if icon != null:
			var icon_rect := TextureRect.new()
			icon_rect.texture = icon
			icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.custom_minimum_size = Vector2(56, 56)
			icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			box.add_child(icon_rect)
	return card

func _on_card_input(ev: InputEvent, opt: Dictionary) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var kind := str(opt.get("kind", ""))
		# 稀有词条（专属/unique）：先弹出“选择承载核心”，选择后才真正授予
		if kind == "buff" and rewards.is_unique_effect(str(opt.get("id", ""))):
			_open_unique_target(opt)
			return
		rewards.apply_option(opt)
		_on_reward_picked()

## 领取当前项后：还有下一掉落项则继续弹，否则进入下一关
func _on_reward_picked() -> void:
	_reward_queue_idx += 1
	if _reward_queue_idx < _reward_queue.size():
		_render_reward_item()
	else:
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
	_on_reward_picked()

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

## 领取奖励后 / 点继续（跳过）：按已完成关卡数，在符合难度的关卡里随机选下一关。
## 原本的顺序推进（level_index+1 循环）由 hex_level_select 模块取代。
func _advance_after_reward() -> void:
	if cleared_levels <= 10: cleared_levels += 1
	# 排除刚打完的这关，避免立刻重打同关
	var exclude := str(LEVEL_PATHS[level_index])
	var next_path := level_select.pick_next_level(cleared_levels, exclude)
	var idx := level_select.index_of_path(next_path)
	if idx < 0:
		# 兜底（理论上不会发生：easy 关恒可候选）：退回顺序推进
		idx = (level_index + 1) % LEVEL_PATHS.size()
	_load_level(idx)
	_hide_reward_screen()

## 领取奖励后 / 点继续（跳过剩余掉落）：跳过所有尚未领取的掉落，直接进入下一关
func _on_reward_continue() -> void:
	_advance_after_reward()

## 加载指定关卡并复位游戏到部署阶段
func _load_level(idx: int) -> void:
	level_index = idx
	map_data.load_map()
	geometry.fit_hex_size()
	geometry.recenter()
	deploy.reset()
	_set_paused(true)   # 每关开局默认进入暂停
	queue_redraw()
	guide.check_expand_intro()       # 本局首次进入拓展关卡（难度≥11）播放一次性剧情对话
	guide.check_enemy_encounters()   # 首次遇到新敌人时播放对应教程
	_update_level_indicator()        # 关卡切换后刷新顶部中央的关卡指示

# ---------------------------------------------------------------------------
# 顶部中央关卡指示（主线：第 X 关；进入无尽模式后显示进度）
# ---------------------------------------------------------------------------

## 创建屏幕顶部中央的关卡指示 Label（场景就绪时调用一次）
func _build_level_indicator() -> void:
	level_indicator_layer = CanvasLayer.new()
	level_indicator_layer.layer = 12   # 位于右上按钮(10)之上、各类弹层(25+)之下
	add_child(level_indicator_layer)
	level_indicator_label = Label.new()
	level_indicator_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	level_indicator_label.add_theme_font_size_override("font_size", 26)
	level_indicator_label.add_theme_color_override("font_color", Color("ffe9c4"))
	level_indicator_label.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.08, 0.85))
	level_indicator_label.add_theme_constant_override("outline_size", 6)
	level_indicator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_indicator_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 顶中锚点 + 固定宽矩形，文字始终水平居中（label 会随文案自动换行截断于矩形内）
	level_indicator_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	level_indicator_label.offset_left = -600.0
	level_indicator_label.offset_right = 600.0
	level_indicator_label.offset_top = 6.0
	level_indicator_label.offset_bottom = 58.0
	level_indicator_layer.add_child(level_indicator_label)

## 刷新关卡指示文案：主线显示“第 X 关”，通关主线后（第 11 关起）显示无尽模式进度
func _update_level_indicator() -> void:
	if level_indicator_label == null:
		return
	if cleared_levels >= MAIN_LINE_LEVELS:
		level_indicator_label.text = "无尽模式 · 已通过 %d 关" % (cleared_levels - MAIN_LINE_LEVELS)
	else:
		level_indicator_label.text = "第 %d 关" % level_index

# ---------------------------------------------------------------------------
# 暂停与倍速（右上角 UI）
# ---------------------------------------------------------------------------
func _build_game_controls() -> void:
	game_controls_layer = CanvasLayer.new()
	game_controls_layer.layer = 10
	add_child(game_controls_layer)

	# 整体挂载 GUI 场景：倍速 / 暂停两个图标按钮（位置、缩放以场景内摆放为准）。
	# 根 Control 铺满屏幕但不拦截鼠标，只有两个按钮接收点击。
	var gui: Control = GUI_SCENE.instantiate()
	gui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_controls_layer.add_child(gui)
	speed_button = gui.get_node_or_null(GUI_SPEED_NODE) as Button
	pause_button = gui.get_node_or_null(GUI_PAUSE_NODE) as Button
	if speed_button != null:
		speed_button.pressed.connect(_cycle_speed)
	if pause_button != null:
		pause_button.pressed.connect(_toggle_pause)
	settings_button = gui.get_node_or_null(GUI_SETTINGS_NODE) as Button
	if settings_button != null:
		settings_button.pressed.connect(_on_settings_pressed)
	reset_button = gui.get_node_or_null(GUI_RESET_NODE) as Button
	if reset_button != null:
		reset_button.pressed.connect(_on_gui_reset_pressed)

	# 道具栏（独立面板）：放在键位提示（GUI 场景里的 Label）正下方，避免遮挡
	var panel := PanelContainer.new()
	game_controls_layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	if items != null:
		items.build_bar(vbox)

	# 顶到 GUI 场景里键位提示标签的下缘之下：取所有 Label 下缘的最大值 + 间距
	var label_bottom := 0.0
	for c in gui.get_children():
		if c is Label:
			label_bottom = maxf(label_bottom, c.offset_bottom)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	panel.offset_top = label_bottom + ITEM_BAR_GAP
	# 等一帧让容器按内容完成布局，再以右上角为支点整体放大（右缘仍贴边、向下向左延展）
	_apply_item_bar_layout(panel)

## 布局稳定后把道具栏放大到 ITEM_BAR_SCALE 倍：以右上角为缩放支点，避免向右越出屏幕
func _apply_item_bar_layout(panel: PanelContainer) -> void:
	await get_tree().process_frame
	if panel == null or not is_instance_valid(panel):
		return
	panel.pivot_offset = Vector2(panel.size.x, 0.0)
	panel.scale = Vector2.ONE * ITEM_BAR_SCALE

func _toggle_pause() -> void:
	_set_paused(not paused)

## 设置暂停状态，并同步右上角按钮图标与状态栏文案
func _set_paused(on: bool) -> void:
	paused = on
	if pause_button != null:
		# 图标随状态切换：运行时显示 pause（点击暂停），暂停时显示 continue（点击继续）
		pause_button.add_theme_icon_override("icon", ICON_CONTINUE if paused else ICON_PAUSE)
	if paused:
		hud.set_status("已暂停（空格继续 / F 调速；仍可部署核心）")
	else:
		# 解除暂停时，若仍在游玩模式的部署阶段，视为“开始扩散”
		if mode == Mode.PLAY and phase == Phase.DEPLOY:
			deploy.start()
		else:
			hud.update_status()
	queue_redraw()

func _cycle_speed() -> void:
	speed_index = (speed_index + 1) % SPEED_LEVELS.size()
	game_speed = SPEED_LEVELS[speed_index]
	if speed_button != null:
		speed_button.add_theme_icon_override("icon", _speed_icon())

## 当前倍速档位对应的图标（1x/2x/4x）
func _speed_icon() -> Texture2D:
	match speed_index:
		1:
			return ICON_2X
		2:
			return ICON_4X
		_:
			return ICON_1X

# ---------------------------------------------------------------------------
# 音量设置（音频总线：Master / Music / SFX；数值读写统一走 VolumeSettings）
# ---------------------------------------------------------------------------

## 确保 Music / SFX 音频总线存在（Master 恒为 0 号），并把场景内的 BGM / SpreadSE 挂到对应总线
func _ensure_audio_buses() -> void:
	VolumeSettings.ensure_buses()
	if has_node("BGM"):
		$BGM.bus = "Music"
	if has_node("SpreadSE"):
		$SpreadSE.bus = "SFX"

## 从 user://volume.cfg 读取音量（缺失键用默认值：音乐默认 -10dB）并应用
func _load_volume_settings() -> void:
	var v := VolumeSettings.load_values()
	volume_master = v["master"]
	volume_music = v["music"]
	volume_sfx = v["sfx"]
	_apply_volume()

func _save_volume_settings() -> void:
	VolumeSettings.save_values(volume_master, volume_music, volume_sfx)

## 把三个音量值写入对应音频总线
func _apply_volume() -> void:
	AudioServer.set_bus_volume_linear(0, volume_master)  # Master
	var m := AudioServer.get_bus_index("Music")
	if m != -1:
		AudioServer.set_bus_volume_linear(m, volume_music)
	var s := AudioServer.get_bus_index("SFX")
	if s != -1:
		AudioServer.set_bus_volume_linear(s, volume_sfx)

func _on_master_slider(v: float) -> void:
	volume_master = v
	_apply_volume()
	_save_volume_settings()

func _on_music_slider(v: float) -> void:
	volume_music = v
	_apply_volume()
	_save_volume_settings()

func _on_sfx_slider(v: float) -> void:
	volume_sfx = v
	_apply_volume()
	_save_volume_settings()

## 在 parent 下追加一行「标签 + 滑块 + 百分比」；返回滑块
func _add_volume_row(parent: Control, label_text: String, init_value: float, on_change: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(80, 0)
	lbl.add_theme_font_size_override("font_size", 15)
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = init_value
	slider.custom_minimum_size = Vector2(160, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var val := Label.new()
	val.text = "%d%%" % int(init_value * 100)
	val.custom_minimum_size = Vector2(44, 0)
	val.add_theme_font_size_override("font_size", 13)
	val.add_theme_color_override("font_color", Color("9fb0cc"))
	row.add_child(val)

	slider.value_changed.connect(func(v: float):
		val.text = "%d%%" % int(v * 100)
		on_change.call(v)
	)
	return slider

# ---------------------------------------------------------------------------
# 暂停菜单（ESC 打开）：变暗遮罩 + 继续游戏 / 重置 / 回到主菜单
# ---------------------------------------------------------------------------
func _build_pause_menu() -> void:
	pause_menu_layer = CanvasLayer.new()
	pause_menu_layer.layer = 30
	pause_menu_layer.visible = false
	add_child(pause_menu_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.68)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_menu_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_menu_layer.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_bottom", 30)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "暂停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	vbox.add_child(title)

	var continue_btn := Button.new()
	continue_btn.text = "继续游戏"
	continue_btn.custom_minimum_size = Vector2(240, 0)
	continue_btn.pressed.connect(_close_pause_menu)
	vbox.add_child(continue_btn)

	var reset_btn := Button.new()
	reset_btn.text = "重置"
	reset_btn.custom_minimum_size = Vector2(240, 0)
	reset_btn.pressed.connect(_on_pause_menu_reset)
	vbox.add_child(reset_btn)

	edit_mode_button = Button.new()
	edit_mode_button.text = "编辑模式"
	edit_mode_button.custom_minimum_size = Vector2(240, 0)
	edit_mode_button.pressed.connect(_on_pause_menu_edit_mode)
	vbox.add_child(edit_mode_button)

	var menu_btn := Button.new()
	menu_btn.text = "回到主菜单"
	menu_btn.custom_minimum_size = Vector2(240, 0)
	menu_btn.pressed.connect(_on_pause_menu_main_menu)
	vbox.add_child(menu_btn)

	# —— 音量设置 ——
	var vol_title := Label.new()
	vol_title.text = "音量设置"
	vol_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vol_title.add_theme_font_size_override("font_size", 18)
	vol_title.add_theme_color_override("font_color", Color("ffd166"))
	vbox.add_child(vol_title)

	_add_volume_row(vbox, "总音量", volume_master, _on_master_slider)
	_add_volume_row(vbox, "音乐音量", volume_music, _on_music_slider)
	_add_volume_row(vbox, "音效音量", volume_sfx, _on_sfx_slider)

func _open_pause_menu() -> void:
	pause_menu_open = true
	if pause_menu_layer != null:
		pause_menu_layer.visible = true
	queue_redraw()

func _close_pause_menu() -> void:
	pause_menu_open = false
	if pause_menu_layer != null:
		pause_menu_layer.visible = false
	queue_redraw()

## 重置：重置当前关卡到部署阶段，退还本关已消耗的道具，并自动进入暂停状态
func _on_pause_menu_reset() -> void:
	_close_pause_menu()
	deploy.reset(true)
	_set_paused(true)   # 重置后自动暂停，等待重新部署

## 切换编辑模式（关闭暂停菜单后切换，与原左上角“编辑模式”按钮一致）
func _on_pause_menu_edit_mode() -> void:
	_close_pause_menu()
	editor.toggle_mode()

func _on_pause_menu_main_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

## ESC 统一处理：优先关控制台 / 取消道具瞄准，否则打开暂停菜单
func _handle_escape() -> void:
	if console_open:
		console.close()
	elif items != null and items.is_aiming():
		items.cancel_arm()
	else:
		_open_pause_menu()

## GUI Settings 按钮：等效于“空闲状态下按 ESC”，呼出暂停/设置菜单
func _on_settings_pressed() -> void:
	# 与 ESC 处理一致：教程播放、暂停菜单/词条总览/奖励界面已打开时不响应
	if tutorial_active:
		return
	if pause_menu_open:
		return
	if buff_overview_open:
		return
	if reward_layer != null and reward_layer.visible:
		return
	_handle_escape()

## GUI Reset 按钮：与 ESC 暂停菜单“重置”一致——重置当前关卡并退还本关已消耗的道具，随后自动暂停
func _on_gui_reset_pressed() -> void:
	# 教程播放 / 暂停菜单 / 词条总览 / 奖励界面打开时不响应（与设置按钮一致）
	if tutorial_active:
		return
	if pause_menu_open:
		return
	if buff_overview_open:
		return
	if reward_layer != null and reward_layer.visible:
		return
	deploy.reset(true)   # 退还本关已消耗的道具
	_set_paused(true)    # 重置后自动暂停，等待重新部署

func _unhandled_input(event: InputEvent) -> void:
	if reward_layer != null and reward_layer.visible:
		return  # 奖励界面弹出时屏蔽游戏输入
	if pause_menu_open:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_pause_menu()
		return  # 暂停菜单打开时屏蔽其余输入
	if buff_overview_open:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			hud.close_buff_overview()
		return  # 词条总览打开时屏蔽游戏输入
	if tutorial_active:
		return  # 剧情/教程播放期间屏蔽所有游戏交互（含暂停部署、快捷键）
	# 全局快捷键：F 倍速、空格暂停（暂停中也生效）
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F:
			_cycle_speed()
			return
		if event.keycode == KEY_SPACE:
			_toggle_pause()
			return
	if paused:
		# 暂停时：仍允许部署/移除核心（鼠标），ESC 打开暂停菜单，R 打开/关闭控制台
		if event is InputEventKey and event.pressed:
			if event.keycode == KEY_ESCAPE:
				_handle_escape()
				return
			if event.keycode == KEY_R:
				if console_open:
					console.close()
				else:
					console.open()
				return
		if console_open:
			return
		if event is InputEventMouseMotion:
			hover_cell = geometry.pixel_to_hex(event.position)
			queue_redraw()
		elif mode != Mode.EDIT and event is InputEventMouseButton and event.pressed:
			_handle_deploy_mouse(event)
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
			_handle_escape()
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
		_handle_deploy_mouse(event)
	elif event is InputEventKey and event.pressed:
		# 数字键选择核心类型（与右下角 UI 同步；只按显示顺序对应已解锁核心）
		var visible_cores: Array[int] = hud.visible_core_indices()
		for k in range(visible_cores.size()):
			if event.keycode == KEY_1 + k:
				hud.select_core(visible_cores[k])
				return
		if event.keycode == KEY_ENTER and phase == Phase.DEPLOY:
			deploy.start()

## 部署相关鼠标输入（放置/移除核心、道具瞄准、定向选择）；暂停时也允许部署
func _handle_deploy_mouse(event: InputEvent) -> void:
	var cell := geometry.pixel_to_hex(event.position)
	if phase == Phase.DEPLOY or phase == Phase.RUNNING:
		# 道具瞄准：优先于普通部署/拆除；左键选择目标、右键取消
		if items != null and items.is_aiming():
			if event.button_index == MOUSE_BUTTON_LEFT:
				items.try_use_at(cell)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				items.cancel_arm()
			queue_redraw()
			return
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

func _draw() -> void:
	drawer.draw()
