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
const MAP_PATH := "res://maps/level1.json"    # 地图数据文件
const CORES_PATH := "res://maps/cores.json"   # 核心数据文件

const HEX_SIZE_DEFAULT := 26.0              # 六边形中心到顶点的距离（像素，默认）
const ENEMY_ATTACK_INTERVAL_DEFAULT := 0.5  # 敌方攻击间隔（秒，默认）
const TURRET_ATTACK_RANGE := 3              # 炮台攻击范围（格），用于范围高亮
const FIRST_RUN_FLAG := "user://has_started.flag"  # 首次进入标记

# 运行时数值（可在控制台修改）
var hex_size := HEX_SIZE_DEFAULT
var enemy_attack_interval := ENEMY_ATTACK_INTERVAL_DEFAULT
# 部署费用（玩家整体资源；初始值与上限定义在 PlayerCore）
var deploy_points := PlayerCore.DEPLOY_COST_START

# 地图数据（从文件读取 / 编辑）
var map_radius := 0                            # 六边形地图半径（中心向外层数）
var walls: Dictionary = {}                    # Vector2i -> true
var turret_positions: Array[Vector2i] = []    # 所有敌方炮台位置

# 核心数据（从文件读取）
var core_types: Array = []     # 每个元素为 Dictionary：{id,name,mode,duration,spread_interval,color}

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
var sb_enemy: SpinBox

var status_label: Label
var start_button: Button
var core_buttons: Array[Button] = []
var core_selector_layer: CanvasLayer

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

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------
func _ready() -> void:
	_create_modules()
	map_data.load_map()
	map_data.load_cores()
	map_data.register_core_modes()
	selected_core = clampi(selected_core, -1, core_types.size() - 1)
	geometry.fit_hex_size()
	geometry.recenter()
	hud.build_hud()
	console.build_console()
	hud.build_core_selector()
	editor.build_editor_ui()
	editor.build_file_dialog()
	deploy.reset()
	queue_redraw()
	guide.check_first_run()

func _process(delta: float) -> void:
	if tutorial_active:
		return
	if console_open:
		return
	if mode != Mode.PLAY:
		return
	if phase != Phase.RUNNING:
		return
	# 1) 核心倒计时（到期后核心消失，但其污染地块保留）
	var expired: Array = []
	for cell in units.keys():
		var n: PlayerCore = units[cell]
		if n.advance(delta):
			expired.append(cell)
	for cell in expired:
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
		var iv: float = mode_intervals.get(m, bm.interval_fallback())
		mode_spread_timers[m] = mode_spread_timers.get(m, 0.0) + delta
		if mode_spread_timers[m] >= iv:
			mode_spread_timers[m] = 0.0
			spread.spread_mode(m, bm)
	# 5) 炮台摧毁 / 胜利判定
	spread.check_turret_destruction()
	if phase != Phase.RUNNING:
		hud.update_status()
		queue_redraw()
		return
	# 6) 敌方攻击（每个存活炮台独立计时）
	var attacked := false
	for t in turret_map.values():
		if t.tick(delta, polluted, units):
			attacked = true
			queue_redraw()
	if attacked and tutorial_gate == "attack":
		guide.on_attack()
	if units.is_empty() and turrets.alive_count() > 0:
		phase = Phase.LOST
	spread.free_orphan_cores()
	hud.update_status()
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		geometry.fit_hex_size()
		geometry.recenter()
		guide.update_spotlight()
		queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
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
		if phase == Phase.DEPLOY:
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
