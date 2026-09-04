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
##   - 绘制（颜色 / 圆圈 / 方向箭头等仍由主脚本读取 config 与 direction 绘制）；
##   - 污染的全局字典 polluted 与胜负判定。
##
## 【接入方式（供未来接线参考；本文件不依赖主脚本，可独立实例化）】
##   1. var n: PlayerCore = (load("res://scenes/player_core.tscn") as PackedScene).instantiate()
##   2. n.setup(cell, type_index, core_types[type_index], dir)
##   3. add_child(n) 并登记（主脚本：units[cell] = n；放置后 polluted[cell] = 行为载荷）
##   4. 每帧 n.advance(delta) 推进倒计时；n.remaining <= 0 即到期移除。

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
## 定向模式的方向（轴向偏移）；其它模式保持 Vector2i.ZERO
var direction := Vector2i.ZERO

# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------
## 初始化一颗核心：放置在 cell，类型为 core_types[type_idx]，定向方向 dir。
## remaining 从 cfg.duration 开始倒计时。
func setup(cell: Vector2i, type_idx: int, cfg: Dictionary, dir: Vector2i = Vector2i.ZERO) -> void:
	coord = cell
	type_index = type_idx
	config = cfg
	remaining = float(cfg.get("duration", 15.0))
	direction = dir

## 每帧推进剩余时间；返回是否到期（<=0，调用方负责移除本节点）
func advance(delta: float) -> bool:
	remaining -= delta
	return remaining <= 0.0

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

## 本核心放置后应写入 polluted 的载荷（交给主脚本 _pollute_with）
func payload() -> Dictionary:
	return behavior().make_payload(direction)

## 本核心是否属于定向类（部署时需选方向）
func is_directional() -> bool:
	return behavior().needs_direction()
