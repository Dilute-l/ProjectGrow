class_name CoreMode
extends RefCounted

## 核心“蔓延模式”的抽象基类 + 注册表。
##
## 背景：我方核心的类型数据（名字/持续时间/扩散间隔/颜色）来自 maps/cores.json，
## 而“这种核心如何扩散”的行为（径向/定向/未来新模式）由 CoreMode 子类描述。
## 主脚本只按模式名查询注册表并调用统一的接口，不再为每种模式写分支 ——
## 这样新增一种“同模式”核心只需改 cores.json；新增一种“新模式”只需：
##   1) 新建一个 CoreMode 子类（实现下面几个虚方法）；
##   2) 在 hex_game.gd 的 _register_core_modes() 里注册一行；
##   3) 在 cores.json 加一条 {"id","name","mode":新模式名,...}。
##
## 内置三种模式（由 hex_game.gd 在 _ready 时注册）：
##   - radial       径向：污染地块每隔一段时间向四周所有相邻地块扩散
##   - directional  定向：污染地块沿部署时选择的方向单向扩散
##   - charge       蓄力：存活期间不扩散，到期后一次性向周围两格爆发

# ---------------------------------------------------------------------------
# 注册表（静态）
# ---------------------------------------------------------------------------
static var _registry: Dictionary = {}   # 模式名(String) -> CoreMode

## 注册一个行为模式；重复注册会被忽略并告警
static func register(mode_name: String, behavior: CoreMode) -> void:
	if _registry.has(mode_name):
		push_warning("CoreMode: 模式「%s」已注册，忽略重复" % mode_name)
		return
	_registry[mode_name] = behavior

## 按模式名取行为；未注册返回 null
static func for_mode(mode_name: String) -> CoreMode:
	return _registry.get(mode_name, null)

## 当前已注册的所有模式名
static func known_modes() -> Array:
	return _registry.keys()

# ---------------------------------------------------------------------------
# 虚接口（子类按需覆写）
# ---------------------------------------------------------------------------
## 模式名（须与 cores.json 里 entry["mode"] 一致），如 "radial" / "directional"
func mode() -> String:
	return ""

## 部署时是否需要“先选地块、再选一个相邻方向”的额外一步（定向类模式返回 true）
func needs_direction() -> bool:
	return false

## 为该模式的一块污染地块构造载荷，存入主脚本的 polluted 字典：
##   polluted[cell] = { "mode": <模式名>, "dir": <方向> }
## dir 仅定向类模式有意义；径向等模式可忽略
func make_payload(dir: Vector2i = Vector2i.ZERO) -> Dictionary:
	return {"mode": mode(), "dir": dir}

## 给定一块该模式的污染地块及其载荷，返回本回合要尝试新增污染的地块列表。
## 只负责“扩散形状/方向”，由主脚本统一做越界、墙、已污染过滤。
## 例：radial 返回 6 个邻居；directional 返回 cell + dir 一格。
func spread_candidates(cell: Vector2i, payload: Dictionary) -> Array[Vector2i]:
	return []

## 核心到期时一次性爆发的候选格（默认无；蓄力类核心覆写，用于“存活结束后爆发”）
func burst_candidates(_cell: Vector2i) -> Array[Vector2i]:
	return []

## 当 cores.json 未给出该模式的扩散间隔时的默认值（秒）
func interval_fallback() -> float:
	return 0.9

## 该模式在部署/游玩时的名字（调试/UI 用，可覆写）
func display_name() -> String:
	return mode()
