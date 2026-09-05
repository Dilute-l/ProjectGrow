class_name EnemyTurret
extends Node2D

## 敌方炮台 —— 独立节点模块（状态 + 攻击逻辑）
##
## 从 scripts/hex_game.gd（多炮台版本）中把“敌方炮台”的自身状态与攻击逻辑
## 拆分出来，封装为可挂载、可复用的节点。
## **一个 EnemyTurret 节点 = 一个敌方炮台**，主脚本按地图中的炮台位置列表
## 为每个炮台生成一个子节点即可。
##
## 【本节点负责】
##   - 单个炮台的状态：坐标 coord、存活 alive、攻击计时 attack_timer、
##     攻击间隔 attack_interval（可运行时调整）；
##   - 攻击逻辑：按间隔计时，在攻击范围（attack_range，立方体距离，默认 3 格）
##     内选择“离自己最近”的污染地块，清除它；若该地块上是我方核心则一并摧毁。
##     核心改造后污染已并入统一 polluted 字典（值 {mode,dir}），清除一次即可；
##     传入的 radial_polluted / directional_polluted（可选兼容集合）也会一并移除；
##   - 损毁规则：污染蔓延到本炮台所在格 => 损毁（见 check_contamination()）。
##
## 【本节点不负责（留在主脚本 / 接入方）】
##   - 读取 maps/*.json、得到 turret_positions（那是地图数据，不是炮台行为）；
##   - 全部绘制（外观 / 充能环 / 损毁叉号）与颜色常量；
##   - 胜负判定（全部炮台损毁 => WON；无存活核心且仍有存活炮台 => LOST）；
##   - HUD 状态文案与控制台。
##   绘制所需的数据都可以只读方式取到：coord / alive / charge_fraction()。
##
## 【与现版 hex_game.gd 的等价约定】
##   hex_game.gd（现版）                          ->  本节点 API
##   turrets 字典的键 Vector2i（炮台位置）        ->  coord（每节点一个）
##   turrets 字典的值（该炮台距下次攻击的秒数）   ->  attack_timer
##   “键存在于 turrets”即代表存活                 ->  alive == true
##   enemy_attack_interval                         ->  attack_interval（运行时调整后同步给各节点）
##   _enemy_attack(from)                           ->  tick()（内部完成选目标 + 清除污染/摧毁核心）
##   _nearest_polluted(from)                       ->  choose_target()
##   _check_turret_destruction()                   ->  check_contamination()（逐节点调用）
##   _draw() 充能环 turrets[p] / enemy_attack_interval -> charge_fraction()
##
## 【接入方式（供未来接线参考；本文件不依赖主脚本，可独立实例化）】
##   1. 生成并挂载（EnemyTurret 为全局 class_name，接入方代码）：
##      for p in turret_positions:
##          var t := EnemyTurret.new()
##          t.setup(p, enemy_attack_interval)
##          add_child(t)
##   2. 每帧（原 _process 第 6 步“敌方攻击”）对每个节点：
##      if t.tick(delta, polluted, units):
##          queue_redraw()
##   3. 每次蔓延后（原第 5 步“炮台摧毁 / 胜利判定”）逐节点：
##      if t.check_contamination(polluted): （若全部损毁则判胜）
##   4. _start() / _reset() 时逐节点 t.reset()；
##      控制台修改攻击间隔后把新值同步给各节点（t.attack_interval = 新值）。
##   5. HUD“存活炮台”= 遍历 alive 计数；绘制判断 turrets.has(p) 改为 t.alive。

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
const ATTACK_INTERVAL_DEFAULT := 0.5   # 攻击间隔默认值（秒），与原 ENEMY_ATTACK_INTERVAL_DEFAULT 一致
const ATTACK_RANGE_DEFAULT := 3        # 攻击范围默认值（六边形立方体距离，单位：格）
const NO_TARGET := Vector2i(2147483647, 2147483647)  # “无目标”哨兵值

# 敌方炮台类型：名称 -> {range(攻击范围，格), interval_mult(攻速倍率，相对基础间隔)}
const TURRET_TYPES := {
	"basic": {"range": 3, "interval_mult": 3},   # 基础
	"sniper": {"range": 4, "interval_mult": 5},  # 范围大一格、攻速更慢
	"rapid": {"range": 2, "interval_mult": 1.5},   # 范围小一格、攻速更快
	"beam": {"range": 4, "interval_mult": 8},    # 射线清除：范围4，攻击间隔长
	"sweeper": {"range": 2, "interval_mult": 8},  # 扫荡凝视：范围2圈，4秒清除范围内所有触手
	"mortar": {"range": 3, "interval_mult": 7},   # 炮塔：普通索敌，3.5秒清除目标一圈内所有触手
}

# 光束炮台的 6 条单方向射线（六邻域各一个方向），用于射线清除型炮台
const RAYS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, -1), Vector2i(-1, 1),
]

# ---------------------------------------------------------------------------
# 信号
# ---------------------------------------------------------------------------
## 每次成功发动攻击并清除地块后发出；target 为被清除（可能含核心）的地块
signal attacked(target: Vector2i)
## 炮台被污染摧毁（由 check_contamination() 或 destroy() 触发）
signal destroyed

# ---------------------------------------------------------------------------
# 状态（对应原 hex_game.gd 中 turrets 字典与 enemy_attack_interval）
# ---------------------------------------------------------------------------
## 本炮台所在六边形坐标（轴向坐标；来自 turret_positions，如 (0,0)、(0,3)）
var coord := Vector2i.ZERO
## 是否存活（原 turrets 字典中“该键是否存在”）
var alive := true
## 攻击间隔（秒，可运行时调整；原 enemy_attack_interval）
var attack_interval := ATTACK_INTERVAL_DEFAULT
## 攻击范围（六边形立方体距离，单位：格；炮台只清除此范围内的污染地块）
var attack_range := ATTACK_RANGE_DEFAULT
## 炮台类型名（basic / sniper / rapid）
var turret_type := "basic"
## 攻速倍率（相对基础间隔；由类型决定）
var interval_mult := 1.0
## 距下次攻击已累计的秒数（只应由 tick() 推进；原 turrets[coord] 的值）
var attack_timer := 0.0
## 眩晕剩余秒数（>0 时停止攻击并冻结充能；由「清算反噬」类词条施加）
var stun_timer := 0.0

# ---------------------------------------------------------------------------
# 初始化 / 重置
# ---------------------------------------------------------------------------
## 初始化本炮台并复位：放置在 cell，类型为 type_name，基础攻击间隔为 base_interval。
## 实际攻击间隔 = base_interval × 类型攻速倍率。
func setup(cell: Vector2i, type_name: String = "basic", base_interval: float = ATTACK_INTERVAL_DEFAULT) -> void:
	coord = cell
	turret_type = type_name
	var stats: Dictionary = TURRET_TYPES.get(type_name, TURRET_TYPES["basic"])
	attack_range = int(stats["range"])
	interval_mult = float(stats["interval_mult"])
	set_base_interval(base_interval)
	reset()

## 设置基础攻击间隔，并按类型攻速倍率换算实际间隔
func set_base_interval(base: float) -> void:
	attack_interval = base * interval_mult

## 复位为“存活、未充能”状态（对应关卡重置 / 开始时重建 turrets 字典并清零计时）
func reset() -> void:
	alive = true
	attack_timer = 0.0
	stun_timer = 0.0

## 外部强制摧毁本炮台（未来扩展：被其它手段击杀等）
func destroy() -> void:
	if alive:
		alive = false
		destroyed.emit()

# ---------------------------------------------------------------------------
# 每帧逻辑（攻击）
# ---------------------------------------------------------------------------
## 每帧推进攻击充能；到点时发动一次攻击：
##   - 若攻击范围（attack_range）内存在污染地块：清除离 coord 最近的一块
##     （统一 polluted；如传入了 radial_polluted / directional_polluted
##     兼容集合也一并移除）；若该地块上有我方核心则一并摧毁；
##   - 若没有可攻击目标：本次空过，充能重新计时（与原 _enemy_attack() 一致）。
## 各污染集合与 units 以引用传入，直接在其中清除 —— 数据归属仍在主脚本。
## 返回是否真的发动了攻击（可用于触发重绘等）。
func tick(delta: float, polluted: Dictionary, units: Dictionary, radial_polluted: Dictionary = {}, directional_polluted: Dictionary = {}, drop_effects = null, battle_time: float = 0.0) -> bool:
	if not alive:
		return false
	if stun_timer > 0.0:
		stun_timer -= delta  # 眩晕期间冻结充能（停止攻击）
		return false
	attack_timer += delta
	if attack_timer < attack_interval:
		return false
	attack_timer = 0.0
	# 按类型收集本次要清除的目标地块，再统一清除
	var targets: Array = []
	var emit_cell := coord
	if is_beam():
		# 射线清除：选一条“含最多污染地块”的射线
		targets = choose_line_targets(polluted)
	elif is_sweeper():
		# 扫荡凝视：清除攻击范围内（距离 ≤ attack_range）的所有触手
		for cell in polluted.keys():
			if _cube_dist(cell, coord) <= attack_range:
				targets.append(cell)
	elif is_mortar():
		# 炮塔：普通索敌（最近目标），清除目标周围一圈（距离 ≤ 1）的所有触手
		var center := choose_target(polluted)
		if center == NO_TARGET:
			return false
		emit_cell = center
		for cell in polluted.keys():
			if _cube_dist(cell, center) <= 1:
				targets.append(cell)
	else:
		# 普通：清除离自己最近的一块
		var target := choose_target(polluted)
		if target == NO_TARGET:
			return false
		targets.append(target)
		emit_cell = target
	if targets.is_empty():
		return false
	var cleared_any := false
	for cell in targets:
		if _clear_cell(cell, polluted, units, radial_polluted, directional_polluted, drop_effects, battle_time):
			cleared_any = true
	if cleared_any:
		attacked.emit(emit_cell)
	return cleared_any

## 清除单个地块（含耐久/庇护判定、摧毁核心、施加眩晕）；返回是否真的清除
func _clear_cell(cell: Vector2i, polluted: Dictionary, units: Dictionary, radial_polluted: Dictionary, directional_polluted: Dictionary, drop_effects, battle_time: float) -> bool:
	var pl = polluted.get(cell, null)
	if pl == null:
		return false
	if drop_effects != null and not drop_effects.attempt_clear(pl, battle_time):
		return false  # 被庇护挡住或只是扣除一次耐久
	polluted.erase(cell)
	radial_polluted.erase(cell)
	directional_polluted.erase(cell)
	if units.has(cell):
		units.erase(cell)  # 摧毁我方单位核心
	if drop_effects != null:
		stun_timer = maxf(stun_timer, drop_effects.stun_on_clear(pl))
	return true

## 当前攻击充能进度 0..1（供主脚本绘制充能环；
## 替代原 _draw() 中 turrets[p] / enemy_attack_interval 的读取）
func charge_fraction() -> float:
	if not alive or attack_interval <= 0.0:
		return 0.0
	return clampf(attack_timer / attack_interval, 0.0, 1.0)

## 蔓延结算后调用：若污染已覆盖本炮台所在地块，则本炮台损毁并发出 destroyed。
## 返回是否损毁；接入方据此判断“所有炮台都已损毁 => 胜利”
## （对应原 _check_turret_destruction() 的逐炮台语义）。
func check_contamination(polluted: Dictionary) -> bool:
	if alive and polluted.has(coord):
		alive = false
		destroyed.emit()
		return true
	return false

# ---------------------------------------------------------------------------
# 攻击目标选择（扩展点：子类可覆写 choose_target() 以定制攻击规则）
# ---------------------------------------------------------------------------
## 选择离 coord 最近且处于攻击范围（立方体距离 <= attack_range）内的
## 一块污染地块；污染区为空或范围内无污染时返回 NO_TARGET。
## 距离相同取先遍历到者（与原 _nearest_polluted() 一致）。
func choose_target(polluted: Dictionary) -> Vector2i:
	var best := NO_TARGET
	var best_d := 1 << 30
	for cell: Vector2i in polluted.keys():
		var d := _cube_dist(cell, coord)
		if d > attack_range:
			continue  # 超出攻击范围
		if d < best_d:
			best_d = d
			best = cell
	return best

## 是否为直线清除型炮台（beam）
func is_beam() -> bool:
	return turret_type == "beam"

## 是否为扫荡凝视（范围内AOE清除）
func is_sweeper() -> bool:
	return turret_type == "sweeper"

## 是否为炮塔（目标周围一圈AOE清除）
func is_mortar() -> bool:
	return turret_type == "mortar"

## 射线清除型：在 6 条单方向射线中选“含最多污染地块”的一条，返回该射线上的所有污染地块
func choose_line_targets(polluted: Dictionary) -> Array:
	var best: Array = []
	for d: Vector2i in RAYS:
		var tiles: Array = []
		for k in range(1, attack_range + 1):
			var cell: Vector2i = coord + d * k
			if polluted.has(cell):
				tiles.append(cell)
		if tiles.size() > best.size():
			best = tiles
	return best

# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------
## 六边形轴向坐标的立方体距离（与原 hex_game.gd 中 cube_dist() 相同）
static func _cube_dist(a: Vector2i, b: Vector2i) -> int:
	var dx := a.x - b.x
	var dz := a.y - b.y
	var dy := -dx - dz
	return maxi(absi(dx), maxi(absi(dy), absi(dz)))

## —— 模块结束 ——
