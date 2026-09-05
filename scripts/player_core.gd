class_name PlayerCore
extends Node2D

## 我方核心 —— 独立节点模块（每颗部署的核心 = 一个 PlayerCore 场景实例）
##
## 从 scripts/hex_game.gd 中把“我方单位核心”的运行期状态与类型数据拆分出来：
##   - 类型数据来自 maps/cores.json（core_types 数组），在 setup() 时快照进 config；
##   - 节点只携带“这一颗核心”的状态：所在格 coord、类型索引 type_index、
##     剩余持续时间 remaining、定向方向 direction；
##   - 行为（如何污染 / 如何扩散）由 CoreMode 注册表按 config.mode 提供，
##     主脚本用统一的 _pollute_with / _spread_mode 驱动。
##
## 【与现版 hex_game.gd 的等价约定】
##   旧 units 字典的元素字段            ->  本节点
##   { type: int }                      ->  type_index + config（core_types 条目快照）
##   { remaining: float }               ->  remaining（advance() 推进）
##   { direction: Vector2i }            ->  direction
##   _make_unit(type_idx)               ->  setup(cell, type_idx, cfg, dir) + CORE_SCENE 实例化
##   core_types[u["type"]]["mode"] 等   ->  config / mode()
##
## 【本节点不负责（留在主脚本 / 接入方）】
##   - 读取 cores.json、维护 core_types 列表；
##   - 污染的全局字典 polluted 与胜负判定。
## 【本节点负责】
##   - 自身绘制（颜色 / 实心圆 / 外圈 / 持续时间环 / 定向箭头，见 _draw()）。
##
## 【接入方式（供未来接线参考；本文件不依赖主脚本，可独立实例化）】
##   1. var n: PlayerCore = (load("res://scenes/player_core.tscn") as PackedScene).instantiate()
##   2. n.setup(cell, type_index, core_types[type_index], dir)
##   3. add_child(n) 并登记（主脚本：units[cell] = n；放置后 polluted[cell] = 行为载荷）
##   4. 每帧 n.advance(delta) 推进倒计时；n.remaining <= 0 即到期移除。

# ---------------------------------------------------------------------------
# 部署费用（玩家整体资源；本文件只定义数值，扣费与校验由接线方在部署入口完成）
# ---------------------------------------------------------------------------
## 玩家初始部署费用（点）：开局可用点数
const DEPLOY_COST_START := 70
## 玩家部署费用上限（点）：可用点数不得超过该值
const DEPLOY_COST_MAX := 70
## 提示：每种核心的部署消耗定义在 maps/cores.json 的 cost 字段，
## 本文件只存玩家侧初始值与上限。

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
## 本核心所在六边形坐标
var coord := Vector2i.ZERO
## 在 core_types 中的类型索引
var type_index := 0
## 类型数据快照（{id,name,mode,duration,spread_interval,color}，来自 cores.json）
var config: Dictionary = {}
## 剩余持续时间（秒，由 advance() 递减）
var remaining := 0.0
## 本核心的部署时刻（战斗时间，秒；由接线方在 spawn 时写入，供限时类词条判断）
var spawn_time := 0.0
## 本核心实例的唯一标识（由接线方在 spawn 时分配；污染地块用 owner 标记归属，
## 用于“核心失效后其产生的地块不再向外扩散”）
var uid := -1
## 定向模式的方向（轴向偏移）；其它模式保持 Vector2i.ZERO
var direction := Vector2i.ZERO
# 渲染上下文（由接线方在生成时与窗口/地图尺寸变化时同步）
var hex_size := 26.0
var map_offset := Vector2.ZERO

# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------
## 初始化一颗核心：放置在 cell，类型为 core_types[type_idx]，定向方向 dir。
## remaining 从 cfg.duration 开始倒计时。
func setup(cell: Vector2i, type_idx: int, cfg: Dictionary, dir: Vector2i = Vector2i.ZERO, size: float = 26.0, offset: Vector2 = Vector2.ZERO) -> void:
	coord = cell
	type_index = type_idx
	config = cfg
	remaining = float(cfg.get("duration", 15.0))
	direction = dir
	hex_size = size
	map_offset = offset
	position = map_offset + HexGeometry.axial_to_pixel(coord.x, coord.y, hex_size)
	queue_redraw()

## 每帧推进剩余时间；返回是否到期（<=0，调用方负责移除本节点）
func advance(delta: float) -> bool:
	remaining -= delta
	queue_redraw()  # 剩余时间变化 → 持续时间环需重绘
	return remaining <= 0.0

## 核心耗尽：整体变暗保留视觉（而非直接消失）；污染地块仍保留、但不再扩散
func mark_corpse() -> void:
	self_modulate = Color(0.45, 0.45, 0.5)
	queue_redraw()

# ---------------------------------------------------------------------------
# 便捷读取
# ---------------------------------------------------------------------------
## 本核心的模式名（= config.mode，即 CoreMode 注册表键）
func mode() -> String:
	return str(config.get("mode", "radial"))

## 本核心对应的行为模式对象（未注册模式时按径向兜底）
func behavior() -> CoreMode:
	var b := CoreMode.for_mode(mode())
	if b == null:
		b = CoreMode.for_mode("radial")
	return b

## 本核心放置后应写入 polluted 的载荷（交给主脚本 _pollute_with）。
## 载荷里附带 source = 本核心所在格；owner = 本核心 uid，用于“失效后停止外扩”。
func payload() -> Dictionary:
	var p: Dictionary = behavior().make_payload(direction)
	p["source"] = coord
	p["owner"] = uid
	return p

## 本核心是否属于定向类（部署时需选方向）
func is_directional() -> bool:
	return behavior().needs_direction()

## 本核心到期时的一次性爆发候选格（默认空；蓄力类核心覆写）
func burst_cells() -> Array[Vector2i]:
	return behavior().burst_candidates(coord)

# ---------------------------------------------------------------------------
# 渲染（本节点自行绘制；主脚本不再代画）
# ---------------------------------------------------------------------------
## 窗口 / 地图尺寸变化时，由接线方同步最新的渲染上下文
func update_layout(size: float, offset: Vector2) -> void:
	hex_size = size
	map_offset = offset
	position = map_offset + HexGeometry.axial_to_pixel(coord.x, coord.y, hex_size)
	queue_redraw()

## 核心颜色（来自 config.color；空值兜底为默认单位色）
func _core_color() -> Color:
	var hex := str(config.get("color", ""))
	if hex == "":
		return Color("3fc1ff")
	return Color(hex)

# 核心本体贴图（画在矢量图形之上）
const TEX_CORE := preload("res://images/Direct_core.png")
const TEX_CORE_CHARGE := preload("res://images/Charge_core.png")
const TEX_CORE_SPEEDY := preload("res://images/Fast_core.png")

## 本核心对应的本体贴图（有美术的模式）；无美术的模式返回 null（用矢量圆盘）
func _core_texture() -> Texture2D:
	match mode():
		"directional":
			return TEX_CORE
		"charge":
			return TEX_CORE_CHARGE
		"speedy":
			return TEX_CORE_SPEEDY
	return null
## 贴图内六边形本体的单边边长（像素）：由本体两条垂直边（x=1181/5305，宽 4124）反推 = 4124/√3 ≈ 2381（不含延伸）
const HEX_ART_EDGE := 2381.0
## 贴图内六边形本体中心（像素坐标）；作为锚点对齐节点原点，补偿贴图透明边不对称（不含延伸）
const CORE_ART_CENTER := Vector2(3243.0, 3360.0)
## 定向核心贴图 Direct_core.png 的主导色（实测 alpha>128 平均），用于其计时器环
const DIRECTIONAL_ART_COLOR := Color("#9F4353")
## 贴图微调偏移（以 hex_size 为单位，随窗口缩放；正 x 向右、正 y 向下）
@export var core_tex_offset := Vector2.ZERO

func _draw() -> void:
	var col: Color = _core_color()
	# 实心圆盘 + 外圈描边
	draw_circle(Vector2.ZERO, hex_size * 0.40, col)
	draw_arc(Vector2.ZERO, hex_size * 0.40, 0.0, TAU, 24, col.lightened(0.5), 2.0)
	# 有贴图的核心：画本体贴图；定向核心额外画方向箭头
	var tex := _core_texture()
	if tex != null:
		if mode() == "directional":
			var dirv: Vector2i = direction
			var dirpx: Vector2 = HexGeometry.axial_to_pixel(dirv.x, dirv.y, hex_size).normalized()
			draw_line(Vector2.ZERO, dirpx * hex_size * 0.62, col.lightened(0.25), 3.0)
			draw_circle(dirpx * hex_size * 0.62, 3.0, col.lightened(0.25))
		_draw_core_texture(tex)
	# 持续时间环（六边形，画在贴图之上，位于格子边缘）
	var frac := clampf(remaining / float(config.get("duration", 15.0)), 0.0, 1.0)
	var timer_pts := HexGeometry.hex_progress_points(Vector2.ZERO, hex_size, frac)
	var ring_col := DIRECTIONAL_ART_COLOR.lightened(0.4) if mode() == "directional" else col.lightened(0.5)
	if timer_pts.size() >= 2:
		draw_polyline(timer_pts, ring_col, 3.0)

## 核心本体贴图：以六边形中心（CORE_ART_CENTER）为锚点对齐节点原点（= 格中心）
func _draw_core_texture(tex: Texture2D) -> void:
	var scale: float = hex_size / HEX_ART_EDGE
	var span: float = float(tex.get_width()) * scale
	var off: Vector2 = core_tex_offset * hex_size
	var top_left: Vector2 = off - CORE_ART_CENTER * scale
	draw_texture_rect(tex, Rect2(top_left, Vector2(span, span)), false)
